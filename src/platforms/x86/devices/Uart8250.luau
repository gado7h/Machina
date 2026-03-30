local Uart8250 = {}
Uart8250.__index = Uart8250

local IER_RX_AVAILABLE = 0x01
local IER_TX_EMPTY = 0x02

local IIR_NO_INTERRUPT = 0x01
local IIR_TX_EMPTY = 0x02
local IIR_RX_AVAILABLE = 0x04

local LCR_DLAB = 0x80
local MCR_LOOP = 0x10

local LSR_DATA_READY = 0x01
local LSR_THR_EMPTY = 0x20
local LSR_TX_EMPTY = 0x40

local TX_LOG_LIMIT = 4096

function Uart8250.new(config)
	local self = setmetatable({}, Uart8250)
	self.config = config
	self._bus = nil
	self._basePort = config.PORT.COM1_BASE
	self._irqLine = (config.IRQ and config.IRQ.COM1) or 4

	self._divisor = 12
	self._ier = 0x00
	self._iir = IIR_NO_INTERRUPT
	self._fcr = 0x00
	self._lcr = 0x03
	self._mcr = 0x00
	self._lsr = bit32.bor(LSR_THR_EMPTY, LSR_TX_EMPTY)
	self._msr = 0xB0
	self._scr = 0x00
	self._rxFifo = {}
	self._txLog = {}
	self._irqPending = false

	self.stats = {
		rxBytes = 0,
		txBytes = 0,
		irqs = 0,
	}

	return self
end

function Uart8250:attachBus(bus)
	self._bus = bus
	local base = self._basePort
	bus:registerPort(base + 0, function()
		return self:_readData()
	end, function(v)
		self:_writeData(v)
	end, "COM1 Data")
	bus:registerPort(base + 1, function()
		return self:_readIER()
	end, function(v)
		self:_writeIER(v)
	end, "COM1 IER")
	bus:registerPort(base + 2, function()
		return self:_readIIR()
	end, function(v)
		self:_writeFCR(v)
	end, "COM1 IIR/FCR")
	bus:registerPort(base + 3, function()
		return self._lcr
	end, function(v)
		self._lcr = bit32.band(tonumber(v) or 0, 0xFF)
	end, "COM1 LCR")
	bus:registerPort(base + 4, function()
		return self._mcr
	end, function(v)
		self._mcr = bit32.band(tonumber(v) or 0, 0xFF)
	end, "COM1 MCR")
	bus:registerPort(base + 5, function()
		return self:_readLSR()
	end, nil, "COM1 LSR")
	bus:registerPort(base + 6, function()
		return self._msr
	end, nil, "COM1 MSR")
	bus:registerPort(base + 7, function()
		return self._scr
	end, function(v)
		self._scr = bit32.band(tonumber(v) or 0, 0xFF)
	end, "COM1 SCR")
end

function Uart8250:_dlabEnabled()
	return bit32.band(self._lcr, LCR_DLAB) ~= 0
end

function Uart8250:_rxCount()
	return #self._rxFifo
end

function Uart8250:_updateIRQ()
	local reason = nil
	if self:_rxCount() > 0 and bit32.band(self._ier, IER_RX_AVAILABLE) ~= 0 then
		reason = IIR_RX_AVAILABLE
	elseif bit32.band(self._ier, IER_TX_EMPTY) ~= 0 then
		reason = IIR_TX_EMPTY
	end

	if reason then
		self._iir = reason
		if not self._irqPending and self._bus then
			self._irqPending = true
			self.stats.irqs = self.stats.irqs + 1
			self._bus:raiseIRQ(self._irqLine, { source = "serial", iir = reason })
		end
	else
		self._iir = IIR_NO_INTERRUPT
		self._irqPending = false
	end
end

function Uart8250:_readData()
	if self:_dlabEnabled() then
		return self._divisor % 0x100
	end

	local value = table.remove(self._rxFifo, 1) or 0
	if self:_rxCount() == 0 then
		self._lsr = bit32.band(self._lsr, bit32.bnot(LSR_DATA_READY))
	end
	self._irqPending = false
	self:_updateIRQ()
	return value
end

function Uart8250:_appendTxLog(value)
	self._txLog[#self._txLog + 1] = value
	if #self._txLog > TX_LOG_LIMIT then
		table.remove(self._txLog, 1)
	end
end

function Uart8250:_writeData(v)
	local value = bit32.band(tonumber(v) or 0, 0xFF)
	if self:_dlabEnabled() then
		self._divisor = bit32.bor(bit32.band(self._divisor, 0xFF00), value)
		return
	end
	if bit32.band(self._mcr, MCR_LOOP) ~= 0 then
		self:pushInputByte(value)
		return
	end
	self.stats.txBytes = self.stats.txBytes + 1
	self:_appendTxLog(value)
	self._lsr = bit32.bor(self._lsr, LSR_THR_EMPTY, LSR_TX_EMPTY)
	self._irqPending = false
	self:_updateIRQ()
end

function Uart8250:_readIER()
	if self:_dlabEnabled() then
		return bit32.rshift(self._divisor, 8) % 0x100
	end
	return self._ier
end

function Uart8250:_writeIER(v)
	local value = bit32.band(tonumber(v) or 0, 0xFF)
	if self:_dlabEnabled() then
		self._divisor = bit32.bor(bit32.band(self._divisor, 0x00FF), bit32.lshift(value, 8))
		return
	end
	self._ier = bit32.band(value, 0x0F)
	self._irqPending = false
	self:_updateIRQ()
end

function Uart8250:_readIIR()
	local value = self._iir
	if bit32.band(value, IIR_NO_INTERRUPT) == 0 and value == IIR_TX_EMPTY then
		self._irqPending = false
		self:_updateIRQ()
	end
	return value
end

function Uart8250:_writeFCR(v)
	local value = bit32.band(tonumber(v) or 0, 0xFF)
	self._fcr = value
	if bit32.band(value, 0x02) ~= 0 or bit32.band(value, 0x04) ~= 0 then
		self._rxFifo = {}
		self._lsr = bit32.band(self._lsr, bit32.bnot(LSR_DATA_READY))
	end
	self._irqPending = false
	self:_updateIRQ()
end

function Uart8250:_readLSR()
	return self._lsr
end

function Uart8250:pushInputByte(value)
	local byteValue = bit32.band(tonumber(value) or 0, 0xFF)
	self._rxFifo[#self._rxFifo + 1] = byteValue
	self._lsr = bit32.bor(self._lsr, LSR_DATA_READY)
	self.stats.rxBytes = self.stats.rxBytes + 1
	self:_updateIRQ()
end

function Uart8250:pushInput(text)
	local normalized = tostring(text)
	for index = 1, #normalized do
		self:pushInputByte(string.byte(normalized, index))
	end
end

function Uart8250:readOutput()
	local chars = {}
	for index = 1, #self._txLog do
		chars[index] = string.char(self._txLog[index])
	end
	return table.concat(chars)
end

function Uart8250:drainOutputBytes()
	local out = self._txLog
	self._txLog = {}
	return out
end

function Uart8250:getStats()
	return self.stats
end

return Uart8250
