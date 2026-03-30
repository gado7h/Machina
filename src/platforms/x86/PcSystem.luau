local PcSystem = {}
PcSystem.__index = PcSystem

local MachineProfile = require("@src/platforms/x86/MachineProfile")
local Task = require("@src/platforms/Task")

local DEFAULT_PROFILE = "x86-bios"
local RUN_CYCLES_PER_TICK = 256
local BOOT_CYCLES_PER_TICK = 768
local DEFAULT_REFRESH_HZ = 60
local CURSOR_BLINK_PERIOD = 0.5
local FAULT_TEXT_ATTR = 0x0C

local function wrapText(text, width)
	local out = {}
	local line = ""
	local function pushLine(value)
		out[#out + 1] = value
	end
	local function appendWord(word)
		while #word > width do
			if line ~= "" then
				pushLine(line)
				line = ""
			end
			pushLine(word:sub(1, width))
			word = word:sub(width + 1)
		end
		if line == "" then
			line = word
		elseif #line + 1 + #word <= width then
			line = line .. " " .. word
		else
			pushLine(line)
			line = word
		end
	end
	for rawLine in tostring(text):gmatch("([^\n]+)") do
		line = ""
		for word in rawLine:gmatch("%S+") do
			appendWord(word)
		end
		if line ~= "" then
			pushLine(line)
		end
	end
	if #out == 0 then
		out[1] = ""
	end
	return out
end

local function copyConfig(config)
	local out = {}
	for key, value in pairs(config) do
		out[key] = type(value) == "table" and table.clone(value) or value
	end
	return out
end

local function activeProfile(config)
	return (config.EMULATION and config.EMULATION.PROFILE) or DEFAULT_PROFILE
end

local function buildBoardConfig(config)
	local board = copyConfig(config)

	local x86 = config.X86 or {}
	board.DISPLAY_REFRESH_HZ = x86.HEARTBEAT_HZ or board.DISPLAY_REFRESH_HZ
	board.ROM_BASE = x86.ROM_BASE or board.ROM_BASE
	board.ROM_SIZE = x86.ROM_SIZE or board.ROM_SIZE
	board.RAM_BASE = x86.LOW_RAM_BASE or 0
	board.RAM_SIZE = x86.LOW_RAM_SIZE or board.RAM_SIZE
	board.HIGH_RAM_BASE = x86.HIGH_RAM_BASE or board.HIGH_RAM_BASE or 0x00100000
	board.HIGH_RAM_SIZE = x86.HIGH_RAM_SIZE or board.HIGH_RAM_SIZE or 0
	board.VRAM_BASE = x86.VIDEO_BASE or board.VRAM_BASE
	board.VRAM_SIZE = x86.VIDEO_SIZE or board.VRAM_SIZE
	board.PIC_VECTOR_BASE_MASTER = x86.PIC_VECTOR_BASE_MASTER or board.PIC_VECTOR_BASE_MASTER
	board.PIC_VECTOR_BASE_SLAVE = x86.PIC_VECTOR_BASE_SLAVE or board.PIC_VECTOR_BASE_SLAVE
	return board
end

local function getX86Config(self)
	return self.config.X86 or {}
end

local function getTickRate(boardConfig)
	return math.max(1, boardConfig.DISPLAY_REFRESH_HZ or DEFAULT_REFRESH_HZ)
end

local function getTickDuration(boardConfig)
	return 1 / getTickRate(boardConfig)
end

local function getPresentationRate(self)
	local x86 = getX86Config(self)
	return math.max(1, x86.PRESENT_REFRESH_HZ or x86.DISPLAY_REFRESH_HZ or DEFAULT_REFRESH_HZ)
end

local function getPresentationDuration(self)
	return 1 / getPresentationRate(self)
end

local function getTextColumns(self)
	return self.boardConfig.TEXT_COLS or self.config.TEXT_COLS or 80
end

local function getHardwareStats(device)
	return (device and type(device.getStats) == "function" and device:getStats()) or {}
end

local function getOptionalStats(device)
	return (device and device.getStats and device:getStats()) or {}
end

function PcSystem.new(config)
	local self = setmetatable({}, PcSystem)
	self.config = config
	self.boardConfig = buildBoardConfig(config)
	self.profile = activeProfile(config)
	self._trace = MachineProfile.getTraceConfig(config)
	self._presentFrame = nil
	self.runtime = nil
	self._powered = false
	self._bootStage = "OFF"
	self._heartbeatGeneration = 0
	self._lastHeartbeatAt = 0
	self._lastPresentAt = 0
	self._uptimeStart = 0
	self._cursorTimer = 0
	self._bootRecord = nil
	return self
end

function PcSystem:_traceCpuState()
	if not self._trace or self._trace.ENABLED ~= true or self._trace.CPU_STATE ~= true then
		return
	end
	if not (self.bus and self.bus._log and self.cpu) then
		return
	end
	self.bus:_log(
		"CPU",
		string.format(
			"CS:IP=%04X:%04X AX=%04X BX=%04X CX=%04X DX=%04X FLAGS=%04X",
			self.cpu.seg.CS or 0,
			self.cpu.ip or 0,
			self.cpu.reg16.AX or 0,
			self.cpu.reg16.BX or 0,
			self.cpu.reg16.CX or 0,
			self.cpu.reg16.DX or 0,
			self.cpu.flags or 0
		)
	)
end

function PcSystem:_initializeBootRecord()
	self._bootRecord = {
		startedAt = self._uptimeStart,
		stages = {},
	}
end

function PcSystem:_buildHardware()
	local SystemBus = require("@src/platforms/x86/devices/SystemBus")
	local PhysicalMemory = require("@src/platforms/x86/devices/PhysicalMemory")
	local FirmwareRom = require("@src/platforms/x86/devices/FirmwareRom")
	local VgaAdapter = require("@src/platforms/x86/devices/VgaAdapter")
	local AtaController = require("@src/platforms/x86/devices/AtaController")
	local I8042Controller = require("@src/platforms/x86/devices/I8042Controller")
	local Uart8250 = require("@src/platforms/x86/devices/Uart8250")
	local CmosRtc = require("@src/platforms/x86/devices/CmosRtc")
	local Cpu80386 = require("@src/platforms/x86/Cpu80386")

	self.bus = SystemBus.new(self.boardConfig)
	self.ram = PhysicalMemory.new(self.boardConfig)
	self.highRam = nil
	if (tonumber(self.boardConfig.HIGH_RAM_SIZE) or 0) > 0 then
		local highRamConfig = copyConfig(self.boardConfig)
		highRamConfig.RAM_SIZE = tonumber(self.boardConfig.HIGH_RAM_SIZE) or 0
		self.highRam = PhysicalMemory.new(highRamConfig)
	end
	self.rom = FirmwareRom.new(self.boardConfig)
	self.gpu = VgaAdapter.new(self.boardConfig)
	self.hdd = AtaController.new(self.boardConfig)
	self.cpu = Cpu80386.new(self.bus, self.boardConfig)
	self.keyboard = I8042Controller.new(self.boardConfig, self.bus)
	self.serial = Uart8250.new(self.boardConfig)
	self.rtc = CmosRtc.new(self.boardConfig)

	self.nic = { link = "DOWN", ip = "unassigned", mac = "00:1A:2B:3C:4D:5E" }

	self.bus:registerDevice("cpu", self.cpu)
	self.bus:registerDevice("ram", self.ram)
	if self.highRam then
		self.bus:registerDevice("high_ram", self.highRam)
	end
	self.bus:registerDevice("rom", self.rom)
	self.bus:registerDevice("gpu", self.gpu)
	self.bus:registerDevice("hdd", self.hdd)
	self.bus:registerDevice("keyboard", self.keyboard)
	self.bus:registerDevice("serial", self.serial)
	self.bus:registerDevice("rtc", self.rtc)
	self.fdc = self.bus.fdc

	self.bus:mapMemory(self.boardConfig.RAM_BASE, self.boardConfig.RAM_SIZE, self.ram, "LOW-RAM")
	if self.highRam then
		self.bus:mapMemory(self.boardConfig.HIGH_RAM_BASE, self.boardConfig.HIGH_RAM_SIZE, self.highRam, "HIGH-RAM")
	end
	self.bus:mapMemory(self.boardConfig.VRAM_BASE, self.boardConfig.VRAM_SIZE, self.gpu, "VGA-TEXT")
	self.bus:mapMemory(self.boardConfig.ROM_BASE, self.boardConfig.ROM_SIZE, self.rom, "BIOS-ROM", {
		readOnly = true,
	})
end

function PcSystem:_buildRuntime()
	local BootController = require("@src/platforms/x86/BootController")
	self.runtime = BootController.new(self)
	self.runtime:startBoot()
end

function PcSystem:_recordRuntimeInitFault(err)
	self:_setBootStage("FAULT", tostring(err))
	if self.gpu then
		self.gpu:hostClear(FAULT_TEXT_ATTR)
		self.gpu:hostWriteLine("runtime init failed", FAULT_TEXT_ATTR)
		self.gpu:hostWriteLine(tostring(err), FAULT_TEXT_ATTR)
	end
end

function PcSystem:_getCyclesPerTick()
	local x86 = getX86Config(self)
	if self._bootStage == "RUNNING" or self._bootStage == "KERNEL" then
		return x86.RUN_CYCLES_PER_TICK or RUN_CYCLES_PER_TICK
	else
		return x86.BOOT_CYCLES_PER_TICK or BOOT_CYCLES_PER_TICK
	end
end

function PcSystem:_getCpuFaultLocation(cpuStats)
	if not cpuStats then
		return nil
	end

	return string.format("pc=%05X cs=%04X ip=%04X", cpuStats.pc or 0, cpuStats.cs or 0, cpuStats.ip or 0)
end

function PcSystem:_writeCpuFaultBytes(cpuStats)
	if not (self.cpu and type(self.cpu.linearAddress) == "function" and type(self.cpu.readPhysical8) == "function") then
		return
	end

	local startLinear = self.cpu:linearAddress(cpuStats.lastCS or 0, cpuStats.lastIP or 0)
	local bytes = {}
	for offset = 0, 5 do
		bytes[#bytes + 1] = string.format("%02X", self.cpu:readPhysical8(startLinear + offset))
	end
	self.gpu:hostWriteLine("bytes=" .. table.concat(bytes, " "), FAULT_TEXT_ATTR)
end

function PcSystem:_reportCpuFault(result)
	self._bootStage = "FAULT"
	if not self.gpu then
		self._powered = false
		return
	end

	local cpuStats = self.cpu and type(self.cpu.getStats) == "function" and self.cpu:getStats() or nil
	local location = self:_getCpuFaultLocation(cpuStats)

	self.gpu:hostClear(FAULT_TEXT_ATTR)
	self.gpu:hostWriteLine("Emulator fault", FAULT_TEXT_ATTR)
	for _, line in ipairs(wrapText(tostring(result), math.max(16, getTextColumns(self) - 2))) do
		self.gpu:hostWriteLine(line, FAULT_TEXT_ATTR)
	end
	if location then
		self.gpu:hostWriteLine(location, FAULT_TEXT_ATTR)
	end
	if cpuStats and cpuStats.lastOpcode ~= nil then
		self.gpu:hostWriteLine(
			string.format("last=%02X start=%04X:%04X", cpuStats.lastOpcode, cpuStats.lastCS or 0, cpuStats.lastIP or 0),
			FAULT_TEXT_ATTR
		)
		self:_writeCpuFaultBytes(cpuStats)
	end

	self._powered = false
end

function PcSystem:_tickRuntime(dt)
	if self.runtime and type(self.runtime.tick) == "function" then
		self.runtime:tick(dt)
	end
end

function PcSystem:_toggleCursor(dt)
	self._cursorTimer = self._cursorTimer + dt
	if self._cursorTimer >= CURSOR_BLINK_PERIOD then
		self._cursorTimer = 0
		self.gpu:toggleCursor()
	end
end

function PcSystem:_stepCPU(dt)
	for _ = 1, self:_getCyclesPerTick() do
		self:_traceCpuState()
		local ok, result = pcall(function()
			return self.cpu:step()
		end)
		if not ok then
			self:_reportCpuFault(result)
			return
		end

		if result == "HLT" then
			break
		end
	end

	self:_tickRuntime(dt)
end

function PcSystem:_startHeartbeat()
	self._heartbeatGeneration = self._heartbeatGeneration + 1
	local generation = self._heartbeatGeneration
	self._lastHeartbeatAt = os.clock()
	self._lastPresentAt = self._lastHeartbeatAt

	local heartbeatDt = getTickDuration(self.boardConfig)
	local presentDt = getPresentationDuration(self)

	local function stepTick()
		if not self._powered or generation ~= self._heartbeatGeneration then
			return
		end

		local now = os.clock()
		self._lastHeartbeatAt = now
		self.bus:processDMA(heartbeatDt)
		self:_stepCPU(heartbeatDt)
		self:_toggleCursor(heartbeatDt)
		Task.delay(heartbeatDt, stepTick)
	end

	local function presentTick()
		if not self._powered or generation ~= self._heartbeatGeneration then
			return
		end

		self._lastPresentAt = os.clock()
		self:presentFrame()
		Task.delay(presentDt, presentTick)
	end

	Task.delay(heartbeatDt, stepTick)
	Task.delay(presentDt, presentTick)
end

function PcSystem:setFramePresenter(presentFrame)
	self._presentFrame = presentFrame
end

function PcSystem:presentFrame()
	if self.gpu then
		self.gpu:present(self._presentFrame)
	end
end

function PcSystem:keyDown(key)
	if self.keyboard then
		self.keyboard:keyDown(key)
	end
end

function PcSystem:keyUp(key)
	if self.keyboard then
		self.keyboard:keyUp(key)
	end
end

function PcSystem:_powerDown(clearScreen)
	self._powered = false
	self._heartbeatGeneration = self._heartbeatGeneration + 1
	self._bootStage = "OFF"
	self.runtime = nil
	self.kernel = nil
	self._bootRecord = nil
	self._cursorTimer = 0

	if self.ram then
		self.ram._mem = {}
	end
	if self.highRam then
		self.highRam._mem = {}
	end

	if clearScreen and self.gpu then
		self.gpu:clearHostOverlay()
		self.gpu:biosSetVideoMode(0x03)
		self:presentFrame()
	end
end

function PcSystem:powerOn()
	if self._powered then
		return
	end

	self._powered = true
	self._uptimeStart = os.clock()
	self._bootStage = "OFF"
	self:_initializeBootRecord()

	self:_buildHardware()
	local ok, err = pcall(function()
		self:_buildRuntime()
	end)
	if not ok then
		self:_recordRuntimeInitFault(err)
	end

	if self._bootStage ~= "FAULT" and self._powered then
		self:_startHeartbeat()
	elseif self.gpu then
		self:presentFrame()
	end
end

function PcSystem:shutdown()
	self:_powerDown(true)
end

function PcSystem:reboot()
	self:_powerDown(true)

	Task.delay(0.5, function()
		self:powerOn()
	end)
end

function PcSystem:_setBootStage(stage, detail)
	self._bootStage = stage
	if self._bootRecord then
		table.insert(self._bootRecord.stages, {
			stage = stage,
			uptime = os.clock() - self._uptimeStart,
			detail = detail,
		})
	end
end

function PcSystem:setBootRecord(record)
	self._bootRecord = self._bootRecord or { startedAt = self._uptimeStart, stages = {} }
	for key, value in pairs(record or {}) do
		self._bootRecord[key] = value
	end
end

function PcSystem:getBootRecord()
	return self._bootRecord
end

function PcSystem:getStats()
	local cpuStats = getHardwareStats(self.cpu)
	local ramStats = getHardwareStats(self.ram)
	local highRamStats = getHardwareStats(self.highRam)
	local hddStats = getHardwareStats(self.hdd)
	local gpuStats = getHardwareStats(self.gpu)
	local busStats = getHardwareStats(self.bus)
	local picStats = (self.bus and self.bus.pic and self.bus.pic.getStats and self.bus.pic:getStats()) or {}
	local timerStats = (self.bus and self.bus.timer and self.bus.timer.getStats and self.bus.timer:getStats()) or {}
	local serialStats = getOptionalStats(self.serial)
	local rtcStats = getOptionalStats(self.rtc)

	return {
		powered = self._powered,
		bootStage = self._bootStage,
		uptime = os.clock() - self._uptimeStart,
		bootRecord = self._bootRecord,
		cpuStats = cpuStats,
		ramStats = ramStats,
		highRamStats = highRamStats,
		hddStats = hddStats,
		gpuStats = gpuStats,
		busStats = busStats,
		hardware = {
			cpu = cpuStats,
			ram = ramStats,
			highRam = highRamStats,
			hdd = hddStats,
			gpu = gpuStats,
			bus = busStats,
			pic = picStats,
			timer = timerStats,
			serial = serialStats,
			rtc = rtcStats,
		},
		software = {
			profile = self.profile,
			bootStage = self._bootStage,
			kernelRunning = self.kernel ~= nil,
			runtimeInitialized = self.runtime ~= nil,
		},
	}
end

function PcSystem:isPowered()
	return self._powered
end

function PcSystem:getBootStage()
	return self._bootStage
end

return PcSystem
