local Fdc765 = {}
Fdc765.__index = Fdc765

local SECTOR_SIZE = 512

local MEDIA_360K = { tracks = 40, heads = 2, sectors = 9, size = 360 * 1024 }
local MEDIA_720K = { tracks = 80, heads = 2, sectors = 9, size = 720 * 1024 }
local MEDIA_1440K = { tracks = 80, heads = 2, sectors = 18, size = 1440 * 1024 }

local CMD_SPECIFY = 0x03
local CMD_SENSE_DRIVE_STATUS = 0x04
local CMD_FORMAT_TRACK = 0x0D
local CMD_READ_DATA = 0x06
local CMD_READ_DELETED = 0x0C
local CMD_WRITE_DATA = 0x05
local CMD_WRITE_DELETED = 0x09
local CMD_RECALIBRATE = 0x07
local CMD_SEEK = 0x0F
local CMD_SENSE_INTERRUPT = 0x08

local ST0_NOT_READY = 0x80
local ST0_UNIT_SELECT = 0x08

local ST1_NO_DATA = 0x04

local MSR_BUSY = 0x10
local MSR_DIRECTION = 0x40
local MSR_NON_DMA = 0x20
local MSR_READY = 0x80

local DOR_RESET = 0x04

local IRQ = 6
local BASE_PORT = 0x03F0

function Fdc765.new(config)
	local self = setmetatable({}, Fdc765)
	self.config = config
	self._bus = nil
	self._sectors = {}
	self._mediaType = MEDIA_1440K

	self._dor = 0x0C
	self._msr = MSR_READY
	self._dataReg = 0

	self._commandBuffer = {}
	self._dataBuffer = {}
	self._resultBuffer = {}
	self._resultIndex = 0
	self._configReg = 0
	self._interruptPending = false

	self._state = "idle"
	self._currentDrive = 0
	self._currentHead = 0
	self._currentTrack = 0
	self._currentSector = 1

	self._headPosition = { 0, 0, 0, 0 }
	self._recalibrateNeeded = { true, true, true, true }

	self._motorOn = { false, false, false, false }
	self._motorTimeout = 0

	self._lastCommand = nil
	self._st0 = 0
	self._st1 = 0
	self._st2 = 0

	self.stats = {
		reads = 0,
		writes = 0,
		seeks = 0,
		recals = 0,
		irqs = 0,
		errors = 0,
	}

	return self
end

function Fdc765:attachBus(bus)
	self._bus = bus
	bus:registerPort(BASE_PORT + 0, nil, function(v) self:_writeDor(v) end, "FDC DOR")
	bus:registerPort(BASE_PORT + 1, nil, function(v) self:_writeTap(v) end, "FDC Tape")
	bus:registerPort(BASE_PORT + 2, nil, function(v) self:_writeDor(v) end, "FDC DOR (alt)")
	bus:registerPort(BASE_PORT + 3, nil, nil, "FDC (unused)")
	bus:registerPort(BASE_PORT + 4, function() return self:_readStatus() end, nil, "FDC MSR")
	bus:registerPort(BASE_PORT + 5, function() return self:_readData() end, function(v) self:_writeData(v) end, "FDC Data")
	bus:registerPort(BASE_PORT + 6, nil, function(v) self:_writeDor(v) end, "FDC DOR (alt)")
	bus:registerPort(BASE_PORT + 7, nil, function(v) self:_writeConfig(v) end, "FDC Config")
end

function Fdc765:_readStatus()
	return self._msr
end

function Fdc765:_readData()
	if #self._dataBuffer > 0 then
		local b = table.remove(self._dataBuffer, 1)
		if #self._dataBuffer == 0 then
			if #self._resultBuffer > 0 then
				self._msr = bit32.bor(MSR_READY, MSR_DIRECTION, MSR_BUSY)
			else
				self._msr = MSR_READY
			end
		end
		return b
	end

	if #self._resultBuffer > 0 then
		local b = table.remove(self._resultBuffer, 1)
		if #self._resultBuffer == 0 then
			self._msr = MSR_READY
		end
		return b
	end
	return 0
end

function Fdc765:_writeDor(value)
	local oldDor = self._dor
	self._dor = bit32.band(value, 0xFF)

	if bit32.band(value, DOR_RESET) == 0 then
		self:_reset()
		return
	end

	if bit32.band(oldDor, DOR_RESET) == 0 then
		self._msr = MSR_READY
		self._st0 = 0xC0
		self._interruptPending = true
		self._resultBuffer = {}
		self:_raiseIRQ()
		return
	end

	for drive = 0, 3 do
		local motorBit = bit32.lshift(1, drive + 4)
		self._motorOn[drive + 1] = (bit32.band(value, motorBit) ~= 0)
	end

	self._currentDrive = bit32.band(value, 0x03)
end

function Fdc765:_writeTap(_value)
end

function Fdc765:_writeConfig(value)
	self._configReg = bit32.band(tonumber(value) or 0, 0xFF)
end

function Fdc765:_writeData(byte)
	byte = bit32.band(byte, 0xFF)

	if self._writeTarget then
		self:_receiveWriteData(byte)
		return
	end

	if bit32.band(self._msr, MSR_BUSY) ~= 0 then
		table.insert(self._commandBuffer, byte)
	else
		self._msr = bit32.bor(MSR_BUSY, MSR_NON_DMA)
		self._commandBuffer = { byte }
	end

	self:_processCommand()
end

function Fdc765:_processCommand()
	local cmd = self._commandBuffer[1]

	if cmd == CMD_SPECIFY then
		if #self._commandBuffer >= 3 then
			self._msr = MSR_READY
			self._commandBuffer = {}
		end
	elseif cmd == CMD_SENSE_DRIVE_STATUS then
		if #self._commandBuffer >= 2 then
			local drive = bit32.band(self._commandBuffer[2], 3)
			local head = bit32.band(bit32.rshift(self._commandBuffer[2], 2), 1)
			local st3 = drive
			if head ~= 0 then
				st3 = bit32.bor(st3, 0x04)
			end
			if not self._recalibrateNeeded[drive + 1] and (self._headPosition[drive + 1] or 0) == 0 then
				st3 = bit32.bor(st3, 0x10)
			end
			if drive == 0 and ((self.config.X86 or {}).FLOPPY_A_PRESENT ~= false) then
				st3 = bit32.bor(st3, 0x20)
			end
			self._msr = bit32.bor(MSR_READY, MSR_DIRECTION, MSR_BUSY)
			self._resultBuffer = { st3 }
			self._commandBuffer = {}
		end
	elseif cmd == CMD_RECALIBRATE then
		if #self._commandBuffer >= 2 then
			local drive = bit32.band(self._commandBuffer[2], 3)
			self._currentDrive = drive
			self._headPosition[drive + 1] = 0
			self._recalibrateNeeded[drive + 1] = false
			self._st0 = drive
			self._msr = MSR_READY
			self._commandBuffer = {}
			self.stats.recals = self.stats.recals + 1
			self:_raiseIRQ()
		end
	elseif cmd == CMD_SEEK then
		if #self._commandBuffer >= 3 then
			local drive = bit32.band(self._commandBuffer[2], 3)
			local track = self._commandBuffer[3]
			self._currentDrive = drive
			self._headPosition[drive + 1] = track
			self._recalibrateNeeded[drive + 1] = false
			self._st0 = drive
			self._msr = MSR_READY
			self._commandBuffer = {}
			self.stats.seeks = self.stats.seeks + 1
			self:_raiseIRQ()
		end
	elseif cmd == CMD_READ_DATA or cmd == CMD_READ_DELETED then
		if #self._commandBuffer >= 9 then
			self:_executeReadSector()
		end
	elseif cmd == CMD_WRITE_DATA or cmd == CMD_WRITE_DELETED then
		if #self._commandBuffer >= 9 then
			self:_beginWriteSector()
		end
	elseif cmd == CMD_FORMAT_TRACK then
		if #self._commandBuffer >= 6 then
			self:_executeFormatTrack()
		end
	elseif cmd == CMD_SENSE_INTERRUPT then
		local cylinder = self._headPosition[self._currentDrive + 1] or 0
		self._resultBuffer = { self._st0, cylinder }
		self._interruptPending = false
		self._msr = bit32.bor(MSR_READY, MSR_DIRECTION, MSR_BUSY)
		self._commandBuffer = {}
	else
		self._msr = MSR_READY
		self._commandBuffer = {}
		self:_raiseIRQ()
	end
end

function Fdc765:_executeReadSector()
	local drive = bit32.band(self._commandBuffer[2], 3)
	local track = self._commandBuffer[3]
	local head = bit32.band(self._commandBuffer[4], 1)
	local sector = self._commandBuffer[5]
	local sizeCode = self._commandBuffer[6]

	local chs = self:_calculateChs(drive, head, track, sector)
	if not chs or sector > self._mediaType.sectors or sizeCode ~= 0x02 then
		self._st0 = bit32.bor(drive, ST0_UNIT_SELECT, ST0_NOT_READY)
		self._st1 = ST1_NO_DATA
		self._st2 = 0
		self._msr = bit32.bor(MSR_READY, MSR_DIRECTION, MSR_BUSY)
		self._resultBuffer = { self._st0, self._st1, self._st2, track, head, sector, sizeCode or 0 }
		self._commandBuffer = {}
		self.stats.errors = self.stats.errors + 1
		self:_raiseIRQ()
		return
	end

	local data = self:readSector(chs)
	if not data then
		self._st0 = bit32.bor(drive, ST0_UNIT_SELECT)
		self._st1 = ST1_NO_DATA
		self._st2 = 0
		self._msr = bit32.bor(MSR_READY, MSR_DIRECTION, MSR_BUSY)
		self._resultBuffer = { self._st0, self._st1, self._st2, track, head, sector, sizeCode or 0 }
		self._commandBuffer = {}
		self.stats.errors = self.stats.errors + 1
		self:_raiseIRQ()
		return
	end

	self._st0 = drive
	self._st1 = 0
	self._st2 = 0
	self._dataBuffer = {}
	for i = 1, SECTOR_SIZE do
		self._dataBuffer[i] = data[i] or 0
	end
	self._msr = bit32.bor(MSR_READY, MSR_NON_DMA, MSR_DIRECTION, MSR_BUSY)
	self._resultBuffer = {
		self._st0,
		self._st1,
		self._st2,
		track,
		head,
		sector,
		sizeCode or 0x02,
	}
	self._commandBuffer = {}
	self.stats.reads = self.stats.reads + 1
	self:_raiseIRQ()
end

function Fdc765:_beginWriteSector()
	local drive = bit32.band(self._commandBuffer[2], 3)
	local track = self._commandBuffer[3]
	local head = bit32.band(self._commandBuffer[4], 1)
	local sector = self._commandBuffer[5]
	local sizeCode = self._commandBuffer[6]

	self._writeTarget = {
		drive = drive,
		head = head,
		track = track,
		sector = sector,
		sizeCode = sizeCode,
		data = {},
		received = 0,
	}

	self._commandBuffer = {}
	self._msr = bit32.bor(MSR_READY, MSR_NON_DMA, MSR_BUSY)
end

function Fdc765:_receiveWriteData(byte)
	if not self._writeTarget then
		return
	end

	table.insert(self._writeTarget.data, byte)
	self._writeTarget.received = self._writeTarget.received + 1

	if self._writeTarget.received >= SECTOR_SIZE then
		local drive = self._writeTarget.drive
		local head = self._writeTarget.head
		local track = self._writeTarget.track
		local sector = self._writeTarget.sector

		local chs = self:_calculateChs(drive, head, track, sector)
		if chs then
			self:writeSector(chs, self._writeTarget.data)
			self.stats.writes = self.stats.writes + 1
		else
			self.stats.errors = self.stats.errors + 1
		end

		self._st0 = drive
		self._st1 = 0
		self._st2 = 0

		self._resultBuffer = {
			self._st0,
			self._st1,
			self._st2,
			track,
			head,
			sector,
			self._writeTarget.sizeCode or 0x02,
		}

		self._writeTarget = nil
		self._commandBuffer = {}
		self._msr = bit32.bor(MSR_READY, MSR_DIRECTION, MSR_BUSY)
		self:_raiseIRQ()
	end
end

function Fdc765:_executeFormatTrack()
	local drive = bit32.band(self._commandBuffer[2], 3)
	local head = bit32.band(bit32.rshift(self._commandBuffer[2], 2), 1)
	local sizeCode = self._commandBuffer[3]
	local sectorsPerTrack = self._commandBuffer[4]
	local filler = self._commandBuffer[6]

	for sectorNum = 1, sectorsPerTrack do
		local chs = self:_calculateChs(drive, head, self._headPosition[drive + 1], sectorNum)
		if chs then
			local data = {}
			for i = 1, SECTOR_SIZE do
				data[i] = filler
			end
			self:writeSector(chs, data)
		end
	end

	self._st0 = drive
	self._st1 = 0
	self._st2 = 0

	self._msr = bit32.bor(MSR_READY, MSR_DIRECTION, MSR_BUSY)
	self._resultBuffer = { self._st0, self._st1, self._st2, self._headPosition[drive + 1], head, sectorsPerTrack, sizeCode }
	self._commandBuffer = {}
	self:_raiseIRQ()
end

function Fdc765:_calculateChs(drive, head, track, sector)
	if drive ~= 0 or ((self.config.X86 or {}).FLOPPY_A_PRESENT == false) then
		return nil
	end
	if track >= self._mediaType.tracks then
		return nil
	end
	if head >= self._mediaType.heads then
		return nil
	end
	if sector == 0 or sector > self._mediaType.sectors then
		return nil
	end
	return (track * self._mediaType.heads + head) * self._mediaType.sectors + sector - 1
end

function Fdc765:_chToLba(track, head, sector)
	return (track * self._mediaType.heads + head) * self._mediaType.sectors + sector - 1
end

function Fdc765:readSector(lba)
	if not lba or lba < 0 then
		return nil
	end

	local totalSectors = self._mediaType.tracks * self._mediaType.heads * self._mediaType.sectors
	if lba >= totalSectors then
		return nil
	end

	local offset = lba * SECTOR_SIZE
	local data = {}

	for i = 1, SECTOR_SIZE do
		data[i] = self._sectors[offset + i] or 0
	end

	return data
end

function Fdc765:writeSector(lba, data)
	if not lba or lba < 0 then
		return false
	end

	local totalSectors = self._mediaType.tracks * self._mediaType.heads * self._mediaType.sectors
	if lba >= totalSectors then
		return false
	end

	local offset = lba * SECTOR_SIZE

	for i = 1, SECTOR_SIZE do
		self._sectors[offset + i] = (data[i] or 0) % 256
	end

	return true
end

function Fdc765:writeSectorRaw(lba, data)
	return self:writeSector(lba, data)
end

function Fdc765:loadImage(imageBytes)
	if not imageBytes or ((self.config.X86 or {}).FLOPPY_A_PRESENT == false) then
		return false
	end

	self._sectors = {}
	local len = #imageBytes

	if len >= 1474560 then
		self._mediaType = MEDIA_1440K
	elseif len >= 737280 then
		self._mediaType = MEDIA_720K
	else
		self._mediaType = MEDIA_360K
	end

	for i = 1, len do
		self._sectors[i] = imageBytes[i] % 256
	end

	return true
end

function Fdc765:getTotalSectors()
	return self._mediaType.tracks * self._mediaType.heads * self._mediaType.sectors
end

function Fdc765:getMediaType()
	return self._mediaType
end

function Fdc765:_reset()
	self._msr = 0
	self._commandBuffer = {}
	self._dataBuffer = {}
	self._resultBuffer = {}
	self._state = "idle"
	self._writeTarget = nil
	self._interruptPending = false
	self._st0 = 0xC0
	self._st1 = 0
	self._st2 = 0
end

function Fdc765:reset()
	self:_reset()
end

function Fdc765:_raiseIRQ()
	if self._bus then
		self._interruptPending = true
		self._bus:raiseIRQ(IRQ, { source = "fdc" })
		self.stats.irqs = self.stats.irqs + 1
	end
end

function Fdc765:getStats()
	return self.stats
end

function Fdc765:getStatus()
	return {
		motor = self._motorOn,
		head = self._headPosition,
		media = self._mediaType.size,
		msr = self._msr,
	}
end

return Fdc765
