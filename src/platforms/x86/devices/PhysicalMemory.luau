-- PhysicalMemory module

local DEFAULT_PAGE_SIZE = 4096

local PhysicalMemory = {}
PhysicalMemory.__index = PhysicalMemory

local function pageSizeFor(config)
	return config.PAGE_SIZE or DEFAULT_PAGE_SIZE
end

local function markDirtyRange(self, offset, length)
	local pageSize = pageSizeFor(self.config)
	if pageSize <= 0 or length <= 0 then
		return
	end
	local firstPage = math.floor(offset / pageSize)
	local lastPage = math.floor((offset + length - 1) / pageSize)
	for page = firstPage, lastPage do
		self._dirty[page] = true
	end
end

function PhysicalMemory.new(config)
	local self = setmetatable({}, PhysicalMemory)
	self.config = config
	self.size = config.RAM_SIZE or config.LOW_RAM_SIZE or 0
	self._mem = {}
	self._dirty = {}
	self.stats = { reads = 0, writes = 0, eccCorrections = 0 }
	return self
end

function PhysicalMemory:memRead(offset)
	self.stats.reads = self.stats.reads + 1
	return self._mem[offset] or 0
end

function PhysicalMemory:memWrite(offset, value)
	self.stats.writes = self.stats.writes + 1
	self._mem[offset] = value % 256
	markDirtyRange(self, offset, 1)
end

function PhysicalMemory:readRegion(offset, length)
	local out = {}
	for index = 1, length do
		out[index] = self._mem[offset + index - 1] or 0
	end
	return out
end

function PhysicalMemory:writeRegion(offset, bytes)
	local length = #bytes
	for index, byteValue in ipairs(bytes) do
		self._mem[offset + index - 1] = byteValue % 256
	end
	self.stats.writes = self.stats.writes + length
	markDirtyRange(self, offset, length)
end

function PhysicalMemory:clear(offset, length)
	for index = 0, length - 1 do
		self._mem[offset + index] = 0
	end
	self.stats.writes = self.stats.writes + length
	markDirtyRange(self, offset, length)
end

function PhysicalMemory:getUsedBytes()
	local count = 0
	for _ in pairs(self._mem) do
		count = count + 1
	end
	return count
end

function PhysicalMemory:getDirtyPageCount()
	local count = 0
	for _ in pairs(self._dirty) do
		count = count + 1
	end
	return count
end

function PhysicalMemory:clearDirty()
	self._dirty = {}
end

function PhysicalMemory:getStats()
	return self.stats
end

return PhysicalMemory
