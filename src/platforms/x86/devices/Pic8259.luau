local PIC_INIT = 0x10
local PIC_OCW3 = 0x08
local PIC_OCW3_REGISTER_SELECT = 0x02
local PIC_OCW3_ISR = 0x01

local PIC_COMMAND_MASK = 0xE0
local PIC_EOI_NONSPECIFIC = 0x20
local PIC_EOI_SPECIFIC = 0x60
local PIC_EOI_ROTATE = 0xA0

local Pic8259 = {}
Pic8259.__index = Pic8259

local function bit(mask, index)
	return bit32.band(mask, bit32.lshift(1, index)) ~= 0
end

local function clearBit(mask, index)
	return bit32.band(mask, bit32.bnot(bit32.lshift(1, index)))
end

local function setBit(mask, index)
	return bit32.bor(mask, bit32.lshift(1, index))
end

local function newChip(defaultBase)
	return {
		vectorBase = defaultBase,
		imr = 0x00,
		irr = 0x00,
		isr = 0x00,
		readRegister = "IRR",
		priorityAdd = 0,
		initStep = 0,
		icw4Needed = false,
		singleMode = false,
		icw3 = 0,
		autoEOI = false,
	}
end

local function priorityOrder(chip, slot)
	return (chip.priorityAdd + slot) % 8
end

local function highestPriorityBit(chip, mask)
	for slot = 0, 7 do
		local irq = priorityOrder(chip, slot)
		if bit(mask, irq) then
			return irq
		end
	end
	return nil
end

local function highestInService(chip)
	return highestPriorityBit(chip, chip.isr)
end

local function nextDeliverableIRQ(chip)
	local pending = bit32.band(chip.irr, bit32.bnot(chip.imr))
	if pending == 0 then
		return nil
	end

	local inService = highestInService(chip)
	if inService == nil then
		return highestPriorityBit(chip, pending)
	end

	for slot = 0, 7 do
		local irq = priorityOrder(chip, slot)
		if irq == inService then
			break
		end
		if bit(pending, irq) then
			return irq
		end
	end

	return nil
end

local function acknowledgeIRQ(chip, irq)
	chip.irr = clearBit(chip.irr, irq)
	if not chip.autoEOI then
		chip.isr = setBit(chip.isr, irq)
	end
end

local function nonspecificEOI(chip)
	local irq = highestInService(chip)
	if irq ~= nil then
		chip.isr = clearBit(chip.isr, irq)
	end
	return irq
end

function Pic8259.new(config)
	local self = setmetatable({}, Pic8259)
	self.config = config
	self.master = newChip(config.PIC_VECTOR_BASE_MASTER or 0x20)
	self.slave = newChip(config.PIC_VECTOR_BASE_SLAVE or 0x28)
	self.master.icw3 = 0x04
	self.slave.icw3 = 0x02
	self.stats = {
		raised = 0,
		delivered = 0,
		eoi = 0,
		spurious = 0,
	}
	return self
end

function Pic8259:_registerChip(bus, chip, commandPort, dataPort, label)
	bus:registerPort(commandPort, function()
		return self:_readCommand(chip)
	end, function(v)
		self:_writeCommand(chip, v)
	end, label .. " CMD")
	bus:registerPort(dataPort, function()
		return chip.imr
	end, function(v)
		self:_writeData(chip, v)
	end, label .. " DATA")
end

function Pic8259:attachBus(bus)
	self._bus = bus
	self:_registerChip(
		bus,
		self.master,
		self.config.PORT.PIC_MASTER_CMD,
		self.config.PORT.PIC_MASTER_DATA,
		"Pic8259 Master"
	)
	self:_registerChip(
		bus,
		self.slave,
		self.config.PORT.PIC_SLAVE_CMD,
		self.config.PORT.PIC_SLAVE_DATA,
		"Pic8259 Slave"
	)
end

function Pic8259:raiseIRQ(irqNum)
	irqNum = tonumber(irqNum) or -1
	if irqNum < 0 or irqNum > 15 then
		self.stats.spurious = self.stats.spurious + 1
		return false
	end

	self.stats.raised = self.stats.raised + 1
	if irqNum < 8 then
		self.master.irr = setBit(self.master.irr, irqNum)
	else
		self.slave.irr = setBit(self.slave.irr, irqNum - 8)
		self.master.irr = setBit(self.master.irr, 2)
	end

	return true
end

function Pic8259:hasPending()
	return self:_nextMasterIRQ() ~= nil
end

function Pic8259:_nextMasterIRQ()
	local pending = bit32.band(self.master.irr, bit32.bnot(self.master.imr))
	if pending == 0 then
		return nil
	end

	local inService = highestInService(self.master)
	for slot = 0, 7 do
		local irq = priorityOrder(self.master, slot)
		if inService ~= nil and irq == inService then
			break
		end
		if bit(pending, irq) and (irq ~= 2 or nextDeliverableIRQ(self.slave) ~= nil) then
			return irq
		end
	end

	return nil
end

function Pic8259:getNextVector()
	local masterIRQ = self:_nextMasterIRQ()
	if masterIRQ == nil then
		return nil
	end

	if masterIRQ == 2 then
		local slaveIRQ = nextDeliverableIRQ(self.slave)
		if slaveIRQ ~= nil then
			acknowledgeIRQ(self.master, 2)
			acknowledgeIRQ(self.slave, slaveIRQ)
			if self.slave.irr == 0 then
				self.master.irr = clearBit(self.master.irr, 2)
			end
			self.stats.delivered = self.stats.delivered + 1
			return (self.slave.vectorBase + slaveIRQ) % 0x100
		end
	end

	acknowledgeIRQ(self.master, masterIRQ)
	self.stats.delivered = self.stats.delivered + 1
	return (self.master.vectorBase + masterIRQ) % 0x100
end

function Pic8259:endOfInterrupt(vector)
	vector = tonumber(vector) or -1
	if vector >= self.slave.vectorBase and vector < self.slave.vectorBase + 8 then
		local irq = vector - self.slave.vectorBase
		self.slave.isr = clearBit(self.slave.isr, irq)
		self.master.isr = clearBit(self.master.isr, 2)
		self.stats.eoi = self.stats.eoi + 1
		return true
	end

	if vector >= self.master.vectorBase and vector < self.master.vectorBase + 8 then
		local irq = vector - self.master.vectorBase
		self.master.isr = clearBit(self.master.isr, irq)
		self.stats.eoi = self.stats.eoi + 1
		return true
	end

	return false
end

function Pic8259:_readCommand(chip)
	return chip.readRegister == "ISR" and chip.isr or chip.irr
end

function Pic8259:_writeCommand(chip, value)
	local v = bit32.band(tonumber(value) or 0, 0xFF)

	if bit32.band(v, PIC_INIT) ~= 0 then
		chip.initStep = 1
		chip.icw4Needed = bit32.band(v, 0x01) ~= 0
		chip.singleMode = bit32.band(v, 0x02) ~= 0
		chip.irr = 0
		chip.isr = 0
		return
	end

	if bit32.band(v, PIC_OCW3) ~= 0 then
		if bit32.band(v, PIC_OCW3_REGISTER_SELECT) ~= 0 then
			chip.readRegister = bit32.band(v, PIC_OCW3_ISR) ~= 0 and "ISR" or "IRR"
		end
		return
	end

	local command = bit32.band(v, PIC_COMMAND_MASK)
	if command == PIC_EOI_NONSPECIFIC then
		if nonspecificEOI(chip) ~= nil then
			self.stats.eoi = self.stats.eoi + 1
		end
		return
	end

	if command == PIC_EOI_SPECIFIC then
		chip.isr = clearBit(chip.isr, bit32.band(v, 0x07))
		self.stats.eoi = self.stats.eoi + 1
		return
	end

	if command == PIC_EOI_ROTATE then
		chip.isr = clearBit(chip.isr, bit32.band(v, 0x07))
		chip.priorityAdd = (bit32.band(v, 0x07) + 1) % 8
		self.stats.eoi = self.stats.eoi + 1
	end
end

function Pic8259:_writeData(chip, value)
	local v = bit32.band(tonumber(value) or 0, 0xFF)
	if chip.initStep == 1 then
		chip.vectorBase = bit32.band(v, 0xF8)
		chip.initStep = 2
		return
	end
	if chip.initStep == 2 then
		chip.icw3 = v
		chip.initStep = chip.icw4Needed and 3 or 0
		return
	end
	if chip.initStep == 3 then
		chip.autoEOI = bit32.band(v, 0x02) ~= 0
		chip.initStep = 0
		return
	end
	chip.imr = v
end

function Pic8259:getStats()
	return self.stats
end

return Pic8259
