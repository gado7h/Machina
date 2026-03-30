local STATUS_A_UIP = 0x80
local STATUS_B_24H = 0x02
local STATUS_B_BINARY = 0x04
local STATUS_B_UIE = 0x10
local STATUS_B_PIE = 0x40
local STATUS_B_AIE = 0x20

local STATUS_C_UF = 0x10
local STATUS_C_AF = 0x20
local STATUS_C_PF = 0x40

local MachineProfile = require("@src/platforms/x86/MachineProfile")

local REGISTER_SECONDS = 0x00
local REGISTER_MINUTES = 0x02
local REGISTER_HOURS = 0x04
local REGISTER_WEEKDAY = 0x06
local REGISTER_DAY = 0x07
local REGISTER_MONTH = 0x08
local REGISTER_YEAR = 0x09

local REGISTER_STATUS_A = 0x0A
local REGISTER_STATUS_B = 0x0B
local REGISTER_STATUS_C = 0x0C
local REGISTER_STATUS_D = 0x0D

local REGISTER_DIAGNOSTIC = 0x0E
local REGISTER_SHUTDOWN = 0x0F
local REGISTER_FLOPPY_TYPE = 0x10
local REGISTER_HD_TYPE = 0x12
local REGISTER_EQUIPMENT = 0x14
local REGISTER_BASE_MEM_LOW = 0x15
local REGISTER_BASE_MEM_HIGH = 0x16
local REGISTER_EXT_MEM_LOW = 0x17
local REGISTER_EXT_MEM_HIGH = 0x18
local REGISTER_CENTURY = 0x32
local REGISTER_EXT_MEM_POST = 0x30

local PERIODIC_RATE_SECONDS = {
	[0x06] = 1 / 976.5625,
	[0x07] = 1 / 488.28125,
	[0x08] = 1 / 244.140625,
	[0x09] = 1 / 122.0703125,
	[0x0A] = 1 / 61.03515625,
	[0x0B] = 1 / 30.517578125,
	[0x0C] = 1 / 15.2587890625,
	[0x0D] = 1 / 7.8125,
	[0x0E] = 1 / 3.90625,
	[0x0F] = 1 / 1.953125,
}

local CmosRtc = {}
CmosRtc.__index = CmosRtc

local function baseMemoryKilobytes(config)
	local x86 = (config and config.X86) or {}
	local lowRamSize = tonumber(x86.LOW_RAM_SIZE) or 0xA0000
	return math.floor(math.max(0, lowRamSize) / 1024)
end

local function extendedMemoryKilobytes(config)
	local x86 = (config and config.X86) or {}
	local highRamSize = tonumber(x86.HIGH_RAM_SIZE) or 0
	if highRamSize <= 0 then
		return 0
	end
	return math.floor(highRamSize / 1024)
end

local function toBCD(value)
	local numericValue = tonumber(value) or 0
	return ((math.floor(numericValue / 10) % 10) * 16) + (numericValue % 10)
end

local function weekdayForOsDate(wday)
	if wday == 1 then
		return 7
	end
	return wday - 1
end

function CmosRtc.new(config)
	local self = setmetatable({}, CmosRtc)
	self.config = config
	self._index = 0
	self._nmiMasked = false
	self._statusA = 0x26
	self._statusB = STATUS_B_24H
	self._statusC = 0x00
	self._statusD = 0x80
	self._elapsed = 0
	self._periodicAccum = 0
	self._lastSecond = nil
	self._irqLatched = false

	self._cmos = {}
	self._cmos[REGISTER_DIAGNOSTIC] = 0x00
	self._cmos[REGISTER_SHUTDOWN] = 0x00
	self._cmos[REGISTER_CENTURY] = 0x20
	self:refreshHardwareTable(config)

	self.stats = {
		reads = 0,
		writes = 0,
	}
	return self
end

function CmosRtc:_periodicIntervalSeconds()
	return PERIODIC_RATE_SECONDS[bit32.band(self._statusA, 0x0F)]
end

function CmosRtc:_currentEpochSecond()
	return os.time(self:_timeTable())
end

function CmosRtc:_raiseIRQ(sourceMask)
	if not self._bus then
		return
	end
	if self._irqLatched then
		return
	end
	local enabled = false
	if bit32.band(sourceMask, STATUS_C_PF) ~= 0 and bit32.band(self._statusB, STATUS_B_PIE) ~= 0 then
		enabled = true
	end
	if bit32.band(sourceMask, STATUS_C_UF) ~= 0 and bit32.band(self._statusB, STATUS_B_UIE) ~= 0 then
		enabled = true
	end
	if bit32.band(sourceMask, STATUS_C_AF) ~= 0 and bit32.band(self._statusB, STATUS_B_AIE) ~= 0 then
		enabled = true
	end
	if not enabled then
		return
	end
	self._irqLatched = true
	self._bus:raiseIRQ(self.config.IRQ.RTC, { source = "rtc", status = sourceMask })
end

function CmosRtc:_setStatusC(bits)
	if bits == 0 then
		return
	end
	self._statusC = bit32.bor(self._statusC, bit32.band(bits, 0x70))
	self:_raiseIRQ(bits)
end

function CmosRtc:refreshHardwareTable(config)
	if config then
		self.config = config
	end

	local profile = MachineProfile.validateConfig(self.config)
	local floppyNibble = profile.floppy.nibble
	local baseMemK = baseMemoryKilobytes(self.config)
	local extMemK = extendedMemoryKilobytes(self.config)

	self._cmos[REGISTER_FLOPPY_TYPE] = bit32.lshift(floppyNibble, 4)
	self._cmos[REGISTER_HD_TYPE] = profile.ata.present and 0x47 or 0x00
	self._cmos[REGISTER_EQUIPMENT] = MachineProfile.getCmosEquipmentByte(self.config)
	self._cmos[REGISTER_BASE_MEM_LOW] = baseMemK % 256
	self._cmos[REGISTER_BASE_MEM_HIGH] = math.floor(baseMemK / 256) % 256
	self._cmos[REGISTER_EXT_MEM_LOW] = extMemK % 256
	self._cmos[REGISTER_EXT_MEM_HIGH] = math.floor(extMemK / 256) % 256
	self._cmos[REGISTER_EXT_MEM_POST] = extMemK % 256
	self._cmos[REGISTER_EXT_MEM_POST + 1] = math.floor(extMemK / 256) % 256
end

function CmosRtc:attachBus(bus)
	self._bus = bus
	bus:registerPort(self.config.PORT.RTC_INDEX, function()
		return bit32.bor(self._index, self._nmiMasked and 0x80 or 0x00)
	end, function(v)
		local value = bit32.band(tonumber(v) or 0, 0xFF)
		self._nmiMasked = bit32.band(value, 0x80) ~= 0
		self._index = bit32.band(value, 0x7F)
	end, "CmosRtc Index")
	bus:registerPort(self.config.PORT.RTC_DATA, function()
		return self:_readSelected()
	end, function(v)
		self:_writeSelected(v)
	end, "CmosRtc Data")
end

function CmosRtc:_timeTable()
	return os.date("*t")
end

function CmosRtc:_uipActive()
	return (os.clock() % 1) >= 0.998
end

function CmosRtc:_binaryMode()
	return bit32.band(self._statusB, STATUS_B_BINARY) ~= 0
end

function CmosRtc:_encodeClockValue(value)
	if self:_binaryMode() then
		return value % 0x100
	end
	return toBCD(value)
end

function CmosRtc:_readClockRegister(index)
	local now = self:_timeTable()
	if index == REGISTER_SECONDS then
		return self:_encodeClockValue(now.sec)
	end
	if index == REGISTER_MINUTES then
		return self:_encodeClockValue(now.min)
	end
	if index == REGISTER_HOURS then
		return self:_encodeClockValue(now.hour)
	end
	if index == REGISTER_WEEKDAY then
		return self:_encodeClockValue(weekdayForOsDate(now.wday))
	end
	if index == REGISTER_DAY then
		return self:_encodeClockValue(now.day)
	end
	if index == REGISTER_MONTH then
		return self:_encodeClockValue(now.month)
	end
	if index == REGISTER_YEAR then
		return self:_encodeClockValue(now.year % 100)
	end
	return nil
end

function CmosRtc:_readStatusRegister(index)
	if index == REGISTER_STATUS_A then
		local value = self._statusA
		if self:_uipActive() then
			return bit32.bor(value, STATUS_A_UIP)
		end
		return bit32.band(value, bit32.bnot(STATUS_A_UIP))
	end
	if index == REGISTER_STATUS_B then
		return self._statusB
	end
	if index == REGISTER_STATUS_C then
		local value = self._statusC
		self._statusC = 0
		self._irqLatched = false
		return value
	end
	if index == REGISTER_STATUS_D then
		return self._statusD
	end
	return nil
end

function CmosRtc:_readCmosRegister(index)
	return self._cmos[index] or 0
end

function CmosRtc:_writeCmosRegister(index, value)
	self._cmos[index] = bit32.band(tonumber(value) or 0, 0xFF)
end

function CmosRtc:_readSelected()
	self.stats.reads = self.stats.reads + 1

	local clockValue = self:_readClockRegister(self._index)
	if clockValue ~= nil then
		return clockValue
	end

	local statusValue = self:_readStatusRegister(self._index)
	if statusValue ~= nil then
		return statusValue
	end

	local cmosValue = self:_readCmosRegister(self._index)
	return cmosValue
end

function CmosRtc:readRegister(index)
	local previousIndex = self._index
	self._index = bit32.band(tonumber(index) or 0, 0x7F)
	local value = self:_readSelected()
	self._index = previousIndex
	return value
end

function CmosRtc:_writeSelected(value)
	self.stats.writes = self.stats.writes + 1
	local v = bit32.band(tonumber(value) or 0, 0xFF)
	if self._index == REGISTER_STATUS_A then
		self._statusA = bit32.band(v, 0x7F)
	elseif self._index == REGISTER_STATUS_B then
		self._statusB = v
	elseif self._index == REGISTER_STATUS_C then
		self._statusC = bit32.band(self._statusC, bit32.bnot(bit32.band(v, 0x70)))
	elseif self._index == REGISTER_STATUS_D then
		self._statusD = bit32.bor(bit32.band(v, 0x7F), 0x80)
	else
		self:_writeCmosRegister(self._index, v)
	end
end

function CmosRtc:_tickPeriodic(dt)
	local interval = self:_periodicIntervalSeconds()
	if not interval or interval <= 0 then
		return
	end

	self._periodicAccum = self._periodicAccum + dt
	while self._periodicAccum >= interval do
		self._periodicAccum = self._periodicAccum - interval
		self:_setStatusC(STATUS_C_PF)
	end
end

function CmosRtc:_tickUpdateEnded()
	local currentSecond = self:_currentEpochSecond()
	if self._lastSecond == nil then
		self._lastSecond = currentSecond
		return
	end

	if currentSecond <= self._lastSecond then
		return
	end

	self._lastSecond = currentSecond
	self:_setStatusC(STATUS_C_UF)
end

function CmosRtc:tick(dt)
	dt = tonumber(dt) or 0
	if dt <= 0 then
		return
	end

	self._elapsed = self._elapsed + dt
	self:_tickUpdateEnded()
	self:_tickPeriodic(dt)
end

function CmosRtc:getBIOSClockTicks()
	local now = self:_timeTable()
	local midnight = os.time({
		year = now.year,
		month = now.month,
		day = now.day,
		hour = 0,
		min = 0,
		sec = 0,
	})
	local seconds = math.max(0, os.time(now) - midnight)
	return math.floor(seconds * 18.20648)
end

function CmosRtc:getStats()
	return self.stats
end

return CmosRtc
