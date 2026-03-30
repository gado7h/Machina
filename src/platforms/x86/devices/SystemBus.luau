-- SystemBus module

local SystemBus = {}
SystemBus.__index = SystemBus

local MachineProfile = require("@src/platforms/x86/MachineProfile")

local function defaultTickDt(config)
	local hz = math.max(config.CPU_CLOCK_HZ or 1, config.DISPLAY_REFRESH_HZ or 60)
	return 1 / math.max(1, hz)
end

function SystemBus.new(config)
	local self = setmetatable({}, SystemBus)
	self.config = config
	self._devices = {} -- name -> device object
	self._memmap = {} -- {base, size, device, tag, readOnly}
	self._portmap = {} -- port_number -> handler function
	self._irqLines = {} -- registered IRQ callbacks: irq_num -> {handler, device, count, active}
	self._dmaQueue = {} -- pending DMA transfers
	self._logs = {}
	self._fault = nil
	self._lastMemMapping = nil
	self._defaultDt = defaultTickDt(config)
	self._a20Enabled = true
	self._postCode = 0xFF
	self._trace = MachineProfile.getTraceConfig(config)

	-- Statistics
	self.stats = {
		memReads = 0,
		memWrites = 0,
		portReads = 0,
		portWrites = 0,
		irqFired = 0,
		irqDelivered = 0,
		dmaBytes = 0,
		faults = 0,
	}

	local Pic8259Module = require("@src/platforms/x86/devices/Pic8259")
	local Pit8254Module = require("@src/platforms/x86/devices/Pit8254")
	local Fdc765Module = require("@src/platforms/x86/devices/Fdc765")
	self.pic = Pic8259Module.new(config)
	self.timer = Pit8254Module.new(config)
	self.fdc = Fdc765Module.new(config)
	self._devices.pic = self.pic
	self._devices.timer = self.timer
	self._devices.fdc = self.fdc
	self.pic:attachBus(self)
	self.timer:attachBus(self)
	self.fdc:attachBus(self)

	self:registerPort(0x80, function()
		return self._postCode or 0xFF
	end, function(v)
		self._postCode = bit32.band(tonumber(v) or 0, 0xFF)
	end, "POST Code")

	self:registerPort(0x92, function()
		return bit32.bor(0, (self._a20Enabled and 0x02 or 0))
	end, function(v)
		self._a20Enabled = (bit32.band(v, 0x02) ~= 0)
	end, "Fast A20")

	return self
end

function SystemBus:setA20Enabled(enabled)
	self._a20Enabled = enabled
	self:_log("BUS", "A20 gate " .. (enabled and "enabled" or "disabled"))
end

function SystemBus:isA20Enabled()
	return self._a20Enabled
end

local function physicalAddress(self, addr)
	local address = (tonumber(addr) or 0) % 0x100000000
	if self._a20Enabled then
		return address
	end
	return bit32.band(address, bit32.bnot(0x00100000))
end

-- Device Registration

function SystemBus:registerDevice(name, device)
	assert(not self._devices[name], "SystemBus: device '" .. name .. "' already registered")
	self._devices[name] = device
	if name == "cpu" then
		self._cpu = device
	end
	if device and type(device.attachBus) == "function" then
		pcall(function()
			device:attachBus(self)
		end)
	end
	self:_log("BUS", "Device registered: " .. name)
end

function SystemBus:getDevice(name)
	return self._devices[name]
end

-- Memory Map

-- device must implement :memRead(offset) and :memWrite(offset, value)
function SystemBus:mapMemory(base, size, device, tag, opts)
	opts = opts or {}
	local readOnly = opts.readOnly == true or (type(tag) == "string" and tag:find("ROM") ~= nil)
	table.insert(self._memmap, {
		base = base,
		size = size,
		device = device,
		tag = tag or "?",
		readOnly = readOnly,
	})
	table.sort(self._memmap, function(a, b)
		return a.base < b.base
	end)
	self._lastMemMapping = nil
	self:_log("BUS", string.format("Mapped [%08X-%08X] -> %s", base, base + size - 1, tag or "?"))
end

local function findMapping(self, addr)
	local cached = self._lastMemMapping
	if cached and addr >= cached.base and addr < cached.base + cached.size then
		return cached
	end

	for _, m in ipairs(self._memmap) do
		if addr >= m.base and addr < m.base + m.size then
			self._lastMemMapping = m
			return m
		end
	end

	self._lastMemMapping = nil
	return nil
end

local function rawPortRead(self, port, width)
	local h = self._portmap[port]
	if not h then
		return nil
	end
	if width == 1 and h.read then
		local ok, value = pcall(h.read)
		if ok then
			if self._trace.ENABLED == true and self._trace.PORT_IO == true then
				self:_log("PORT", string.format("IN  %04Xh -> %02Xh (%s)", port, (tonumber(value) or 0) % 0x100, h.label))
			end
			return (tonumber(value) or 0) % 0x100
		end
	elseif width == 2 and h.read16 then
		local ok, value = pcall(h.read16)
		if ok then
			if self._trace.ENABLED == true and self._trace.PORT_IO == true then
				self:_log("PORT", string.format("IN  %04Xh -> %04Xh (%s)", port, (tonumber(value) or 0) % 0x10000, h.label))
			end
			return (tonumber(value) or 0) % 0x10000
		end
	elseif width == 4 and h.read32 then
		local ok, value = pcall(h.read32)
		if ok then
			if self._trace.ENABLED == true and self._trace.PORT_IO == true then
				self:_log("PORT", string.format("IN  %04Xh -> %08Xh (%s)", port, (tonumber(value) or 0) % 0x100000000, h.label))
			end
			return (tonumber(value) or 0) % 0x100000000
		end
	end
	return nil
end

local function rawPortWrite(self, port, value, width)
	local h = self._portmap[port]
	if not h then
		return false
	end
	local masked = tonumber(value) or 0
	if width == 1 and h.write then
		local ok, err = pcall(h.write, masked % 0x100)
		if not ok then
			self:_setFault("port-write-fault", port, "out", err)
		elseif self._trace.ENABLED == true and self._trace.PORT_IO == true then
			self:_log("PORT", string.format("OUT %04Xh <- %02Xh (%s)", port, masked % 0x100, h.label))
		end
		return true
	elseif width == 2 and h.write16 then
		local ok, err = pcall(h.write16, masked % 0x10000)
		if not ok then
			self:_setFault("port-write-fault", port, "out16", err)
		elseif self._trace.ENABLED == true and self._trace.PORT_IO == true then
			self:_log("PORT", string.format("OUT %04Xh <- %04Xh (%s)", port, masked % 0x10000, h.label))
		end
		return true
	elseif width == 4 and h.write32 then
		local ok, err = pcall(h.write32, masked % 0x100000000)
		if not ok then
			self:_setFault("port-write-fault", port, "out32", err)
		elseif self._trace.ENABLED == true and self._trace.PORT_IO == true then
			self:_log("PORT", string.format("OUT %04Xh <- %08Xh (%s)", port, masked % 0x100000000, h.label))
		end
		return true
	end
	return false
end

function SystemBus:_setFault(kind, addr, op, detail)
	self.stats.faults = self.stats.faults + 1
	self._fault = {
		kind = kind,
		addr = addr,
		op = op,
		detail = detail,
		time = os.clock(),
	}
	self:_log(
		"BUS",
		string.format("FAULT %s op=%s addr=%08X (%s)", tostring(kind), tostring(op), addr or 0, tostring(detail))
	)
end

function SystemBus:peekFault()
	return self._fault
end

function SystemBus:consumeFault()
	local f = self._fault
	self._fault = nil
	return f
end

function SystemBus:memRead(addr)
	addr = physicalAddress(self, addr)
	self.stats.memReads = self.stats.memReads + 1
	local m = findMapping(self, addr)
	if not m then
		self:_setFault("unmapped-read", addr, "read8", "Address not mapped")
		return 0xFF
	end
	local ok, value = pcall(function()
		return m.device:memRead(addr - m.base)
	end)
	if not ok then
		self:_setFault("device-read-fault", addr, "read8", value)
		return 0xFF
	end
	if value == nil then
		self:_setFault("device-read-nil", addr, "read8", m.tag)
		return 0xFF
	end
	return (tonumber(value) or 0) % 256
end

function SystemBus:memWrite(addr, value)
	addr = physicalAddress(self, addr)
	self.stats.memWrites = self.stats.memWrites + 1
	local m = findMapping(self, addr)
	if not m then
		self:_setFault("unmapped-write", addr, "write8", "Address not mapped")
		return false
	end
	if m.readOnly then
		self:_setFault("readonly-write", addr, "write8", m.tag)
		return false
	end
	local ok, err = pcall(function()
		m.device:memWrite(addr - m.base, (tonumber(value) or 0) % 256)
	end)
	if not ok then
		self:_setFault("device-write-fault", addr, "write8", err)
		return false
	end
	return true
end

-- 32-bit word helpers
function SystemBus:memRead32(addr)
	local b0 = self:memRead(addr)
	local b1 = self:memRead(addr + 1)
	local b2 = self:memRead(addr + 2)
	local b3 = self:memRead(addr + 3)
	return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

function SystemBus:memWrite32(addr, value)
	local v = tonumber(value) or 0
	local ok0 = self:memWrite(addr, v % 256)
	local ok1 = self:memWrite(addr + 1, math.floor(v / 256) % 256)
	local ok2 = self:memWrite(addr + 2, math.floor(v / 65536) % 256)
	local ok3 = self:memWrite(addr + 3, math.floor(v / 16777216) % 256)
	return ok0 and ok1 and ok2 and ok3
end

-- Port I/O

function SystemBus:registerPort(port, readFn, writeFn, label, read16Fn, write16Fn, read32Fn, write32Fn)
	self._portmap[port] = {
		read = readFn,
		write = writeFn,
		read16 = read16Fn,
		write16 = write16Fn,
		read32 = read32Fn,
		write32 = write32Fn,
		label = label or string.format("0x%04X", port),
	}
end

function SystemBus:portRead(port)
	self.stats.portReads = self.stats.portReads + 1
	local value = rawPortRead(self, port, 1)
	if value ~= nil then
		return value
	end
	return 0xFF
end

function SystemBus:portWrite(port, value)
	self.stats.portWrites = self.stats.portWrites + 1
	rawPortWrite(self, port, value, 1)
end

function SystemBus:portRead16(port)
	self.stats.portReads = self.stats.portReads + 1
	local value = rawPortRead(self, port, 2)
	if value ~= nil then
		return value
	end
	local lo = rawPortRead(self, port, 1) or 0xFF
	local hi = rawPortRead(self, port + 1, 1) or 0xFF
	return lo + hi * 0x100
end

function SystemBus:portWrite16(port, value)
	self.stats.portWrites = self.stats.portWrites + 1
	local masked = (tonumber(value) or 0) % 0x10000
	if rawPortWrite(self, port, masked, 2) then
		return
	end
	rawPortWrite(self, port, masked % 0x100, 1)
	rawPortWrite(self, port + 1, math.floor(masked / 0x100) % 0x100, 1)
end

function SystemBus:portRead32(port)
	self.stats.portReads = self.stats.portReads + 1
	local value = rawPortRead(self, port, 4)
	if value ~= nil then
		return value
	end
	local lo = rawPortRead(self, port, 2) or 0xFFFF
	local hi = rawPortRead(self, port + 2, 2) or 0xFFFF
	return lo + hi * 0x10000
end

function SystemBus:portWrite32(port, value)
	self.stats.portWrites = self.stats.portWrites + 1
	local masked = (tonumber(value) or 0) % 0x100000000
	if rawPortWrite(self, port, masked, 4) then
		return
	end
	rawPortWrite(self, port, masked % 0x10000, 2)
	rawPortWrite(self, port + 2, math.floor(masked / 0x10000) % 0x10000, 2)
end

-- IRQ (Interrupt Request Lines)

function SystemBus:registerIRQ(irqNum, device, handler)
	if not self._irqLines[irqNum] then
		self._irqLines[irqNum] = {}
	end
	table.insert(self._irqLines[irqNum], { device = device, handler = handler, count = 0, active = false })
	self:_log("BUS", string.format("IRQ%d registered for device: %s", irqNum, tostring(device)))
end

-- Fire an interrupt: queue into PIC and notify registered IRQ callbacks.
function SystemBus:raiseIRQ(irqNum, data)
	self.stats.irqFired = self.stats.irqFired + 1
	if self.pic then
		self.pic:raiseIRQ(irqNum)
	end
	if self._trace.ENABLED == true and self._trace.IRQ_ROUTING == true then
		self:_log("IRQ", string.format("IRQ%d raised source=%s", irqNum, tostring(data and data.source or "?")))
	end

	local handlers = self._irqLines[irqNum]
	if not handlers then
		return
	end
	for _, h in ipairs(handlers) do
		h.count = h.count + 1
		h.active = true
		local ok, err = pcall(h.handler, irqNum, data)
		if not ok then
			self:_log("BUS", "IRQ handler error IRQ" .. irqNum .. ": " .. tostring(err))
		end
		h.active = false
	end
end

function SystemBus:hasPendingInterrupt()
	return self.pic and self.pic:hasPending() or false
end

function SystemBus:getPendingInterruptVector()
	if not self.pic then
		return nil
	end
	local vec = self.pic:getNextVector()
	if vec ~= nil then
		self.stats.irqDelivered = self.stats.irqDelivered + 1
		if self._trace.ENABLED == true and self._trace.IRQ_ROUTING == true then
			self:_log("IRQ", string.format("vector %02Xh delivered", vec))
		end
	end
	return vec
end

function SystemBus:endOfInterrupt(vector)
	if self.pic then
		return self.pic:endOfInterrupt(vector)
	end
	return false
end

function SystemBus:getIRQStats()
	local out = {}
	for irq, handlers in pairs(self._irqLines) do
		for _, h in ipairs(handlers) do
			table.insert(out, { irq = irq, device = tostring(h.device), count = h.count, active = h.active })
		end
	end
	return out
end

-- DMA (Direct Memory Access)

-- Enqueue a DMA transfer. src/dst are physical addresses; callback fires on completion.
function SystemBus:dmaTransfer(src, dst, length, callback)
	table.insert(self._dmaQueue, { src = src, dst = dst, length = length, cb = callback, done = false })
end

-- Process all pending DMA transfers.
function SystemBus:processDMA(dt)
	for _, xfer in ipairs(self._dmaQueue) do
		if not xfer.done then
			for off = 0, xfer.length - 1 do
				local byte = self:memRead(xfer.src + off)
				self:memWrite(xfer.dst + off, byte)
			end
			self.stats.dmaBytes = self.stats.dmaBytes + xfer.length
			xfer.done = true
			if xfer.cb then
				pcall(xfer.cb)
			end
		end
	end

	local live = {}
	for _, x in ipairs(self._dmaQueue) do
		if not x.done then
			table.insert(live, x)
		end
	end
	self._dmaQueue = live

	self:tick(dt)
end

function SystemBus:tick(dt)
	dt = tonumber(dt) or self._defaultDt
	if self.timer and type(self.timer.tick) == "function" then
		self.timer:tick(dt)
	end
	-- Let devices progress asynchronous operations.
	for name, device in pairs(self._devices) do
		if name ~= "timer" and name ~= "pic" and name ~= "cpu" and type(device.tick) == "function" then
			device:tick(dt)
		end
	end
end

-- Internal logging

function SystemBus:_log(tag, msg)
	local entry = string.format("[%s] %s", tag, msg)
	table.insert(self._logs, entry)
	if #self._logs > 500 then
		table.remove(self._logs, 1)
	end
end

function SystemBus:getLog(n)
	n = n or #self._logs
	local start = math.max(1, #self._logs - n + 1)
	local out = {}
	for i = start, #self._logs do
		table.insert(out, self._logs[i])
	end
	return out
end

function SystemBus:getStats()
	return self.stats
end

return SystemBus
