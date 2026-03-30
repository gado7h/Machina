local BootImageCatalog = require("@src/platforms/x86/BootImageCatalog")
local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")
local DiagnosticsState = require("@src/platforms/x86/HardwareDiagnosticsState")
local MachineProfile = require("@src/platforms/x86/MachineProfile")
local ProtectedModeSelfTest = require("@src/platforms/x86/ProtectedModeSelfTest")

local HardwareDiagnostics = {}

local deepCopy = DiagnosticsState.deepCopy
local copyStats = DiagnosticsState.copyStats
local restoreStats = DiagnosticsState.restoreStats
local snapshotPIC = DiagnosticsState.snapshotPIC
local restorePIC = DiagnosticsState.restorePIC
local snapshotMachine = DiagnosticsState.snapshotMachine
local restoreMachine = DiagnosticsState.restoreMachine
local readTextScreen = DiagnosticsState.readTextScreen

local function wrapTest(name, suite, run)
	local ok, passed, detail, evidence = pcall(run)
	if not ok then
		return {
			name = name,
			suite = suite or "smoke",
			passed = false,
			detail = tostring(passed),
			evidence = {
				error = tostring(passed),
			},
		}
	end
	return {
		name = name,
		suite = suite or "smoke",
		passed = passed ~= false,
		detail = tostring(detail or (passed ~= false and "ok" or "failed")),
		evidence = evidence,
	}
end

local function applyX86Overrides(target, source)
	target.X86 = target.X86 or {}
	for key, value in pairs(source or {}) do
		target.X86[key] = deepCopy(value)
	end
end

local function formatHex(value, width)
	local digits = width or 2
	return string.format("0x%0" .. tostring(digits) .. "X", (tonumber(value) or 0) % (2 ^ (digits * 4)))
end

local function decodeRTCValue(value, binaryMode)
	local byteValue = (tonumber(value) or 0) % 0x100
	if binaryMode then
		return byteValue
	end
	return ((math.floor(byteValue / 16) % 16) * 10) + (byteValue % 16)
end

local function testPIC(machine, config)
	local bus = machine.bus
	local pic = bus.pic
	local snapshot = snapshotPIC(pic)
	local busStats = copyStats(bus)

	local ports = config.PORT
	bus:portWrite(ports.PIC_MASTER_CMD, 0x11)
	bus:portWrite(ports.PIC_SLAVE_CMD, 0x11)
	bus:portWrite(ports.PIC_MASTER_DATA, 0x20)
	bus:portWrite(ports.PIC_SLAVE_DATA, 0x28)
	bus:portWrite(ports.PIC_MASTER_DATA, 0x04)
	bus:portWrite(ports.PIC_SLAVE_DATA, 0x02)
	bus:portWrite(ports.PIC_MASTER_DATA, 0x01)
	bus:portWrite(ports.PIC_SLAVE_DATA, 0x01)
	bus:portWrite(ports.PIC_MASTER_DATA, 0x00)
	bus:portWrite(ports.PIC_SLAVE_DATA, 0x00)

	bus:raiseIRQ(1, { source = "diag-pic" })
	local vector1 = bus:getPendingInterruptVector()
	if vector1 then
		bus:endOfInterrupt(vector1)
	end

	bus:raiseIRQ(14, { source = "diag-pic" })
	local vector2 = bus:getPendingInterruptVector()
	if vector2 then
		bus:endOfInterrupt(vector2)
	end

	restorePIC(pic, snapshot)
	restoreStats(bus, busStats)

	local passed = vector1 == 0x21 and vector2 == 0x2E
	return passed, string.format("irq1=%s irq14=%s", formatHex(vector1), formatHex(vector2))
end

local function testPIT(machine, config)
	local bus = machine.bus
	local timer = bus.timer
	local picSnapshot = snapshotPIC(bus.pic)
	local timerChannels = deepCopy(timer._channels)
	local timerSubTicks = timer._subTicks
	local timerStats = copyStats(timer)
	local busStats = copyStats(bus)

	bus.pic.master.imr = 0x00
	bus.pic.slave.imr = 0x00
	bus:portWrite(config.PORT.PIT_CMD, 0x34)
	bus:portWrite(config.PORT.PIT_CHAN0, 0x02)
	bus:portWrite(config.PORT.PIT_CHAN0, 0x00)
	timer:tick(4 / math.max(1, timer._baseHz or 1193182))
	local vector = bus:getPendingInterruptVector()
	if vector then
		bus:endOfInterrupt(vector)
	end

	bus:portWrite(config.PORT.PIT_CMD, 0xB6)
	bus:portWrite(config.PORT.PIT_CHAN0 + 2, 0xFF)
	bus:portWrite(config.PORT.PIT_CHAN0 + 2, 0x7F)
	timer:tick(64 / math.max(1, timer._baseHz or 1193182))
	bus:portWrite(config.PORT.PIT_CMD, 0xD8)
	local status2 = bus:portRead(config.PORT.PIT_CHAN0 + 2)
	local count2Lo = bus:portRead(config.PORT.PIT_CHAN0 + 2)
	local count2Hi = bus:portRead(config.PORT.PIT_CHAN0 + 2)

	timer._channels = deepCopy(timerChannels)
	timer._subTicks = timerSubTicks
	restoreStats(timer, timerStats)
	restorePIC(bus.pic, picSnapshot)
	restoreStats(bus, busStats)

	local expected = ((config.X86 and config.X86.PIC_VECTOR_BASE_MASTER) or config.PIC_VECTOR_BASE_MASTER or 0x08)
	local statusOk = bit32.band(status2, 0x36) == 0x36
	local countOk = count2Lo ~= 0 or count2Hi ~= 0
	local passed = vector == expected and statusOk and countOk
	return passed,
		string.format(
			"pit_vector=%s expected=%s ch2_status=%s ch2_count=%s%s",
			formatHex(vector),
			formatHex(expected),
			formatHex(status2),
			formatHex(count2Hi),
			formatHex(count2Lo)
		)
end

local function testVGA(machine, config)
	local bus = machine.bus
	local gpu = machine.gpu
	local x86 = config.X86 or {}
	local textBase = x86.TEXT_BUFFER_BASE or 0xB8000
	local graphicsBase = x86.VIDEO_BASE or config.VRAM_BASE or 0xA0000
	local busStats = copyStats(bus)
	local gpuStats = copyStats(gpu)
	local savedText0 = bus:memRead(textBase)
	local savedText1 = bus:memRead(textBase + 1)
	local savedGraphics0 = bus:memRead(graphicsBase)
	local savedGraphics1 = bus:memRead(graphicsBase + 1)
	local crtc = {
		index = gpu._crtcIndex,
		hi = gpu._crtc[0x0E] or 0,
		lo = gpu._crtc[0x0F] or 0,
		startHi = gpu._crtc[0x0C] or 0,
		startLo = gpu._crtc[0x0D] or 0,
		mode = gpu._biosMode,
		misc = gpu._miscOutput,
		attrIndex = gpu._attrIndex,
		attrFlipFlop = gpu._attrFlipFlop,
		dacMask = gpu._dacMask,
		dacReadIndex = gpu._dacReadIndex,
		dacWriteIndex = gpu._dacWriteIndex,
		dacReadComponent = gpu._dacReadComponent,
		dacWriteComponent = gpu._dacWriteComponent,
	}
	local savedSeq = deepCopy(gpu._sequencer)
	local savedGraphics = deepCopy(gpu._graphics)
	local savedAttr = deepCopy(gpu._attribute)
	local savedDac = deepCopy(gpu._dac)

	gpu:biosSetVideoMode(0x03)
	bus:memWrite(textBase, string.byte("Z"))
	bus:memWrite(textBase + 1, 0x1E)
	bus:portWrite(config.PORT.VGA_CRTC_INDEX, 0x0F)
	bus:portWrite(config.PORT.VGA_CRTC_DATA, 0x05)
	bus:portWrite(config.PORT.VGA_CRTC_INDEX, 0x0E)
	bus:portWrite(config.PORT.VGA_CRTC_DATA, 0x00)
	bus:portRead(config.PORT.VGA_INPUT_STATUS1)
	bus:portWrite(config.PORT.VGA_ATTR_INDEX, 0x02)
	bus:portWrite(config.PORT.VGA_ATTR_INDEX, 0x12)
	bus:portWrite(config.PORT.VGA_DAC_WRITE_INDEX, 0x12)
	bus:portWrite(config.PORT.VGA_DAC_DATA, 0x3F)
	bus:portWrite(config.PORT.VGA_DAC_DATA, 0x00)
	bus:portWrite(config.PORT.VGA_DAC_DATA, 0x00)
	bus:portWrite(config.PORT.VGA_DAC_READ_INDEX, 0x12)
	local dacR = bus:portRead(config.PORT.VGA_DAC_DATA)
	local dacG = bus:portRead(config.PORT.VGA_DAC_DATA)
	local dacB = bus:portRead(config.PORT.VGA_DAC_DATA)

	local glyph = bus:memRead(textBase)
	local attr = bus:memRead(textBase + 1)
	local col, row = gpu:getCursor()

	gpu:biosSetVideoMode(0x13)
	bus:memWrite(graphicsBase, 0x12)
	bus:memWrite(graphicsBase + 1, 0x34)
	local gfx0 = bus:memRead(graphicsBase)
	local gfx1 = bus:memRead(graphicsBase + 1)

	bus:memWrite(textBase, savedText0)
	bus:memWrite(textBase + 1, savedText1)
	bus:memWrite(graphicsBase, savedGraphics0)
	bus:memWrite(graphicsBase + 1, savedGraphics1)
	bus:portWrite(config.PORT.VGA_CRTC_INDEX, 0x0C)
	bus:portWrite(config.PORT.VGA_CRTC_DATA, crtc.startHi)
	bus:portWrite(config.PORT.VGA_CRTC_INDEX, 0x0D)
	bus:portWrite(config.PORT.VGA_CRTC_DATA, crtc.startLo)
	bus:portWrite(config.PORT.VGA_CRTC_INDEX, 0x0E)
	bus:portWrite(config.PORT.VGA_CRTC_DATA, crtc.hi)
	bus:portWrite(config.PORT.VGA_CRTC_INDEX, 0x0F)
	bus:portWrite(config.PORT.VGA_CRTC_DATA, crtc.lo)
	gpu._biosMode = crtc.mode
	gpu._miscOutput = crtc.misc
	gpu._crtcIndex = crtc.index
	gpu._attrIndex = crtc.attrIndex
	gpu._attrFlipFlop = crtc.attrFlipFlop
	gpu._dacMask = crtc.dacMask
	gpu._dacReadIndex = crtc.dacReadIndex
	gpu._dacWriteIndex = crtc.dacWriteIndex
	gpu._dacReadComponent = crtc.dacReadComponent
	gpu._dacWriteComponent = crtc.dacWriteComponent
	gpu._sequencer = deepCopy(savedSeq)
	gpu._graphics = deepCopy(savedGraphics)
	gpu._attribute = deepCopy(savedAttr)
	gpu._dac = deepCopy(savedDac)
	restoreStats(gpu, gpuStats)
	restoreStats(bus, busStats)

	local passed = glyph == string.byte("Z")
		and attr == 0x1E
		and col == 5
		and row == 0
		and dacR == 0x3F
		and dacG == 0x00
		and dacB == 0x00
		and gfx0 == 0x12
		and gfx1 == 0x34
	return passed,
		string.format(
			"char=%s attr=%s cursor=%d,%d dac=%s/%s/%s gfx=%s,%s",
			formatHex(glyph),
			formatHex(attr),
			col or -1,
			row or -1,
			formatHex(dacR),
			formatHex(dacG),
			formatHex(dacB),
			formatHex(gfx0),
			formatHex(gfx1)
		)
end

local function testVGAFontPlane(machine, config)
	local bus = machine.bus
	local gpu = machine.gpu
	local graphicsBase = (config.X86 or {}).VIDEO_BASE or config.VRAM_BASE or 0xA0000
	local busStats = copyStats(bus)
	local gpuStats = copyStats(gpu)
	local savedGraphics = deepCopy(gpu._graphics)
	local savedSeq = deepCopy(gpu._sequencer)
	local targetChar = 65
	local targetOffset = targetChar * 32
	local original = {}

	for row = 0, 15 do
		bus:portWrite(config.PORT.VGA_SEQ_INDEX, 0x02)
		bus:portWrite(config.PORT.VGA_SEQ_DATA, 0x04)
		bus:portWrite(config.PORT.VGA_GC_INDEX, 0x06)
		bus:portWrite(config.PORT.VGA_GC_DATA, 0x00)
		bus:portWrite(config.PORT.VGA_GC_INDEX, 0x04)
		bus:portWrite(config.PORT.VGA_GC_DATA, 0x02)
		original[row] = bus:memRead(graphicsBase + targetOffset + row)
	end

	for row = 0, 15 do
		bus:memWrite(graphicsBase + targetOffset + row, (row % 2 == 0) and 0x18 or 0x3C)
	end

	local uploaded = {}
	for row = 0, 15 do
		uploaded[row] = bus:memRead(graphicsBase + targetOffset + row)
	end

	for row = 0, 15 do
		bus:memWrite(graphicsBase + targetOffset + row, original[row] or 0)
	end

	gpu._graphics = deepCopy(savedGraphics)
	gpu._sequencer = deepCopy(savedSeq)
	restoreStats(gpu, gpuStats)
	restoreStats(bus, busStats)

	local passed = true
	for row = 0, 15 do
		local expected = (row % 2 == 0) and 0x18 or 0x3C
		if uploaded[row] ~= expected then
			passed = false
			break
		end
	end
	return passed,
		string.format("font_plane_char=%d row0=%s row1=%s", targetChar, formatHex(uploaded[0]), formatHex(uploaded[1]))
end

local function testVGAPlanar(machine, config)
	local bus = machine.bus
	local gpu = machine.gpu
	local graphicsBase = (config.X86 or {}).VIDEO_BASE or config.VRAM_BASE or 0xA0000
	local busStats = copyStats(bus)
	local gpuStats = copyStats(gpu)
	local savedGraphics = deepCopy(gpu._graphics)
	local savedSeq = deepCopy(gpu._sequencer)

	gpu:biosSetVideoMode(0x0D)
	bus:portWrite(config.PORT.VGA_SEQ_INDEX, 0x02)
	bus:portWrite(config.PORT.VGA_SEQ_DATA, 0x0F)
	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x08)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0xFF)
	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x03)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0x00)
	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x05)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0x00)
	bus:memWrite(graphicsBase, 0xA5)

	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x04)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0x00)
	local plane0 = bus:memRead(graphicsBase)

	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x05)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0x01)
	bus:memWrite(graphicsBase, 0x00)
	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x05)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0x00)
	local plane0AfterMode1 = bus:memRead(graphicsBase)

	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x00)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0x0F)
	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x01)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0x0F)
	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x08)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0xF0)
	bus:portWrite(config.PORT.VGA_GC_INDEX, 0x05)
	bus:portWrite(config.PORT.VGA_GC_DATA, 0x00)
	bus:memWrite(graphicsBase, 0x00)
	local setResetPlane0 = bus:memRead(graphicsBase)

	gpu._graphics = deepCopy(savedGraphics)
	gpu._sequencer = deepCopy(savedSeq)
	restoreStats(gpu, gpuStats)
	restoreStats(bus, busStats)

	local passed = plane0 == 0xA5 and plane0AfterMode1 == 0xA5 and setResetPlane0 == 0xF5
	return passed,
		string.format(
			"plane0=%s mode1=%s setreset=%s",
			formatHex(plane0),
			formatHex(plane0AfterMode1),
			formatHex(setResetPlane0)
		)
end

local function testVGATiming(machine, _config)
	local gpu = machine.gpu
	local bus = machine.bus
	local gpuStats = copyStats(gpu)
	local elapsed = gpu._timing.elapsed
	local sawDisplay = false
	local sawRetrace = false

	for _ = 1, 256 do
		gpu:tick((gpu._timing.frameTime or (1 / 70)) / 256)
		local status = bus:portRead(machine.config.PORT.VGA_INPUT_STATUS1)
		if bit32.band(status, 0x08) ~= 0 then
			sawRetrace = true
		end
		if bit32.band(status, 0x01) == 0 then
			sawDisplay = true
		end
	end

	gpu._timing.elapsed = elapsed
	gpu:tick(0)
	restoreStats(gpu, gpuStats)

	return sawDisplay and sawRetrace,
		string.format(
			"display_enable=%s vertical_retrace=%s line=%d column=%d",
			tostring(sawDisplay),
			tostring(sawRetrace),
			gpu._timing.currentLine or -1,
			gpu._timing.currentColumn or -1
		)
end

local function testKeyboard(machine, config)
	local bus = machine.bus
	local keyboard = machine.keyboard
	local picSnapshot = snapshotPIC(bus.pic)
	local busStats = copyStats(bus)
	local keyboardStats = copyStats(keyboard)
	local snapshot = {
		buffer = deepCopy(keyboard._buffer),
		ascii = deepCopy(keyboard._ascii),
		shift = keyboard._shift,
		ctrl = keyboard._ctrl,
		alt = keyboard._alt,
		capsLock = keyboard._capsLock,
		enabled = keyboard._enabled,
		scanningEnabled = keyboard._scanningEnabled,
		controllerCommandByte = keyboard._controllerCommandByte,
		pendingControllerData = keyboard._pendingControllerData,
		pendingI8042ControllerData = keyboard._pendingI8042ControllerData,
		status = keyboard._status,
		outputPort = keyboard._outputPort,
		pendingOutputPortWrite = keyboard._pendingOutputPortWrite,
	}

	bus:portWrite(config.PORT.KBD_STATUS, 0xAA)
	local selfTest = bus:portRead(config.PORT.KBD_DATA)
	bus:portWrite(config.PORT.KBD_DATA, 0xF2)
	local ack = bus:portRead(config.PORT.KBD_DATA)
	local identA = bus:portRead(config.PORT.KBD_DATA)
	local identB = bus:portRead(config.PORT.KBD_DATA)

	keyboard._buffer = deepCopy(snapshot.buffer)
	keyboard._ascii = deepCopy(snapshot.ascii)
	keyboard._shift = snapshot.shift
	keyboard._ctrl = snapshot.ctrl
	keyboard._alt = snapshot.alt
	keyboard._capsLock = snapshot.capsLock
	keyboard._enabled = snapshot.enabled
	keyboard._scanningEnabled = snapshot.scanningEnabled
	keyboard._controllerCommandByte = snapshot.controllerCommandByte
	keyboard._pendingControllerData = snapshot.pendingControllerData
	keyboard._pendingI8042ControllerData = snapshot.pendingI8042ControllerData
	keyboard._status = snapshot.status
	keyboard._outputPort = snapshot.outputPort
	keyboard._pendingOutputPortWrite = snapshot.pendingOutputPortWrite
	restoreStats(keyboard, keyboardStats)
	restorePIC(bus.pic, picSnapshot)
	restoreStats(bus, busStats)

	local passed = selfTest == 0x55 and ack == 0xFA and identA == 0xAB and identB == 0x83
	return passed,
		string.format(
			"selftest=%s ack=%s ident=%s,%s",
			formatHex(selfTest),
			formatHex(ack),
			formatHex(identA),
			formatHex(identB)
		)
end

local function testRTC(machine, config)
	local bus = machine.bus
	local rtc = machine.rtc
	local snapshot = snapshotMachine(machine)
	local ok, passed, detail = pcall(function()
		local expectedVector = ((config.X86 and config.X86.PIC_VECTOR_BASE_SLAVE) or config.PIC_VECTOR_BASE_SLAVE or 0x70)
		bus.pic.master.imr = 0x00
		bus.pic.slave.imr = 0x00

		bus:portWrite(config.PORT.RTC_INDEX, 0x0A)
		local statusA = bus:portRead(config.PORT.RTC_DATA)
		bus:portWrite(config.PORT.RTC_INDEX, 0x0A)
		bus:portWrite(config.PORT.RTC_DATA, bit32.bor(bit32.band(statusA, 0x70), 0x0F))

		bus:portWrite(config.PORT.RTC_INDEX, 0x0B)
		local statusB = bus:portRead(config.PORT.RTC_DATA)
		bus:portWrite(config.PORT.RTC_INDEX, 0x0B)
		bus:portWrite(config.PORT.RTC_DATA, bit32.bor(statusB, 0x40))

		local binaryMode = bit32.band(statusB, 0x04) ~= 0
		bus:portWrite(config.PORT.RTC_INDEX, 0x00)
		local sec = decodeRTCValue(bus:portRead(config.PORT.RTC_DATA), binaryMode)
		bus:portWrite(config.PORT.RTC_INDEX, 0x02)
		local min = decodeRTCValue(bus:portRead(config.PORT.RTC_DATA), binaryMode)
		bus:portWrite(config.PORT.RTC_INDEX, 0x04)
		local hour = decodeRTCValue(bus:portRead(config.PORT.RTC_DATA), binaryMode)

		rtc:tick(0.6)
		local vector = bus:getPendingInterruptVector()
		if vector then
			bus:endOfInterrupt(vector)
		end

		bus:portWrite(config.PORT.RTC_INDEX, 0x0C)
		local statusC1 = bus:portRead(config.PORT.RTC_DATA)
		bus:portWrite(config.PORT.RTC_INDEX, 0x0C)
		local statusC2 = bus:portRead(config.PORT.RTC_DATA)

		local passedRtc = bit32.band(statusB, 0x02) ~= 0
			and sec >= 0
			and sec < 60
			and min >= 0
			and min < 60
			and hour >= 0
			and hour < 24
			and vector == expectedVector
			and bit32.band(statusC1, 0x40) ~= 0
			and statusC2 == 0
		return passedRtc,
			string.format(
				"time=%02d:%02d:%02d statusB=%s statusC=%s/%s irq=%s",
				hour,
				min,
				sec,
				formatHex(statusB),
				formatHex(statusC1),
				formatHex(statusC2),
				formatHex(vector)
			)
	end)
	restoreMachine(machine, snapshot)
	if not ok then
		return false, tostring(passed)
	end
	return passed, detail
end

local function testSerial(machine, config)
	local bus = machine.bus
	local serial = machine.serial
	local busStats = copyStats(bus)
	local serialStats = copyStats(serial)
	local snapshot = {
		divisor = serial._divisor,
		ier = serial._ier,
		iir = serial._iir,
		fcr = serial._fcr,
		lcr = serial._lcr,
		mcr = serial._mcr,
		lsr = serial._lsr,
		msr = serial._msr,
		scr = serial._scr,
		rxFifo = deepCopy(serial._rxFifo),
		txLog = deepCopy(serial._txLog),
		irqPending = serial._irqPending,
	}

	local base = config.PORT.COM1_BASE
	bus:portWrite(base + 4, 0x10)
	bus:portWrite(base + 0, string.byte("A"))
	local lsr = bus:portRead(base + 5)
	local echoed = bus:portRead(base + 0)

	serial._divisor = snapshot.divisor
	serial._ier = snapshot.ier
	serial._iir = snapshot.iir
	serial._fcr = snapshot.fcr
	serial._lcr = snapshot.lcr
	serial._mcr = snapshot.mcr
	serial._lsr = snapshot.lsr
	serial._msr = snapshot.msr
	serial._scr = snapshot.scr
	serial._rxFifo = deepCopy(snapshot.rxFifo)
	serial._txLog = deepCopy(snapshot.txLog)
	serial._irqPending = snapshot.irqPending
	restoreStats(serial, serialStats)
	restoreStats(bus, busStats)

	local passed = bit32.band(lsr, 0x01) ~= 0 and echoed == string.byte("A")
	return passed, string.format("lsr=%s echoed=%s", formatHex(lsr), formatHex(echoed))
end

local function testIDE(machine, config)
	local bus = machine.bus
	local hdd = machine.hdd
	local picSnapshot = snapshotPIC(bus.pic)
	local busStats = copyStats(bus)
	local hddStats = copyStats(hdd)
	local snapshot = {
		status = hdd._status,
		error = hdd._error,
		features = hdd._features,
		sectorCount = hdd._sectorCount,
		sectorNumber = hdd._sectorNumber,
		cylinderLow = hdd._cylinderLow,
		cylinderHigh = hdd._cylinderHigh,
		driveHead = hdd._driveHead,
		deviceControl = hdd._deviceControl,
		ioBuffer = deepCopy(hdd._ioBuffer),
		transfer = deepCopy(hdd._transfer),
		pending = deepCopy(hdd._pending),
		headPos = hdd._headPos,
		activity = hdd._activity,
		irqPending = hdd._irqPending,
	}

	local base = config.PORT.IDE_PRIMARY_CMD
	bus:portWrite(base + 6, 0xE0)
	bus:portWrite(base + 7, 0xEC)
	hdd:tick(0.01)
	local status = bus:portRead(base + 7)
	local word0 = bus:portRead16(base + 0)

	hdd._status = snapshot.status
	hdd._error = snapshot.error
	hdd._features = snapshot.features
	hdd._sectorCount = snapshot.sectorCount
	hdd._sectorNumber = snapshot.sectorNumber
	hdd._cylinderLow = snapshot.cylinderLow
	hdd._cylinderHigh = snapshot.cylinderHigh
	hdd._driveHead = snapshot.driveHead
	hdd._deviceControl = snapshot.deviceControl
	hdd._ioBuffer = deepCopy(snapshot.ioBuffer)
	hdd._transfer = deepCopy(snapshot.transfer)
	hdd._pending = deepCopy(snapshot.pending)
	hdd._headPos = snapshot.headPos
	hdd._activity = snapshot.activity
	hdd._irqPending = snapshot.irqPending
	restoreStats(hdd, hddStats)
	restorePIC(bus.pic, picSnapshot)
	restoreStats(bus, busStats)

	local passed = bit32.band(status, 0x01) == 0 and bit32.band(status, 0x08) ~= 0 and word0 == 0x0040
	return passed, string.format("status=%s identify_word0=%s", formatHex(status), formatHex(word0, 4))
end

local function testFDC(machine, config)
	local bus = machine.bus
	local fdc = machine.fdc
	if not fdc then
		return false, "fdc missing", { device = "fdc" }
	end

	local snapshot = snapshotMachine(machine)
	local ok, passed, detail, evidence = pcall(function()
		local sector = {}
		for i = 1, 512 do
			sector[i] = (i - 1) % 256
		end
		fdc._mediaType = {
			tracks = 80,
			heads = 2,
			sectors = 18,
			size = 1440 * 1024,
		}
		fdc._sectors = {}
		fdc:writeSector(0, sector)

		bus:portWrite(0x03F2, 0x1C)
		bus:portWrite(0x03F5, 0x07)
		bus:portWrite(0x03F5, 0x00)
		local irqVector = bus:getPendingInterruptVector()
		if irqVector then
			bus:endOfInterrupt(irqVector)
		end

		bus:portWrite(0x03F5, 0x08)
		local senseSt0 = bus:portRead(0x03F5)
		local sensePcn = bus:portRead(0x03F5)

		bus:portWrite(0x03F5, 0x06)
		bus:portWrite(0x03F5, 0x00)
		bus:portWrite(0x03F5, 0x00)
		bus:portWrite(0x03F5, 0x00)
		bus:portWrite(0x03F5, 0x01)
		bus:portWrite(0x03F5, 0x02)
		bus:portWrite(0x03F5, 0x12)
		bus:portWrite(0x03F5, 0x1B)
		bus:portWrite(0x03F5, 0xFF)

		local data = {}
		for i = 1, 512 do
			data[i] = bus:portRead(0x03F5)
		end
		local result = {}
		for i = 1, 7 do
			result[i] = bus:portRead(0x03F5)
		end

		local readOk = data[1] == 0x00 and data[2] == 0x01 and data[256] == 0xFF and data[257] == 0x00
		local resultOk = result[1] == 0x00 and result[2] == 0x00 and result[3] == 0x00 and result[4] == 0x00 and result[5] == 0x00 and result[6] == 0x01
		local passedFdc = senseSt0 == 0x00 and sensePcn == 0x00 and readOk and resultOk
		return passedFdc,
			string.format(
				"sense=%s/%s data0=%s data1=%s result=%s,%s,%s,%s,%s,%s,%s",
				formatHex(senseSt0),
				formatHex(sensePcn),
				formatHex(data[1]),
				formatHex(data[2]),
				formatHex(result[1]),
				formatHex(result[2]),
				formatHex(result[3]),
				formatHex(result[4]),
				formatHex(result[5]),
				formatHex(result[6]),
				formatHex(result[7])
			),
			{
				sense = { senseSt0, sensePcn },
				result = result,
			}
	end)
	restoreMachine(machine, snapshot)
	if not ok then
		return false, tostring(passed), { error = tostring(passed) }
	end
	return passed, detail, evidence
end

local function testProtectedMode(machine, config)
	return ProtectedModeSelfTest.run(machine, config)
end

local function buildValidationImage(config, name)
	MachineProfile.validateConfig(config)
	local entry = BootImageCatalog[name]
	assert(entry and type(entry.build) == "function", "unknown x86 validation image: " .. tostring(name))
	return entry.build(config)
end

local function runValidationImage(machine, config, imageName, expectedPassText, options)
	options = options or {}
	local buildConfig = deepCopy(config)
	buildConfig.X86 = deepCopy(config.X86 or {})
	if options.x86Override then
		applyX86Overrides(buildConfig, options.x86Override)
	end

	local image = buildValidationImage(buildConfig, imageName)
	if image.configOverride then
		applyX86Overrides(buildConfig, image.configOverride)
	end
	if options.bootOrder then
		buildConfig.X86.BOOT_ORDER = deepCopy(options.bootOrder)
	end
	if options.bootDevice then
		buildConfig.X86.BOOT_ORDER = { options.bootDevice }
		buildConfig.X86.BOOT_DRIVE = MachineProfile.bootDriveForDevice(options.bootDevice)
	end
	if buildConfig.X86.BOOT_DRIVE == nil then
		buildConfig.X86.BOOT_DRIVE = MachineProfile.resolveBootDrive(buildConfig)
	end
	local snapshot = snapshotMachine(machine)
	local savedConfigX86 = deepCopy(machine.config.X86 or {})
	local savedBoardX86 = deepCopy((machine.boardConfig and machine.boardConfig.X86) or {})
	local ok, passed, detail, evidence = pcall(function()
		applyX86Overrides(machine.config, buildConfig.X86)
		applyX86Overrides(machine.boardConfig, buildConfig.X86)
		machine._trace = MachineProfile.getTraceConfig(machine.config)
		if machine.bus then
			machine.bus._trace = machine._trace
		end
		if machine.rtc and type(machine.rtc.refreshHardwareTable) == "function" then
			machine.rtc:refreshHardwareTable(machine.boardConfig)
		end

		if machine.gpu and type(machine.gpu.clearHostOverlay) == "function" then
			machine.gpu:clearHostOverlay()
		end
		if machine.gpu and type(machine.gpu.biosSetVideoMode) == "function" then
			machine.gpu:biosSetVideoMode(options.bootVideoMode or 0x03)
		end

		if machine.bus and machine.bus.timer then
			machine.bus.timer._enabled = options.timerEnabled ~= false
			machine.bus.timer._irqEnabled = options.timerIrqEnabled ~= false
		end

		local bootDevice = options.bootDevice
			or MachineProfile.resolveBootDevice(buildConfig, {
				imageByteCount = math.max(0, ((image.layout and image.layout.kernelSectorCount) or 0) + 1) * 512,
			})
		local installTargets = {}
		if type(options.installImageTo) == "table" then
			for _, device in ipairs(options.installImageTo) do
				installTargets[tostring(device)] = true
			end
		end
		installTargets[tostring(bootDevice)] = true

		if machine.hdd then
			machine.hdd._sectors = {}
		end
		if machine.fdc then
			machine.fdc._sectors = {}
			if type(machine.fdc.reset) == "function" then
				machine.fdc:reset()
			end
		end

		if machine.hdd then
			if installTargets.ata then
				for lba, sector in pairs(image.sectors or {}) do
					machine.hdd:writeSector(lba, sector)
				end
			end
		end

		if machine.fdc and installTargets.floppy then
			local bytes = {}
			for lba = 0, math.max(0, (((image.layout and image.layout.kernelSectorCount) or 0) + 1) - 1) do
				local sector = (image.sectors or {})[lba] or {}
				for i = 1, 512 do
					bytes[#bytes + 1] = sector[i] or 0
				end
			end
			machine.fdc:loadImage(bytes)
		end

		if machine.rom and image.romBytes then
			machine.rom:flash(image.romBytes)
		end

		local bios = BiosInterrupts.new(machine, {}, image)
		if machine.cpu and type(machine.cpu.attachBIOS) == "function" then
			machine.cpu:attachBIOS(bios)
		end
		if machine.cpu and type(machine.cpu.reset) == "function" then
			machine.cpu:reset()
		end

		local maxSteps = options.maxSteps or 40000
		local checkInterval = options.checkInterval or 16
		local stepDt = options.stepDt or (1 / math.max(1, machine.config and machine.config.DISPLAY_REFRESH_HZ or 60))
		for step = 1, maxSteps do
			if options.tickTimer and machine.bus and machine.bus.timer then
				machine.bus.timer:tick(stepDt)
			end

			local stepOk, result = pcall(function()
				return machine.cpu:step()
			end)
			if not stepOk then
				return false, tostring(result)
			end

			if step % checkInterval == 0 or result == "HLT" then
				local text = readTextScreen(machine, buildConfig)
				if string.find(text, expectedPassText, 1, true) then
					return true, string.format("pass=%s step=%d", expectedPassText, step), {
						image = imageName,
						bootDevice = bootDevice,
						bootDrive = buildConfig.X86.BOOT_DRIVE,
						passText = expectedPassText,
						step = step,
					}
				end
			end

			if machine.bus and type(machine.bus.peekFault) == "function" then
				local fault = machine.bus:peekFault()
				if fault then
					return false,
						string.format(
							"bus fault kind=%s addr=%s op=%s detail=%s",
							tostring(fault.kind),
							formatHex(fault.addr, 5),
							tostring(fault.op),
							tostring(fault.detail)
						),
						{
							image = imageName,
							bootDevice = bootDevice,
							fault = deepCopy(fault),
						}
				end
			end
		end

		local text = readTextScreen(machine, buildConfig)
		return false, string.format("missing PASS marker: %s", expectedPassText .. " text=" .. text:sub(1, 256)), {
			image = imageName,
			bootDevice = bootDevice,
			screen = text:sub(1, 256),
		}
	end)
	restoreMachine(machine, snapshot)
	machine.config.X86 = savedConfigX86
	machine.boardConfig.X86 = savedBoardX86
	machine._trace = MachineProfile.getTraceConfig(machine.config)
	if machine.bus then
		machine.bus._trace = machine._trace
	end
	if machine.rtc and type(machine.rtc.refreshHardwareTable) == "function" then
		machine.rtc:refreshHardwareTable(machine.boardConfig)
	end
	if not ok then
		return false, tostring(passed), {
			image = imageName,
			error = tostring(passed),
		}
	end
	return passed, detail, evidence
end

local function runValidationSet(machine, config, entries, defaultSuite)
	local results = {}
	local passedCount = 0
	for _, entry in ipairs(entries) do
		local result = wrapTest(entry.name, entry.suite or defaultSuite, function()
			return runValidationImage(machine, config, entry.image, entry.passText, entry.options)
		end)
		results[#results + 1] = result
		if result.passed then
			passedCount = passedCount + 1
		end
	end
	return {
		passed = passedCount == #results,
		passedCount = passedCount,
		totalCount = #results,
		results = results,
	}
end

local RUNTIME_VALIDATIONS = {
	{
		name = "reset_vector_validation",
		image = "ResetVectorValidation",
		passText = "reset vector validation PASS",
		options = {
			maxSteps = 12000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "bios_boot_validation",
		image = "BiosBootValidation",
		passText = "bios boot validation PASS",
		options = {
			maxSteps = 18000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "interrupt_integration_validation",
		image = "InterruptIntegrationValidation",
		passText = "interrupt integration validation PASS",
		options = {
			maxSteps = 32000,
			tickTimer = true,
			timerEnabled = true,
			timerIrqEnabled = true,
		},
	},
}

local CPU_VALIDATIONS = {
	{
		name = "cpu_protected_mode_validation",
		image = "CpuProtectedModeValidation",
		passText = "cpu pm validation PASS",
		options = {
			maxSteps = 24000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "cpu_exception_validation",
		image = "CpuExceptionValidation",
		passText = "cpu exception validation PASS",
		options = {
			maxSteps = 24000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "privilege_transition_validation",
		image = "PrivilegeTransitionValidation",
		passText = "privilege transition validation PASS",
		options = {
			maxSteps = 24000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "cpu_real_mode_fidelity_validation",
		image = "CpuRealModeFidelityValidation",
		passText = "cpu real mode fidelity PASS",
		options = {
			maxSteps = 32000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "protected_mode_segment_validation",
		image = "ProtectedModeSegmentValidation",
		passText = "pm segment validation PASS",
		options = {
			maxSteps = 32000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
}

local COMPATIBILITY_VALIDATIONS = {
	{
		name = "compat_floppy_boot",
		suite = "compatibility",
		image = "CompatibilityFloppyBootValidation",
		passText = "compat floppy boot PASS",
		options = {
			bootDevice = "floppy",
			maxSteps = 12000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "compat_ata_boot",
		suite = "compatibility",
		image = "CompatibilityAtaBootValidation",
		passText = "compat ata boot PASS",
		options = {
			bootDevice = "ata",
			maxSteps = 12000,
			timerEnabled = false,
			timerIrqEnabled = false,
			x86Override = {
				BOOT_ORDER = { "ata", "floppy" },
			},
		},
	},
	{
		name = "compat_floppy_geometry",
		suite = "compatibility",
		image = "CompatibilityFloppyGeometryValidation",
		passText = "compat floppy geometry PASS",
		options = {
			bootDevice = "floppy",
			maxSteps = 12000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "compat_machine_profile",
		suite = "compatibility",
		image = "CompatibilityMachineProfileValidation",
		passText = "compat machine profile PASS",
		options = {
			bootDevice = "floppy",
			maxSteps = 12000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "compat_ata_geometry",
		suite = "compatibility",
		image = "AtaGeometryValidation",
		passText = "compat ata geometry PASS",
		options = {
			bootDevice = "ata",
			maxSteps = 18000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "compat_keyboard_controller",
		suite = "compatibility",
		image = "KeyboardControllerValidation",
		passText = "compat keyboard controller PASS",
		options = {
			bootDevice = "floppy",
			maxSteps = 12000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "compat_rtc_cmos",
		suite = "compatibility",
		image = "RtcCmosValidation",
		passText = "compat rtc cmos PASS",
		options = {
			bootDevice = "floppy",
			maxSteps = 12000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "compat_pit_programming",
		suite = "compatibility",
		image = "PitProgrammingValidation",
		passText = "compat pit programming PASS",
		options = {
			bootDevice = "floppy",
			maxSteps = 12000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "compat_a20_high_ram",
		suite = "compatibility",
		image = "A20HighRamValidation",
		passText = "a20 high ram validation PASS",
		options = {
			bootDevice = "floppy",
			maxSteps = 24000,
			timerEnabled = false,
			timerIrqEnabled = false,
			x86Override = {
				HIGH_RAM_SIZE = 0x00020000,
			},
		},
	},
	{
		name = "compat_disk_selection_from_floppy",
		suite = "compatibility",
		image = "DiskDriveSelectionValidation",
		passText = "disk drive selection PASS",
		options = {
			bootDevice = "floppy",
			installImageTo = { "floppy", "ata" },
			maxSteps = 16000,
			timerEnabled = false,
			timerIrqEnabled = false,
		},
	},
	{
		name = "compat_disk_selection_from_ata",
		suite = "compatibility",
		image = "DiskDriveSelectionValidation",
		passText = "disk drive selection PASS",
		options = {
			bootDevice = "ata",
			installImageTo = { "floppy", "ata" },
			maxSteps = 16000,
			timerEnabled = false,
			timerIrqEnabled = false,
			x86Override = {
				BOOT_ORDER = { "ata", "floppy" },
			},
		},
	},
}

function HardwareDiagnostics.run(machine, config)
	MachineProfile.validateConfig(config)

	local results = {
		wrapTest("pic", "smoke", function()
			return testPIC(machine, config)
		end),
		wrapTest("pit", "smoke", function()
			return testPIT(machine, config)
		end),
		wrapTest("vga", "smoke", function()
			return testVGA(machine, config)
		end),
		wrapTest("vga_font_plane", "smoke", function()
			return testVGAFontPlane(machine, config)
		end),
		wrapTest("vga_planar_modes", "smoke", function()
			return testVGAPlanar(machine, config)
		end),
		wrapTest("vga_timing", "smoke", function()
			return testVGATiming(machine, config)
		end),
		wrapTest("keyboard", "smoke", function()
			return testKeyboard(machine, config)
		end),
		wrapTest("rtc", "smoke", function()
			return testRTC(machine, config)
		end),
		wrapTest("serial", "smoke", function()
			return testSerial(machine, config)
		end),
		wrapTest("ide", "smoke", function()
			return testIDE(machine, config)
		end),
		wrapTest("fdc", "smoke", function()
			return testFDC(machine, config)
		end),
		wrapTest("protected_mode_smoke", "smoke", function()
			return testProtectedMode(machine, config)
		end),
	}

	local passedCount = 0
	for _, result in ipairs(results) do
		if result.passed then
			passedCount = passedCount + 1
		end
	end

	return {
		passed = passedCount == #results,
		passedCount = passedCount,
		totalCount = #results,
		results = results,
	}
end

function HardwareDiagnostics.runGuestRuntimeValidations(machine, config)
	return runValidationSet(machine, config, RUNTIME_VALIDATIONS, "runtime")
end

function HardwareDiagnostics.runGuestCPUValidations(machine, config)
	return runValidationSet(machine, config, CPU_VALIDATIONS, "cpu")
end

function HardwareDiagnostics.runReviewSuite(machine, config)
	local base = HardwareDiagnostics.run(machine, config)
	local runtime = HardwareDiagnostics.runGuestRuntimeValidations(machine, config)
	local cpu = HardwareDiagnostics.runGuestCPUValidations(machine, config)

	local results = {}
	local passedCount = 0
	for _, set in ipairs({ base, runtime, cpu }) do
		for _, result in ipairs(set.results or {}) do
			results[#results + 1] = result
			if result.passed then
				passedCount = passedCount + 1
			end
		end
	end

	local combined = {
		passed = passedCount == #results,
		passedCount = passedCount,
		totalCount = #results,
		results = results,
		base = base,
		runtime = runtime,
		cpu = cpu,
	}

	return combined
end

function HardwareDiagnostics.runCompatibilitySuite(machine, config)
	local review = HardwareDiagnostics.runReviewSuite(machine, config)
	local compatibility = runValidationSet(machine, config, COMPATIBILITY_VALIDATIONS, "compatibility")

	local results = {}
	local passedCount = 0
	for _, set in ipairs({ review, compatibility }) do
		for _, result in ipairs(set.results or {}) do
			results[#results + 1] = result
			if result.passed then
				passedCount = passedCount + 1
			end
		end
	end

	return {
		passed = passedCount == #results,
		passedCount = passedCount,
		totalCount = #results,
		results = results,
		review = review,
		compatibility = compatibility,
	}
end

return HardwareDiagnostics
