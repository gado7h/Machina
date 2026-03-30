local CHANNEL_OFFSETS = { 0, 1, 2 }

local Pit8254 = {}
Pit8254.__index = Pit8254

local function newChannel(defaultReload)
	return {
		reloadValue = defaultReload or 0,
		accessMode = 3,
		mode = 3,
		bcd = false,
		writeLatch = nil,
		readFlipFlop = 0,
		writeFlipFlop = 0,
		latchValue = nil,
		statusLatch = nil,
		accumulatedTicks = 0,
		running = true,
	}
end

local function effectiveReload(channel)
	local value = channel.reloadValue
	if value == 0 then
		return 0x10000
	end
	return value
end

function Pit8254.new(config)
	local self = setmetatable({}, Pit8254)
	self.config = config

	local timerConfig = config.TIMER or {}
	self._baseHz = timerConfig.BASE_HZ or 1193182
	self._channels = {
		[0] = newChannel(timerConfig.DEFAULT_DIVISOR or 0),
		[1] = newChannel(0),
		[2] = newChannel(0),
	}
	self._subTicks = 0
	self._enabled = true
	self._irqEnabled = true
	self.stats = {
		ticks = 0,
		irqs = 0,
	}
	return self
end

function Pit8254:_registerChannelPort(bus, basePort, index)
	bus:registerPort(basePort + CHANNEL_OFFSETS[index + 1], function()
		return self:_readChannel(index)
	end, function(v)
		self:_writeChannel(index, v)
	end, "PIT CH" .. tostring(index))
end

function Pit8254:attachBus(bus)
	self._bus = bus
	for _, index in ipairs({ 0, 1, 2 }) do
		self:_registerChannelPort(bus, self.config.PORT.PIT_CHAN0, index)
	end
	bus:registerPort(self.config.PORT.PIT_CMD, function()
		return 0
	end, function(v)
		self:_writeCommand(v)
	end, "PIT CMD")
end

function Pit8254:_currentCount(channel)
	local reload = effectiveReload(channel)
	if reload <= 0 then
		return 0
	end
	local phase = math.floor(channel.accumulatedTicks) % reload
	local count = reload - phase
	if count == reload then
		count = 0
	end
	return count % 0x10000
end

function Pit8254:_latchCount(channel)
	channel.latchValue = self:_currentCount(channel)
	channel.readFlipFlop = 0
end

function Pit8254:_latchStatus(channel)
	local output = self:_currentOutput(channel)
	local status = 0
	if output then
		status = bit32.bor(status, 0x80)
	end
	if channel.reloadValue == 0 and channel.writeFlipFlop == 0 and channel.writeLatch == nil then
		status = bit32.bor(status, 0x40)
	end
	status = bit32.bor(status, bit32.lshift(bit32.band(channel.accessMode, 0x03), 4))
	status = bit32.bor(status, bit32.lshift(bit32.band(channel.mode, 0x07), 1))
	if channel.bcd then
		status = bit32.bor(status, 0x01)
	end
	channel.statusLatch = status
end

function Pit8254:_currentOutput(channel)
	local reload = effectiveReload(channel)
	if reload <= 0 then
		return false
	end
	local phase = math.floor(channel.accumulatedTicks) % reload
	if channel.mode == 0 then
		return channel.accumulatedTicks >= reload
	end
	if channel.mode == 2 then
		return phase ~= reload - 1
	end
	if channel.mode == 3 then
		return phase < (reload / 2)
	end
	return true
end

function Pit8254:_readLatchedByte(channel, value)
	if channel.accessMode == 1 then
		return value % 0x100
	end
	if channel.accessMode == 2 then
		return math.floor(value / 0x100) % 0x100
	end

	local byteValue
	if channel.readFlipFlop == 0 then
		byteValue = value % 0x100
	else
		byteValue = math.floor(value / 0x100) % 0x100
	end

	channel.readFlipFlop = 1 - channel.readFlipFlop
	if channel.readFlipFlop == 0 then
		channel.latchValue = nil
	end

	return byteValue
end

function Pit8254:_readChannel(index)
	local channel = self._channels[index]
	if not channel then
		return 0
	end

	if channel.statusLatch ~= nil then
		local status = channel.statusLatch
		channel.statusLatch = nil
		return status
	end

	local value = channel.latchValue
	if value == nil then
		value = self:_currentCount(channel)
	end
	return self:_readLatchedByte(channel, value)
end

function Pit8254:_commitReload(channel, value)
	channel.reloadValue = value % 0x10000
	channel.accumulatedTicks = 0
	channel.running = true
	channel.latchValue = nil
	channel.statusLatch = nil
	channel.readFlipFlop = 0
end

function Pit8254:_writeChannel(index, value)
	local channel = self._channels[index]
	if not channel then
		return
	end

	local byteValue = bit32.band(tonumber(value) or 0, 0xFF)
	if channel.accessMode == 1 then
		self:_commitReload(channel, byteValue)
		return
	end
	if channel.accessMode == 2 then
		self:_commitReload(channel, bit32.lshift(byteValue, 8))
		return
	end

	if channel.writeFlipFlop == 0 then
		channel.writeLatch = byteValue
		channel.writeFlipFlop = 1
	else
		self:_commitReload(channel, channel.writeLatch + bit32.lshift(byteValue, 8))
		channel.writeLatch = nil
		channel.writeFlipFlop = 0
	end
end

function Pit8254:_writeCommand(value)
	local v = bit32.band(tonumber(value) or 0, 0xFF)
	local select = bit32.rshift(v, 6)
	if select == 3 then
		local latchCount = bit32.band(v, 0x02) == 0
		local latchStatus = bit32.band(v, 0x01) == 0
		for index = 0, 2 do
			local selectMask = bit32.lshift(1, index + 3)
			if bit32.band(v, selectMask) == 0 then
				local channel = self._channels[index]
				if channel then
					if latchCount then
						self:_latchCount(channel)
					end
					if latchStatus then
						self:_latchStatus(channel)
					end
				end
			end
		end
		return
	end

	local channel = self._channels[select]
	if not channel then
		return
	end

	local accessMode = bit32.band(bit32.rshift(v, 4), 0x03)
	local mode = bit32.band(bit32.rshift(v, 1), 0x07)
	if mode == 6 then
		mode = 2
	elseif mode == 7 then
		mode = 3
	end

	if accessMode == 0 then
		self:_latchCount(channel)
		return
	end

	channel.accessMode = accessMode
	channel.mode = mode
	channel.bcd = bit32.band(v, 0x01) ~= 0
	channel.writeLatch = nil
	channel.writeFlipFlop = 0
	channel.readFlipFlop = 0
	channel.latchValue = nil
	channel.statusLatch = nil
end

function Pit8254:_fireIRQ(count)
	if not self._bus or not self._irqEnabled or count <= 0 then
		return
	end
	for _ = 1, count do
		self._bus:raiseIRQ(self.config.IRQ.TIMER, { source = "pit", channel = 0 })
		self.stats.irqs = self.stats.irqs + 1
	end
end

function Pit8254:_tickChannel0(elapsedTicks)
	local channel = self._channels[0]
	if not channel or not channel.running then
		return
	end

	local reload = effectiveReload(channel)
	if reload <= 0 then
		return
	end

	local previous = channel.accumulatedTicks
	channel.accumulatedTicks = channel.accumulatedTicks + elapsedTicks

	if channel.mode == 0 then
		if previous < reload and channel.accumulatedTicks >= reload then
			channel.running = false
			self:_fireIRQ(1)
		end
		return
	end

	if channel.mode ~= 2 and channel.mode ~= 3 then
		return
	end

	local completed = math.floor(channel.accumulatedTicks / reload) - math.floor(previous / reload)
	if completed > 0 then
		self:_fireIRQ(completed)
	end
end

function Pit8254:_tickChannel(index, elapsedTicks)
	local channel = self._channels[index]
	if not channel or not channel.running then
		return
	end

	local reload = effectiveReload(channel)
	if reload <= 0 then
		return
	end

	if index == 0 then
		self:_tickChannel0(elapsedTicks)
		return
	end

	channel.accumulatedTicks = channel.accumulatedTicks + elapsedTicks
end

function Pit8254:tick(dt)
	self.stats.ticks = self.stats.ticks + 1
	if not self._enabled then
		return
	end

	dt = tonumber(dt) or 0
	if dt <= 0 then
		return
	end

	self._subTicks = self._subTicks + dt * self._baseHz
	local elapsedTicks = math.floor(self._subTicks)
	if elapsedTicks <= 0 then
		return
	end

	self._subTicks = self._subTicks - elapsedTicks
	for index = 0, 2 do
		self:_tickChannel(index, elapsedTicks)
	end
end

function Pit8254:memRead(offset)
	offset = tonumber(offset) or -1
	if offset == 0x00 then
		return self:_readChannel(0)
	end
	if offset == 0x01 then
		return self:_readChannel(1)
	end
	if offset == 0x02 then
		return self:_readChannel(2)
	end
	if offset == 0x03 then
		return 0
	end
	return 0
end

function Pit8254:memWrite(offset, value)
	offset = tonumber(offset) or -1
	if offset == 0x00 then
		self:_writeChannel(0, value)
	elseif offset == 0x01 then
		self:_writeChannel(1, value)
	elseif offset == 0x02 then
		self:_writeChannel(2, value)
	elseif offset == 0x03 then
		self:_writeCommand(value)
	end
end

function Pit8254:getStats()
	return self.stats
end

return Pit8254
