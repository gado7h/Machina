local AtaController = {}
AtaController.__index = AtaController

local SECTOR_SIZE = 512
local DATA_WINDOW_OFF = 0x200
local DATA_WINDOW_END = DATA_WINDOW_OFF + SECTOR_SIZE - 1

local STATUS_ERR = 0x01
local STATUS_DRQ = 0x08
local STATUS_DSC = 0x10
local STATUS_DRDY = 0x40
local STATUS_BSY = 0x80

local ERROR_ABORT = 0x04
local ERROR_IDNF = 0x10

local CMD_READ = 0x20
local CMD_WRITE = 0x30
local CMD_IDENTIFY = 0xEC
local CMD_FLUSH = 0xE7

local DEVICE_CONTROL_NIEN = 0x02
local DEVICE_CONTROL_SRST = 0x04

local MBR_SIGNATURE_LO = 0x55
local MBR_SIGNATURE_HI = 0xAA

local function blankSector()
	local s = {}
	for i = 1, SECTOR_SIZE do
		s[i] = 0
	end
	return s
end

local function wordToBytes(buffer, wordIndex, value)
	local offset = (wordIndex * 2) + 1
	buffer[offset] = value % 0x100
	buffer[offset + 1] = math.floor(value / 0x100) % 0x100
end

local function writeIdentifyString(buffer, wordIndex, text, wordCount)
	local padded = tostring(text)
	local totalChars = wordCount * 2
	if #padded < totalChars then
		padded = padded .. string.rep(" ", totalChars - #padded)
	else
		padded = padded:sub(1, totalChars)
	end
	for index = 0, wordCount - 1 do
		local a = string.byte(padded, (index * 2) + 1) or 0x20
		local b = string.byte(padded, (index * 2) + 2) or 0x20
		local offset = (wordIndex + index) * 2 + 1
		buffer[offset] = b
		buffer[offset + 1] = a
	end
end

function AtaController.new(config)
	local self = setmetatable({}, AtaController)
	self.config = config
	self.sectorSize = SECTOR_SIZE
	self.totalSectors = tonumber(config.DISK_BLOCKS) or 0
	self._sectors = {}
	self._activity = false
	self._headPos = 0
	self._bus = nil
	self._irqPending = false

	self._status = bit32.bor(STATUS_DRDY, STATUS_DSC)
	self._error = 0
	self._features = 0
	self._sectorCount = 1
	self._sectorNumber = 1
	self._cylinderLow = 0
	self._cylinderHigh = 0
	self._driveHead = 0xE0
	self._deviceControl = 0

	self._ioBuffer = blankSector()
	self._transfer = nil
	self._pending = nil

	self.stats = {
		reads = 0,
		writes = 0,
		seeks = 0,
		errors = 0,
		commands = 0,
		irqRaised = 0,
	}

	self:_initMBR()
	return self
end

function AtaController:attachBus(bus)
	self._bus = bus
	local base = self.config.PORT.IDE_PRIMARY_CMD
	local ctrl = self.config.PORT.IDE_PRIMARY_CTRL
	bus:registerPort(
		base + 0,
		function()
			return self:_readData8()
		end,
		function(v)
			self:_writeData8(v)
		end,
		"IDE Data",
		function()
			return self:_readData16()
		end,
		function(v)
			self:_writeData16(v)
		end
	)
	bus:registerPort(base + 1, function()
		return self._error
	end, function(v)
		self._features = bit32.band(tonumber(v) or 0, 0xFF)
	end, "IDE Error/Features")
	bus:registerPort(base + 2, function()
		return self._sectorCount
	end, function(v)
		self._sectorCount = bit32.band(tonumber(v) or 0, 0xFF)
	end, "IDE Sector Count")
	bus:registerPort(base + 3, function()
		return self._sectorNumber
	end, function(v)
		self._sectorNumber = bit32.band(tonumber(v) or 0, 0xFF)
	end, "IDE Sector Number")
	bus:registerPort(base + 4, function()
		return self._cylinderLow
	end, function(v)
		self._cylinderLow = bit32.band(tonumber(v) or 0, 0xFF)
	end, "IDE Cylinder Low")
	bus:registerPort(base + 5, function()
		return self._cylinderHigh
	end, function(v)
		self._cylinderHigh = bit32.band(tonumber(v) or 0, 0xFF)
	end, "IDE Cylinder High")
	bus:registerPort(base + 6, function()
		return self._driveHead
	end, function(v)
		self._driveHead = bit32.band(tonumber(v) or 0, 0xFF)
	end, "IDE Drive/Head")
	bus:registerPort(base + 7, function()
		return self:_readStatus()
	end, function(v)
		self:_issueCommand(v)
	end, "IDE Status/Command")
	if ctrl then
		bus:registerPort(ctrl, function()
			return self:_readAltStatus()
		end, function(v)
			self:_writeDeviceControl(v)
		end, "IDE AltStatus/Control")
	end
end

function AtaController:_selectedDrive()
	return bit32.band(self._driveHead, 0x10) ~= 0 and 1 or 0
end

function AtaController:_setError(code)
	self._error = code or 1
	self._status = bit32.bor(
		bit32.band(self._status, bit32.bnot(bit32.bor(STATUS_BSY, STATUS_DRQ))),
		STATUS_ERR,
		STATUS_DRDY,
		STATUS_DSC
	)
	self._irqPending = false
	self.stats.errors = self.stats.errors + 1
end

function AtaController:_clearError()
	self._error = 0
	self._status = bit32.band(self._status, bit32.bnot(STATUS_ERR))
end

function AtaController:_interruptsEnabled()
	return bit32.band(self._deviceControl, DEVICE_CONTROL_NIEN) == 0
end

function AtaController:_raiseIRQ(kind, lba)
	if self:_interruptsEnabled() and self._bus then
		local irq = (self.config.IRQ and self.config.IRQ.ATA) or 14
		self._bus:raiseIRQ(irq, { source = "hdd", event = kind, lba = lba })
		self.stats.irqRaised = self.stats.irqRaised + 1
		self._irqPending = true
	end
end

function AtaController:_readStatus()
	local status = self._status
	self._irqPending = false
	return status
end

function AtaController:_readAltStatus()
	return self._status
end

function AtaController:_writeDeviceControl(value)
	local v = bit32.band(tonumber(value) or 0, 0xFF)
	self._deviceControl = v
	if bit32.band(v, DEVICE_CONTROL_SRST) ~= 0 then
		self._irqPending = false
		self:_softReset()
	end
end

function AtaController:_softReset()
	self._irqPending = false
	self._status = bit32.bor(STATUS_DRDY, STATUS_DSC)
	self._error = 0
	self._features = 0
	self._sectorCount = 1
	self._sectorNumber = 1
	self._cylinderLow = 0
	self._cylinderHigh = 0
	self._driveHead = 0xE0
	self._transfer = nil
	self._pending = nil
end

function AtaController:_currentSectorCount()
	if self._sectorCount == 0 then
		return 256
	end
	return self._sectorCount
end

function AtaController:_chsToLba(cylinder, head, sector)
	local spt = (self.config.X86 and self.config.X86.SECTORS_PER_TRACK) or 18
	local heads = (self.config.X86 and self.config.X86.HEADS) or 1
	if sector <= 0 or sector > spt or head < 0 or head >= heads then
		return nil
	end
	return ((cylinder * heads + head) * spt) + (sector - 1)
end

function AtaController:_currentLBA()
	if bit32.band(self._driveHead, 0x40) ~= 0 then
		return self._sectorNumber
			+ (self._cylinderLow * 0x100)
			+ (self._cylinderHigh * 0x10000)
			+ (bit32.band(self._driveHead, 0x0F) * 0x1000000)
	end
	local cylinder = self._cylinderLow + (self._cylinderHigh * 0x100)
	local head = bit32.band(self._driveHead, 0x0F)
	return self:_chsToLba(cylinder, head, self._sectorNumber)
end

function AtaController:_setCurrentLBA(value)
	local lba = math.max(0, tonumber(value) or 0)
	self._sectorNumber = lba % 0x100
	self._cylinderLow = math.floor(lba / 0x100) % 0x100
	self._cylinderHigh = math.floor(lba / 0x10000) % 0x100
	self._driveHead = bit32.bor(bit32.band(self._driveHead, 0xF0), math.floor(lba / 0x1000000) % 0x10, 0x40)
end

function AtaController:_estimateLatencySec(lba)
	local dist = math.abs(lba - self._headPos)
	return 0.001 + (dist / 250000)
end

function AtaController:_loadReadBuffer(bytes)
	self._ioBuffer = {}
	for index = 1, SECTOR_SIZE do
		self._ioBuffer[index] = bytes[index] or 0
	end
	self._transfer.index = 1
	self._status = bit32.bor(bit32.band(self._status, bit32.bnot(STATUS_BSY)), STATUS_DRDY, STATUS_DSC, STATUS_DRQ)
end

function AtaController:_beginReadTransfer(op, firstBuffer)
	self._transfer = {
		mode = "read",
		lba = op.lba,
		remaining = op.count,
		index = 1,
	}
	self:_loadReadBuffer(firstBuffer)
	self:_raiseIRQ(op.cmd == CMD_IDENTIFY and "identify-ready" or "read-ready", op.lba)
end

function AtaController:_beginWriteTransfer(op)
	self._transfer = {
		mode = "write",
		lba = op.lba,
		remaining = op.count,
		index = 1,
	}
	self._ioBuffer = blankSector()
	self._status = bit32.bor(bit32.band(self._status, bit32.bnot(STATUS_BSY)), STATUS_DRDY, STATUS_DSC, STATUS_DRQ)
	self:_raiseIRQ("write-ready", op.lba)
end

function AtaController:_completeTransfer()
	self._transfer = nil
	self._status = bit32.bor(STATUS_DRDY, STATUS_DSC)
end

function AtaController:_issueCommand(cmd)
	local command = bit32.band(tonumber(cmd) or 0, 0xFF)
	self.stats.commands = self.stats.commands + 1
	self:_clearError()
	self._status = bit32.bor(STATUS_BSY, STATUS_DRDY)
	self._irqPending = false

	if self:_selectedDrive() ~= 0 then
		self:_setError(ERROR_ABORT)
		return
	end

	local normalized = command
	if command == 1 then
		normalized = CMD_READ
	elseif command == 2 then
		normalized = CMD_WRITE
	end
	if
		normalized ~= CMD_READ
		and normalized ~= CMD_WRITE
		and normalized ~= CMD_IDENTIFY
		and normalized ~= CMD_FLUSH
	then
		self:_setError(ERROR_ABORT)
		return
	end

	local lba = 0
	local count = 1
	if normalized ~= CMD_IDENTIFY and normalized ~= CMD_FLUSH then
		lba = self:_currentLBA()
		count = self:_currentSectorCount()
		if lba == nil or lba < 0 or (lba + count - 1) >= self.totalSectors then
			self:_setError(ERROR_IDNF)
			return
		end
	end

	local latency = 0.001
	if normalized ~= CMD_FLUSH then
		latency = self:_estimateLatencySec(lba)
	end

	self._pending = {
		cmd = normalized,
		lba = lba,
		count = count,
		remaining = latency,
	}
end

function AtaController:_buildIdentifySector()
	local sector = blankSector()
	wordToBytes(sector, 0, 0x0040)
	wordToBytes(sector, 1, 0x0000)
	wordToBytes(sector, 49, 0x0200)
	wordToBytes(sector, 53, 0x0007)
	local total = self.totalSectors % 0x100000000
	wordToBytes(sector, 60, total % 0x10000)
	wordToBytes(sector, 61, math.floor(total / 0x10000) % 0x10000)
	writeIdentifyString(sector, 10, "00000001", 10)
	writeIdentifyString(sector, 23, "1.0", 4)
	writeIdentifyString(sector, 27, self.config.DISK_MODEL or "Machina Virtual ATA", 20)
	return sector
end

function AtaController:_finishCommand(op)
	self._pending = nil
	self._status = bit32.bor(STATUS_DRDY, STATUS_DSC)
	self:_clearError()

	if op.cmd == CMD_READ then
		self:_beginReadTransfer(op, self:readSector(op.lba))
	elseif op.cmd == CMD_WRITE then
		self:_beginWriteTransfer(op)
	elseif op.cmd == CMD_IDENTIFY then
		self:_beginReadTransfer(op, self:_buildIdentifySector())
	elseif op.cmd == CMD_FLUSH then
		self._status = bit32.bor(STATUS_DRDY, STATUS_DSC)
		self:_raiseIRQ("flush-complete", nil)
	end
end

function AtaController:_consumeReadByte()
	local transfer = self._transfer
	if not transfer or transfer.mode ~= "read" then
		return 0xFF
	end
	local value = self._ioBuffer[transfer.index] or 0
	transfer.index = transfer.index + 1
	if transfer.index > SECTOR_SIZE then
		transfer.remaining = transfer.remaining - 1
		if transfer.remaining > 0 then
			transfer.lba = transfer.lba + 1
			self:_loadReadBuffer(self:readSector(transfer.lba))
			self:_raiseIRQ("read-ready", transfer.lba)
		else
			self:_completeTransfer()
		end
	end
	return value
end

function AtaController:_consumeWriteByte(value)
	local transfer = self._transfer
	if not transfer or transfer.mode ~= "write" then
		return
	end
	self._ioBuffer[transfer.index] = bit32.band(tonumber(value) or 0, 0xFF)
	transfer.index = transfer.index + 1
	if transfer.index > SECTOR_SIZE then
		self:writeSector(transfer.lba, self._ioBuffer)
		transfer.remaining = transfer.remaining - 1
		if transfer.remaining > 0 then
			transfer.lba = transfer.lba + 1
			transfer.index = 1
			self._ioBuffer = blankSector()
			self:_raiseIRQ("write-ready", transfer.lba)
		else
			self:_completeTransfer()
			self:_raiseIRQ("write-complete", transfer.lba)
		end
	end
end

function AtaController:_readData8()
	return self:_consumeReadByte()
end

function AtaController:_writeData8(value)
	self:_consumeWriteByte(value)
end

function AtaController:_readData16()
	local lo = self:_consumeReadByte()
	local hi = self:_consumeReadByte()
	return lo + hi * 0x100
end

function AtaController:_writeData16(value)
	local masked = (tonumber(value) or 0) % 0x10000
	self:_consumeWriteByte(masked % 0x100)
	self:_consumeWriteByte(math.floor(masked / 0x100) % 0x100)
end

function AtaController:tick(dt)
	if not self._pending then
		return
	end
	dt = tonumber(dt) or 0
	if dt <= 0 then
		return
	end
	self._pending.remaining = self._pending.remaining - dt
	if self._pending.remaining <= 0 then
		self:_finishCommand(self._pending)
	end
end

function AtaController:readSector(lba)
	self.stats.reads = self.stats.reads + 1
	self._activity = true
	if lba < 0 or lba >= self.totalSectors then
		self.stats.errors = self.stats.errors + 1
		return blankSector()
	end
	local dist = math.abs(lba - self._headPos)
	self._headPos = lba
	if dist > 1000 then
		self.stats.seeks = self.stats.seeks + 1
	end
	return self._sectors[lba] or blankSector()
end

function AtaController:writeSector(lba, data)
	self.stats.writes = self.stats.writes + 1
	self._activity = true
	if lba < 0 or lba >= self.totalSectors then
		self.stats.errors = self.stats.errors + 1
		return false
	end
	local s = {}
	for i = 1, SECTOR_SIZE do
		s[i] = (data[i] or 0) % 256
	end
	self._sectors[lba] = s
	self._headPos = lba
	return true
end

function AtaController:readSectors(startLba, count)
	local out = {}
	for i = 0, count - 1 do
		local s = self:readSector(startLba + i)
		for _, b in ipairs(s) do
			out[#out + 1] = b
		end
	end
	return out
end

function AtaController:writeSectors(startLba, bytes)
	local scount = math.ceil(#bytes / SECTOR_SIZE)
	for i = 0, scount - 1 do
		local s = {}
		for j = 1, SECTOR_SIZE do
			s[j] = bytes[i * SECTOR_SIZE + j] or 0
		end
		self:writeSector(startLba + i, s)
	end
end

function AtaController:memRead(offset)
	offset = tonumber(offset) or -1
	if offset == 0x00 or offset == 0x01 then
		return self._status
	elseif offset == 0x02 then
		return self._error
	elseif offset == 0x03 then
		return self:_interruptsEnabled() and 1 or 0
	elseif offset == 0x04 then
		return self._sectorNumber
	elseif offset == 0x05 then
		return self._cylinderLow
	elseif offset == 0x06 then
		return self._cylinderHigh
	elseif offset == 0x07 then
		return self._driveHead
	elseif offset == 0x08 then
		return self._sectorCount
	elseif offset >= DATA_WINDOW_OFF and offset <= DATA_WINDOW_END then
		return self._ioBuffer[offset - DATA_WINDOW_OFF + 1] or 0
	end
	self:_setError(ERROR_IDNF)
	return 0xFF
end

function AtaController:memWrite(offset, value)
	offset = tonumber(offset) or -1
	local v = (tonumber(value) or 0) % 256
	if offset == 0x00 then
		self:_issueCommand(v)
	elseif offset == 0x03 then
		self:_writeDeviceControl(v)
	elseif offset == 0x04 then
		self._sectorNumber = v
	elseif offset == 0x05 then
		self._cylinderLow = v
	elseif offset == 0x06 then
		self._cylinderHigh = v
	elseif offset == 0x07 then
		self._driveHead = v
	elseif offset == 0x08 then
		self._sectorCount = v
	elseif offset >= DATA_WINDOW_OFF and offset <= DATA_WINDOW_END then
		self._ioBuffer[offset - DATA_WINDOW_OFF + 1] = v
	else
		self:_setError(ERROR_IDNF)
	end
end

function AtaController:_initMBR()
	local mbr = blankSector()
	mbr[1] = 0xEB
	mbr[2] = 0x58
	mbr[3] = 0x90

	mbr[441] = 0x4E
	mbr[442] = 0x56
	mbr[443] = 0x4D
	mbr[444] = 0x41

	local pe = 447
	mbr[pe + 0] = 0x80
	mbr[pe + 1] = 0x00
	mbr[pe + 2] = 0x02
	mbr[pe + 3] = 0x03
	mbr[pe + 4] = 0x83
	mbr[pe + 5] = 0xFF
	mbr[pe + 6] = 0xFF
	mbr[pe + 7] = 0xFF
	mbr[pe + 8] = 63
	mbr[pe + 9] = 0
	mbr[pe + 10] = 0
	mbr[pe + 11] = 0
	local sz = self.totalSectors - 63
	mbr[pe + 12] = sz % 256
	mbr[pe + 13] = math.floor(sz / 256) % 256
	mbr[pe + 14] = math.floor(sz / 65536) % 256
	mbr[pe + 15] = math.floor(sz / 16777216) % 256

	mbr[511] = MBR_SIGNATURE_LO
	mbr[512] = MBR_SIGNATURE_HI
	self._sectors[0] = mbr
end

function AtaController:readUInt32(sector, offset)
	local s = self:readSector(sector)
	local b0 = s[offset + 1] or 0
	local b1 = s[offset + 2] or 0
	local b2 = s[offset + 3] or 0
	local b3 = s[offset + 4] or 0
	return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

function AtaController:writeUInt32(sector, offset, value)
	local s = self._sectors[sector] or blankSector()
	s[offset + 1] = value % 256
	s[offset + 2] = math.floor(value / 256) % 256
	s[offset + 3] = math.floor(value / 65536) % 256
	s[offset + 4] = math.floor(value / 16777216) % 256
	self._sectors[sector] = s
end

function AtaController:readString(sector, offset, length)
	local s = self:readSector(sector)
	local chars = {}
	for i = 1, length do
		local b = s[offset + i] or 0
		if b == 0 then
			break
		end
		chars[#chars + 1] = string.char(b)
	end
	return table.concat(chars)
end

function AtaController:writeString(sector, offset, str, fieldLen)
	local s = self._sectors[sector] or blankSector()
	for i = 1, fieldLen or #str do
		s[offset + i] = (i <= #str) and string.byte(str, i) or 0
	end
	self._sectors[sector] = s
end

function AtaController:isActive()
	local active = self._activity
	self._activity = false
	return active
end

function AtaController:getStats()
	return self.stats
end

function AtaController:getSectorSize()
	return self.sectorSize
end

function AtaController:getTotalSectors()
	return self.totalSectors
end

return AtaController
