local BiosInterrupts = {}
BiosInterrupts.__index = BiosInterrupts

local MachineProfile = require("@src/platforms/x86/MachineProfile")
local task = require("@src/task")

local function scanCodeForChar(ch)
	if ch == "\n" or ch == "\r" then
		return 0x1C
	end
	if ch == "\b" then
		return 0x0E
	end
	return 0
end

local function biosCharValue(ch)
	if ch == "\n" or ch == "\r" then
		return 13
	end
	if ch == "\b" then
		return 8
	end
	return string.byte(ch)
end

local REG8 = {
	AL = 0,
	CL = 1,
	DL = 2,
	BL = 3,
	AH = 4,
	CH = 5,
	DH = 6,
	BH = 7,
}

local REG16 = {
	AX = 0,
	CX = 1,
	DX = 2,
	BX = 3,
	SP = 4,
	BP = 5,
	SI = 6,
	DI = 7,
}

local SEG = {
	ES = 0,
	CS = 1,
	SS = 2,
	DS = 3,
}

local BIOS_TICKS_DWORD = 0x046C
local BIOS_MIDNIGHT_FLAG = 0x0470
local BIOS_TICKS_PER_DAY = 0x1800B0

local function readDword(cpu, address)
	return cpu:readPhysical8(address)
		+ cpu:readPhysical8(address + 1) * 0x100
		+ cpu:readPhysical8(address + 2) * 0x10000
		+ cpu:readPhysical8(address + 3) * 0x1000000
end

local function writeDword(cpu, address, value)
	local dword = (tonumber(value) or 0) % 0x100000000
	cpu:writePhysical8(address, dword % 256)
	cpu:writePhysical8(address + 1, math.floor(dword / 256) % 256)
	cpu:writePhysical8(address + 2, math.floor(dword / 65536) % 256)
	cpu:writePhysical8(address + 3, math.floor(dword / 16777216) % 256)
end

function BiosInterrupts.new(machine, runtime, image)
	local self = setmetatable({}, BiosInterrupts)
	self.machine = machine
	self.runtime = runtime
	self.image = image or {}
	self.config = machine.config
	self.x86 = machine.config.X86 or {}
	self._trace = MachineProfile.getTraceConfig(self.config)
	self._keyboardLatch = nil
	self._lastDiskStatus = 0x00
	return self
end

function BiosInterrupts:_traceLog(flagName, message)
	if not self._trace or self._trace.ENABLED ~= true then
		return
	end
	if flagName and self._trace[flagName] ~= true then
		return
	end
	if self.machine and self.machine.bus and self.machine.bus._log then
		self.machine.bus:_log("BIOS", message)
	end
end

function BiosInterrupts:_setCarry(cpu, enabled)
	cpu:setFlag(0x0001, enabled)
end

function BiosInterrupts:_repeatSoftwareInterrupt(cpu, intWidth)
	if not (cpu and cpu.readMem16 and cpu.writeMem16 and cpu.seg) then
		return
	end

	local stackSeg = cpu.seg.SS or 0
	local stackPtr = cpu:getReg16(REG16.SP)
	local returnIp = cpu:readMem16(stackSeg, stackPtr)
	cpu:writeMem16(stackSeg, stackPtr, (returnIp - (tonumber(intWidth) or 2)) % 0x10000)
end

function BiosInterrupts:_setDiskStatus(cpu, status)
	local normalized = (tonumber(status) or 0) % 0x100
	self._lastDiskStatus = normalized
	cpu:setReg8(REG8.AH, normalized)
end

function BiosInterrupts:_teletype(cpu)
	local ch = cpu:getReg8(REG8.AL)
	if ch ~= 0 then
		self.machine.gpu:biosTeletype(ch, 0x07)
	end
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_setVideoMode(cpu)
	local mode = cpu:getReg8(REG8.AL)
	self.machine.gpu:biosSetVideoMode(mode)
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_getCursorPosition(cpu)
	local page = bit32.band(cpu:getReg8(REG8.BH), 0x0F)
	local row = 0
	local col = 0
	if self.machine.gpu.getCursorPos then
		row, col = self.machine.gpu:getCursorPos(page)
	end
	cpu:setReg8(REG8.DH, row)
	cpu:setReg8(REG8.DL, col)
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_setCursorPosition(cpu)
	local page = bit32.band(cpu:getReg8(REG8.BH), 0x0F)
	local row = cpu:getReg8(REG8.DH)
	local col = cpu:getReg8(REG8.DL)
	if self.machine.gpu.setCursorPos then
		self.machine.gpu:setCursorPos(page, row, col)
	end
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_setCursorType(cpu)
	local start = cpu:getReg8(REG8.CH)
	local endLine = cpu:getReg8(REG8.CL)
	if self.machine.gpu.setCursorType then
		self.machine.gpu:setCursorType(start, endLine)
	end
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_scrollWindow(cpu)
	local lines = cpu:getReg8(REG8.AL)
	local attr = cpu:getReg8(REG8.BH)
	local top = cpu:getReg8(REG8.CH)
	local left = cpu:getReg8(REG8.CL)
	local bottom = cpu:getReg8(REG8.DH)
	local right = cpu:getReg8(REG8.DL)
	local page = 0
	if self.machine.gpu.scrollWindow then
		self.machine.gpu:scrollWindow(page, top, left, bottom, right, lines, attr)
	end
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_readCharAttr(cpu)
	local page = bit32.band(cpu:getReg8(REG8.BH), 0x0F)
	local char = 0
	local attr = 0
	if self.machine.gpu.readCharAttr then
		char, attr = self.machine.gpu:readCharAttr(page)
	end
	cpu:setReg8(REG8.AL, char)
	cpu:setReg8(REG8.AH, attr)
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_writeCharAttr(cpu)
	local char = cpu:getReg8(REG8.AL)
	local attr = cpu:getReg8(REG8.BL)
	local count = cpu:getReg16(REG16.CX)
	local page = bit32.band(cpu:getReg8(REG8.BH), 0x0F)
	if self.machine.gpu.writeCharAttr then
		self.machine.gpu:writeCharAttr(page, char, attr, count)
	end
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_getVideoMode(cpu)
	local mode = 0x03
	local cols = 80
	local page = 0
	if self.machine.gpu.getVideoMode then
		mode, cols, page = self.machine.gpu:getVideoMode()
	end
	cpu:setReg8(REG8.AL, mode)
	cpu:setReg8(REG8.AH, cols)
	cpu:setReg8(REG8.BH, page)
	self:_setCarry(cpu, false)
end

function BiosInterrupts:_chsToLba(cylinder, head, sector)
	local spt = self.x86.SECTORS_PER_TRACK or 18
	local heads = self.x86.HEADS or 1
	if sector <= 0 or sector > spt or head < 0 or head >= heads or cylinder < 0 then
		return nil
	end
	return ((cylinder * heads + head) * spt) + (sector - 1)
end

function BiosInterrupts:_encodeChsFields(cylinders, heads, sectorsPerTrack)
	local maxCylinder = math.max(0, (tonumber(cylinders) or 1) - 1)
	local maxHead = math.max(0, (tonumber(heads) or 1) - 1)
	local sectorCount = math.max(1, tonumber(sectorsPerTrack) or 1)
	local ch = bit32.band(maxCylinder, 0xFF)
	local cl = bit32.bor(bit32.band(sectorCount, 0x3F), bit32.lshift(bit32.band(bit32.rshift(maxCylinder, 8), 0x03), 6))
	return ch, cl, maxHead
end

function BiosInterrupts:_hasAtaDrive()
	return MachineProfile.validateConfig(self.config).ata.present and self.machine.hdd ~= nil
end

function BiosInterrupts:_hasFloppyDrive()
	return MachineProfile.getFloppyDriveA(self.config).present and self.machine.fdc ~= nil
end

function BiosInterrupts:_isSupportedAtaDrive(drive)
	return drive == 0x80 and self:_hasAtaDrive()
end

function BiosInterrupts:_isSupportedFloppyDrive(drive)
	return drive == 0x00 and self:_hasFloppyDrive()
end

function BiosInterrupts:_reportLastDiskStatus(cpu)
	self:_setDiskStatus(cpu, self._lastDiskStatus or 0x00)
	cpu:setReg8(REG8.AL, 0x00)
	self:_setCarry(cpu, (self._lastDiskStatus or 0x00) ~= 0)
	return true
end

function BiosInterrupts:_equipmentInterrupt(cpu)
	local low = cpu:readPhysical8(0x0410)
	local high = cpu:readPhysical8(0x0411)
	local equipmentWord = low + high * 0x100
	if equipmentWord == 0 then
		equipmentWord = MachineProfile.getEquipmentWord(self.config)
	end
	cpu:setReg16(REG16.AX, equipmentWord)
	self:_setCarry(cpu, false)
	return true
end

function BiosInterrupts:_ataGetDriveParameters(cpu, drive)
	if not self:_isSupportedAtaDrive(drive) then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x01)
		return true
	end

	local totalSectors = self.machine.hdd.getTotalSectors and self.machine.hdd:getTotalSectors()
		or self.machine.hdd.totalSectors
		or 0
	local heads = tonumber(self.x86.HEADS) or 1
	local sectorsPerTrack = tonumber(self.x86.SECTORS_PER_TRACK) or 18
	local cylinders = math.max(1, math.floor((tonumber(totalSectors) or 0) / math.max(1, heads * sectorsPerTrack)))
	local ch, cl, dh = self:_encodeChsFields(cylinders, heads, sectorsPerTrack)

	cpu:setReg8(REG8.CH, ch)
	cpu:setReg8(REG8.CL, cl)
	cpu:setReg8(REG8.DH, dh)
	cpu:setReg8(REG8.DL, 0x01)
	self:_setCarry(cpu, false)
	self:_setDiskStatus(cpu, 0x00)
	self:_traceLog(
		"DISK",
		string.format(
			"INT 13h AH=08 ATA drive=%02Xh ch=%02X cl=%02X dh=%02X",
			drive,
			ch,
			cl,
			dh
		)
	)
	return true
end

function BiosInterrupts:_floppyGetDriveParameters(cpu, drive)
	local fdc = self.machine.fdc
	local media = fdc and fdc.getMediaType and fdc:getMediaType() or nil
	local tracks = (media and media.tracks) or self.x86.FLOPPY_TRACKS or 80
	local heads = (media and media.heads) or self.x86.FLOPPY_HEADS or 2
	local sectors = (media and media.sectors) or self.x86.FLOPPY_SECTORS or 18

	if not self:_isSupportedFloppyDrive(drive) then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x01)
		return true
	end

	local ch, cl, dh = self:_encodeChsFields(tracks, heads, sectors)
	cpu:setReg8(REG8.CH, ch)
	cpu:setReg8(REG8.CL, cl)
	cpu:setReg8(REG8.DH, dh)
	cpu:setReg8(REG8.DL, 0x01)
	cpu:setReg8(REG8.BL, MachineProfile.getFloppyDriveA(self.config).nibble)
	self:_setCarry(cpu, false)
	self:_setDiskStatus(cpu, 0x00)
	self:_traceLog(
		"DISK",
		string.format(
			"INT 13h AH=08 floppy drive=%02Xh tracks=%d heads=%d sectors=%d",
			drive,
			tracks,
			heads,
			sectors
		)
	)
	return true
end

function BiosInterrupts:_readSectors(cpu)
	local count = cpu:getReg8(REG8.AL)
	local cl = cpu:getReg8(REG8.CL)
	local ch = cpu:getReg8(REG8.CH)
	local cylinder = bit32.bor(bit32.band(ch, 0xFF), bit32.lshift(bit32.band(cl, 0xC0), 2))
	local sector = bit32.band(cl, 0x3F)
	local head = cpu:getReg8(REG8.DH)
	local drive = cpu:getReg8(REG8.DL)
	local bufferAddress = cpu:linearAddress(cpu.seg.ES, cpu:getReg16(REG16.BX))

	if not self:_isSupportedAtaDrive(drive) then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x01)
		return true
	end

	local startLba = self:_chsToLba(cylinder, head, sector)
	if not startLba then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end
	local totalSectors = self.machine.hdd.getTotalSectors and self.machine.hdd:getTotalSectors()
		or self.machine.hdd.totalSectors
	if (startLba + math.max(0, count - 1)) >= (tonumber(totalSectors) or 0) then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	for sectorIndex = 0, math.max(0, count - 1) do
		local bytes = self.machine.hdd:readSector(startLba + sectorIndex)
		for i = 1, #bytes do
			cpu:writePhysical8(bufferAddress + sectorIndex * 512 + i - 1, bytes[i])
		end
	end

	if self.runtime and type(self.runtime.onDiskRead) == "function" then
		self.runtime:onDiskRead(startLba, count, bufferAddress)
	end

	self:_traceLog(
		"DISK",
		string.format("INT 13h AH=02 ATA drive=%02Xh lba=%d count=%d", drive, startLba, count)
	)
	self:_setCarry(cpu, false)
	self:_setDiskStatus(cpu, 0x00)
	cpu:setReg8(REG8.AL, count)
	return true
end

function BiosInterrupts:_writeSectors(cpu)
	local count = cpu:getReg8(REG8.AL)
	local cl = cpu:getReg8(REG8.CL)
	local ch = cpu:getReg8(REG8.CH)
	local cylinder = bit32.bor(bit32.band(ch, 0xFF), bit32.lshift(bit32.band(cl, 0xC0), 2))
	local sector = bit32.band(cl, 0x3F)
	local head = cpu:getReg8(REG8.DH)
	local drive = cpu:getReg8(REG8.DL)
	local bufferAddress = cpu:linearAddress(cpu.seg.ES, cpu:getReg16(REG16.BX))

	if not self:_isSupportedAtaDrive(drive) then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x01)
		return true
	end

	local startLba = self:_chsToLba(cylinder, head, sector)
	if not startLba then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	local totalSectors = self.machine.hdd.getTotalSectors and self.machine.hdd:getTotalSectors()
		or self.machine.hdd.totalSectors
	if (startLba + math.max(0, count - 1)) >= (tonumber(totalSectors) or 0) then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	for sectorIndex = 0, math.max(0, count - 1) do
		local bytes = {}
		for i = 1, 512 do
			bytes[i] = cpu:readPhysical8(bufferAddress + sectorIndex * 512 + i - 1)
		end
		self.machine.hdd:writeSector(startLba + sectorIndex, bytes)
	end

	self:_traceLog(
		"DISK",
		string.format("INT 13h AH=03 ATA drive=%02Xh lba=%d count=%d", drive, startLba, count)
	)
	self:_setCarry(cpu, false)
	self:_setDiskStatus(cpu, 0x00)
	cpu:setReg8(REG8.AL, count)
	return true
end

function BiosInterrupts:_diskInterrupt(cpu)
	local drive = cpu:getReg8(REG8.DL)

	if drive < 0x80 then
		return self:_floppyDiskInterrupt(cpu, drive)
	else
		return self:_ataDiskInterrupt(cpu, drive)
	end
end

function BiosInterrupts:_ataDiskInterrupt(cpu, drive)
	local service = cpu:getReg8(REG8.AH)
	self:_traceLog("BIOS_CALLS", string.format("INT 13h ATA service=%02Xh drive=%02Xh", service, drive))
	if service == 0x00 then
		self:_setCarry(cpu, false)
		self:_setDiskStatus(cpu, 0x00)
		return true
	end
	if service == 0x02 then
		return self:_readSectors(cpu)
	end
	if service == 0x03 then
		return self:_writeSectors(cpu)
	end
	if service == 0x01 then
		return self:_reportLastDiskStatus(cpu)
	end
	if service == 0x08 then
		return self:_ataGetDriveParameters(cpu, drive)
	end
	self:_setCarry(cpu, true)
	self:_setDiskStatus(cpu, 0x01)
	return true
end

function BiosInterrupts:_floppyDiskInterrupt(cpu, drive)
	local service = cpu:getReg8(REG8.AH)
	self:_traceLog("BIOS_CALLS", string.format("INT 13h floppy service=%02Xh drive=%02Xh", service, drive))

	if service == 0x00 then
		self:_setCarry(cpu, false)
		self:_setDiskStatus(cpu, 0x00)
		return true
	end

	if service == 0x01 then
		return self:_reportLastDiskStatus(cpu)
	end

	if service == 0x02 then
		return self:_floppyReadSectors(cpu, drive)
	end

	if service == 0x03 then
		return self:_floppyWriteSectors(cpu, drive)
	end

	if service == 0x08 then
		return self:_floppyGetDriveParameters(cpu, drive)
	end

	self:_setCarry(cpu, true)
	self:_setDiskStatus(cpu, 0x01)
	return true
end

function BiosInterrupts:_floppyReadSectors(cpu, drive)
	local count = cpu:getReg8(REG8.AL)
	local cl = cpu:getReg8(REG8.CL)
	local ch = cpu:getReg8(REG8.CH)
	local dh = cpu:getReg8(REG8.DH)
	local cylinder = bit32.bor(bit32.band(ch, 0xFF), bit32.lshift(bit32.band(cl, 0xC0), 2))
	local sector = bit32.band(cl, 0x3F)
	local head = dh
	local bufferAddress = cpu:linearAddress(cpu.seg.ES, cpu:getReg16(REG16.BX))

	local fdc = self.machine.fdc
	if not fdc then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	if not self:_isSupportedFloppyDrive(drive) then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x01)
		return true
	end

	local media = fdc.getMediaType and fdc:getMediaType() or nil
	local spt = (media and media.sectors) or self.x86.FLOPPY_SECTORS or self.x86.SECTORS_PER_TRACK or 18
	local heads = (media and media.heads) or self.x86.FLOPPY_HEADS or self.x86.HEADS or 2
	local tracks = (media and media.tracks) or self.x86.FLOPPY_TRACKS or 80
	if count <= 0 or sector == 0 or sector > spt or head >= heads or cylinder >= tracks then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	local startLba = ((cylinder * heads + head) * spt) + (sector - 1)
	local totalSectors = fdc.getTotalSectors and fdc:getTotalSectors() or (tracks * heads * spt)
	if (startLba + math.max(0, count - 1)) >= totalSectors then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	for sectorIndex = 0, math.max(0, count - 1) do
		local bytes = fdc:readSector(startLba + sectorIndex)
		if not bytes then
			self:_setCarry(cpu, true)
			self:_setDiskStatus(cpu, 0x04)
			return true
		end
		for i = 1, #bytes do
			cpu:writePhysical8(bufferAddress + sectorIndex * 512 + i - 1, bytes[i])
		end
	end

	if self.runtime and type(self.runtime.onDiskRead) == "function" then
		self.runtime:onDiskRead(startLba, count, bufferAddress)
	end

	self:_traceLog(
		"DISK",
		string.format("INT 13h AH=02 floppy drive=%02Xh lba=%d count=%d", drive, startLba, count)
	)
	self:_setCarry(cpu, false)
	self:_setDiskStatus(cpu, 0x00)
	cpu:setReg8(REG8.AL, count)
	return true
end

function BiosInterrupts:_floppyWriteSectors(cpu, drive)
	local count = cpu:getReg8(REG8.AL)
	local cl = cpu:getReg8(REG8.CL)
	local ch = cpu:getReg8(REG8.CH)
	local dh = cpu:getReg8(REG8.DH)
	local cylinder = bit32.bor(bit32.band(ch, 0xFF), bit32.lshift(bit32.band(cl, 0xC0), 2))
	local sector = bit32.band(cl, 0x3F)
	local head = dh
	local bufferAddress = cpu:linearAddress(cpu.seg.ES, cpu:getReg16(REG16.BX))

	local fdc = self.machine.fdc
	if not fdc then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	if not self:_isSupportedFloppyDrive(drive) then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x01)
		return true
	end

	local media = fdc.getMediaType and fdc:getMediaType() or nil
	local spt = (media and media.sectors) or self.x86.FLOPPY_SECTORS or self.x86.SECTORS_PER_TRACK or 18
	local heads = (media and media.heads) or self.x86.FLOPPY_HEADS or self.x86.HEADS or 2
	local tracks = (media and media.tracks) or self.x86.FLOPPY_TRACKS or 80
	if count <= 0 or sector == 0 or sector > spt or head >= heads or cylinder >= tracks then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	local startLba = ((cylinder * heads + head) * spt) + (sector - 1)

	local totalSectors = fdc.getTotalSectors and fdc:getTotalSectors() or (tracks * heads * spt)
	if (startLba + math.max(0, count - 1)) >= totalSectors then
		self:_setCarry(cpu, true)
		self:_setDiskStatus(cpu, 0x04)
		return true
	end

	for sectorIndex = 0, math.max(0, count - 1) do
		local bytes = {}
		for i = 1, 512 do
			bytes[i] = cpu:readPhysical8(bufferAddress + sectorIndex * 512 + i - 1)
		end
		if not fdc:writeSector(startLba + sectorIndex, bytes) then
			self:_setCarry(cpu, true)
			self:_setDiskStatus(cpu, 0x04)
			return true
		end
	end

	self:_traceLog(
		"DISK",
		string.format("INT 13h AH=03 floppy drive=%02Xh lba=%d count=%d", drive, startLba, count)
	)
	self:_setCarry(cpu, false)
	self:_setDiskStatus(cpu, 0x00)
	cpu:setReg8(REG8.AL, count)
	return true
end

function BiosInterrupts:_keyboardInterrupt(cpu)
	local service = cpu:getReg8(REG8.AH)
	if service == 0x00 then
		local ch = self._keyboardLatch
		if ch then
			local queued = self.machine.keyboard:peekChar()
			if queued == ch then
				self.machine.keyboard:readChar()
			end
			self._keyboardLatch = nil
		else
			ch = self.machine.keyboard:readChar()
		end
		if not ch then
			-- INT 16h AH=00 waits for input. Rewind to the interrupt opcode so the
			-- guest retries instead of treating "no key" as a printable NUL.
			self:_repeatSoftwareInterrupt(cpu, 2)
			self:_setCarry(cpu, false)
			return true
		end
		cpu:setReg8(REG8.AL, biosCharValue(ch))
		cpu:setReg8(REG8.AH, scanCodeForChar(ch))
		cpu:setFlag(0x0040, false)
		self:_setCarry(cpu, false)
		return true
	end
	if service == 0x01 then
		local ch = self._keyboardLatch or self.machine.keyboard:peekChar()
		if ch then
			self._keyboardLatch = ch
			cpu:setReg8(REG8.AL, biosCharValue(ch))
			cpu:setReg8(REG8.AH, scanCodeForChar(ch))
			cpu:setFlag(0x0040, false)
		else
			self._keyboardLatch = nil
			cpu:setFlag(0x0040, true)
		end
		self:_setCarry(cpu, false)
		return true
	end
	return false
end

function BiosInterrupts:_clockInterrupt(cpu)
	local service = cpu:getReg8(REG8.AH)
	self:_traceLog("BIOS_CALLS", string.format("INT 1Ah service=%02Xh", service))
	if service == 0x00 then
		local ticks = readDword(cpu, BIOS_TICKS_DWORD)
		local rollover = cpu:readPhysical8(BIOS_MIDNIGHT_FLAG)
		cpu:setReg16(REG16.CX, math.floor(ticks / 0x10000))
		cpu:setReg16(REG16.DX, ticks % 0x10000)
		cpu:setReg8(REG8.AL, rollover)
		cpu:writePhysical8(BIOS_MIDNIGHT_FLAG, 0x00)
		self:_setCarry(cpu, false)
		return true
	end
	if service == 0x02 or service == 0x04 then
		local rtc = self.machine.rtc
		if not rtc or type(rtc.readRegister) ~= "function" then
			self:_setCarry(cpu, true)
			return true
		end
		local isDate = service == 0x04
		local regs = isDate and { 0x09, 0x08, 0x07 } or { 0x04, 0x02, 0x00 }
		cpu:setReg8(REG8.CH, rtc:readRegister(regs[1]))
		cpu:setReg8(REG8.CL, rtc:readRegister(regs[2]))
		cpu:setReg8(REG8.DH, rtc:readRegister(regs[3]))
		cpu:setReg8(REG8.DL, 0x00)
		self:_setCarry(cpu, false)
		return true
	end
	return false
end

function BiosInterrupts:_memorySizeInterrupt(cpu)
	local x86 = self.x86
	local baseMemK = x86.LOW_RAM_SIZE and math.floor(x86.LOW_RAM_SIZE / 1024) or 640
	cpu:setReg16(REG16.AX, baseMemK)
	self:_setCarry(cpu, false)
	return true
end

function BiosInterrupts:_systemConfigInterrupt(cpu)
	local service = cpu:getReg8(REG8.AH)
	if service == 0xC0 then
		local biosSymbols = self.image and self.image.symbols and self.image.symbols.bios or nil
		local tableOffset = (biosSymbols and biosSymbols.SYS_CONFIG_TABLE) or 0xE980
		cpu:setSeg(SEG.ES, 0xF000)
		cpu:setReg16(REG16.BX, tableOffset % 0x10000)
		cpu:setReg8(REG8.AH, 0x00)
		self:_setCarry(cpu, false)
		return true
	end
	if service == 0xC2 then
		local sub = cpu:getReg8(REG8.AL)
		if sub == 0x00 then
			cpu:setReg8(REG8.AL, 0x05)
			self:_setCarry(cpu, false)
			return true
		end
	end
	if service == 0x87 then
		local src = cpu:getReg16(REG16.DX) * 16 + cpu:getReg16(REG16.BX)
		local dest = cpu:getReg16(REG16.SI) * 16 + cpu:getReg16(REG16.DI)
		local count = cpu:getReg16(REG16.BX)
		for i = 0, count * 2 - 1 do
			local byte = cpu:readPhysical8(src + i)
			cpu:writePhysical8(dest + i, byte)
		end
		cpu:setReg8(REG8.AL, 0x00)
		self:_setCarry(cpu, false)
		return true
	end
	if service == 0xC5 then
		cpu:setReg8(REG8.AL, 0x00)
		cpu:setReg8(REG8.CL, 0x00)
		cpu:setReg8(REG8.DL, 0x00)
		cpu:setReg8(REG8.BL, 0x00)
		self:_setCarry(cpu, false)
		return true
	end
	return false
end

function BiosInterrupts:_incrementBiosTickCounter(cpu)
	local ticks = readDword(cpu, BIOS_TICKS_DWORD) + 1
	local midnightRollovers = 0
	while ticks >= BIOS_TICKS_PER_DAY do
		ticks = ticks - BIOS_TICKS_PER_DAY
		midnightRollovers = midnightRollovers + 1
	end
	writeDword(cpu, BIOS_TICKS_DWORD, ticks)
	if midnightRollovers > 0 then
		local current = cpu:readPhysical8(BIOS_MIDNIGHT_FLAG)
		cpu:writePhysical8(BIOS_MIDNIGHT_FLAG, (current + midnightRollovers) % 0x100)
	end
end

function BiosInterrupts:_usesDefaultInterruptHandler(cpu, vector)
	local biosSymbols = self.image and self.image.symbols and self.image.symbols.bios or nil
	local defaultHandler = (biosSymbols and biosSymbols.DEFAULT_INT_HANDLER) or (self.x86.BIOS_ENTRY_OFFSET or 0x0100)
	local romBase = self.x86.ROM_BASE or self.config.ROM_BASE or 0xF0000
	local romSegment = math.floor(romBase / 16) % 0x10000
	local ivtOffset = ((tonumber(vector) or 0) % 0x100) * 4
	local offset = cpu:readPhysical8(ivtOffset) + cpu:readPhysical8(ivtOffset + 1) * 0x100
	local segment = cpu:readPhysical8(ivtOffset + 2) + cpu:readPhysical8(ivtOffset + 3) * 0x100
	return offset == (defaultHandler % 0x10000) and segment == romSegment
end

function BiosInterrupts:_handleHardwareInterrupt(cpu, vector)
	local masterBase = self.x86.PIC_VECTOR_BASE_MASTER or self.config.PIC_VECTOR_BASE_MASTER or 0x08
	local slaveBase = self.x86.PIC_VECTOR_BASE_SLAVE or self.config.PIC_VECTOR_BASE_SLAVE or 0x70
	local isMasterIrq = vector >= masterBase and vector < (masterBase + 8)
	local isSlaveIrq = vector >= slaveBase and vector < (slaveBase + 8)

	if not isMasterIrq and not isSlaveIrq then
		return false
	end
	if not self:_usesDefaultInterruptHandler(cpu, vector) then
		return false
	end

	if vector == masterBase then
		self:_incrementBiosTickCounter(cpu)
	elseif vector == slaveBase then
		if self.machine.rtc and type(self.machine.rtc.readRegister) == "function" then
			self.machine.rtc:readRegister(0x0C)
		end
	end

	if self.machine.bus and type(self.machine.bus.endOfInterrupt) == "function" then
		self.machine.bus:endOfInterrupt(vector)
	end
	return true
end

function BiosInterrupts:_a20Interrupt(cpu)
	local service = cpu:getReg8(REG8.AH)
	if service == 0x24 then
		local sub = cpu:getReg8(REG8.AL)
		if sub == 0x00 then
			if self.machine.bus and self.machine.bus.setA20Enabled then
				self.machine.bus:setA20Enabled(false)
			end
			cpu:setReg16(REG16.AX, 0x0000)
			self:_setCarry(cpu, false)
			return true
		end
		if sub == 0x01 then
			if self.machine.bus and self.machine.bus.setA20Enabled then
				self.machine.bus:setA20Enabled(true)
			end
			cpu:setReg16(REG16.AX, 0x0000)
			self:_setCarry(cpu, false)
			return true
		end
		if sub == 0x02 then
			local a20Enabled = self.machine.bus and self.machine.bus.isA20Enabled()
			cpu:setReg8(REG8.AH, 0x00)
			cpu:setReg8(REG8.AL, a20Enabled and 0x01 or 0x00)
			self:_setCarry(cpu, false)
			return true
		end
		if sub == 0x03 then
			cpu:setReg8(REG8.AH, 0x00)
			cpu:setReg16(REG16.BX, 0x0003)
			self:_setCarry(cpu, false)
			return true
		end
	end
	return false
end

function BiosInterrupts:_bootInterrupt(cpu)
	cpu.halted = true
	local reboot = function()
		self.machine:reboot()
	end
	if task and task.delay then
		task.delay(0, reboot)
	else
		reboot()
	end
	return true
end

function BiosInterrupts:handleInterrupt(cpu, vector)
	if vector == 0x10 then
		local service = cpu:getReg8(REG8.AH)
		self:_traceLog("BIOS_CALLS", string.format("INT 10h service=%02Xh", service))
		if service == 0x0E then
			self:_teletype(cpu)
			return true
		end
		if service == 0x00 then
			self:_setVideoMode(cpu)
			return true
		end
		if service == 0x03 then
			self:_getCursorPosition(cpu)
			return true
		end
		if service == 0x02 then
			self:_setCursorPosition(cpu)
			return true
		end
		if service == 0x01 then
			self:_setCursorType(cpu)
			return true
		end
		if service == 0x06 then
			self:_scrollWindow(cpu)
			return true
		end
		if service == 0x08 then
			self:_readCharAttr(cpu)
			return true
		end
		if service == 0x09 then
			self:_writeCharAttr(cpu)
			return true
		end
		if service == 0x0F then
			self:_getVideoMode(cpu)
			return true
		end
		return true
	end
	if vector == 0x11 then
		return self:_equipmentInterrupt(cpu)
	end
	if vector == 0x12 then
		return self:_memorySizeInterrupt(cpu)
	end
	if vector == 0x13 then
		return self:_diskInterrupt(cpu)
	end
	if vector == 0x15 then
		if self:_a20Interrupt(cpu) then
			return true
		end
		return self:_systemConfigInterrupt(cpu)
	end
	if vector == 0x16 then
		return self:_keyboardInterrupt(cpu)
	end
	if vector == 0x19 then
		return self:_bootInterrupt(cpu)
	end
	if vector == 0x1A then
		return self:_clockInterrupt(cpu)
	end
	if self:_handleHardwareInterrupt(cpu, vector) then
		return true
	end
	return false
end

return BiosInterrupts
