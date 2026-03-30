-- FirmwareRom module

local FirmwareRom = {}
FirmwareRom.__index = FirmwareRom

function FirmwareRom.new(config)
	local self = setmetatable({}, FirmwareRom)
	self.config = config
	self.size = config.ROM_SIZE or 0
	self._data = {} -- offset â†’ byte
	self._locked = true -- write-protected by default
	self._unlockSeq = { 0xAA, 0x55, 0xA0 } -- must write to 0x5555, 0x2AAA, 0x5555
	self._unlockStep = 0
	self.stats = { reads = 0, writeAttempts = 0, programOps = 0 }
	return self
end

--- Load a firmware image (table of bytes) into FirmwareRom.
--- Called by the system builder before powering on.
function FirmwareRom:flash(bytes)
	self._locked = false
	for i, b in ipairs(bytes) do
		self._data[i - 1] = b % 256
	end
	self._locked = true
	self.stats.programOps = self.stats.programOps + 1
end

--- Load a firmware image from a Lua string.
function FirmwareRom:flashString(str)
	local bytes = {}
	for i = 1, #str do
		bytes[i] = string.byte(str, i)
	end
	self:flash(bytes)
end

function FirmwareRom:memRead(offset)
	self.stats.reads = self.stats.reads + 1
	return self._data[offset] or 0xFF -- unprogrammed NOR = 0xFF
end

function FirmwareRom:memWrite(offset, value)
	self.stats.writeAttempts = self.stats.writeAttempts + 1
	-- Implement AMD/SST-style unlock sequence for flash programming
	if self._locked then
		return
	end -- silently ignore when locked
	self._data[offset] = value % 256
end

function FirmwareRom:readRegion(offset, length)
	local out = {}
	for i = 0, length - 1 do
		table.insert(out, self._data[offset + i] or 0xFF)
	end
	return out
end

--- Dump FirmwareRom contents as hex string for debugging.
function FirmwareRom:hexDump(offset, length)
	local lines = {}
	local line = {}
	for i = 0, length - 1 do
		table.insert(line, string.format("%02X", self._data[offset + i] or 0xFF))
		if #line == 16 then
			table.insert(lines, string.format("%04X: %s", offset + i - 15, table.concat(line, " ")))
			line = {}
		end
	end
	if #line > 0 then
		table.insert(lines, string.format("%04X: %s", offset + length - #line, table.concat(line, " ")))
	end
	return lines
end

function FirmwareRom:getStats()
	return self.stats
end
function FirmwareRom:getSize()
	return self.size
end

return FirmwareRom
