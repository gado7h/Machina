local Cpu8086 = require("@src/platforms/x86/Cpu8086")

local Cpu80386 = {}
Cpu80386.__index = Cpu80386
setmetatable(Cpu80386, { __index = Cpu8086 })

local FLAG_CF = 0x0001
local FLAG_PF = 0x0004
local FLAG_AF = 0x0010
local FLAG_ZF = 0x0040
local FLAG_SF = 0x0080
local FLAG_IF = 0x0200
local FLAG_DF = 0x0400
local FLAG_OF = 0x0800
local FLAG_TF = 0x0100
local FLAGS16_WRITE_MASK = 0x0FD5
local EFLAGS_WRITE_MASK = 0x3F7FD5

local VECTOR_DE = 0
local VECTOR_UD = 6
local VECTOR_TS = 10
local VECTOR_NP = 11
local VECTOR_SS = 12
local VECTOR_GP = 13

local REG32 = {
	"EAX",
	"ECX",
	"EDX",
	"EBX",
	"ESP",
	"EBP",
	"ESI",
	"EDI",
}

local SEGMENT_NAMES = { "ES", "CS", "SS", "DS", "FS", "GS" }
local SEGMENT_CODE_BY_NAME = {
	ES = 0,
	CS = 1,
	SS = 2,
	DS = 3,
	FS = 4,
	GS = 5,
}

local SEGMENT_PREFIX_TO_CODE = {
	[0x26] = 0,
	[0x2E] = 1,
	[0x36] = 2,
	[0x3E] = 3,
	[0x64] = 4,
	[0x65] = 5,
}

local function signExtend8(value)
	value = value % 0x100
	if value >= 0x80 then
		return value - 0x100
	end
	return value
end

local function signExtend16(value)
	value = value % 0x10000
	if value >= 0x8000 then
		return value - 0x10000
	end
	return value
end

local function signExtend32(value)
	value = value % 0x100000000
	if value >= 0x80000000 then
		return value - 0x100000000
	end
	return value
end

local function maskForWidth(width)
	if width == 8 then
		return 0xFF
	elseif width == 16 then
		return 0xFFFF
	end
	return 0xFFFFFFFF
end

local function signBit(width)
	if width == 8 then
		return 0x80
	elseif width == 16 then
		return 0x8000
	end
	return 0x80000000
end

local function toSigned(width, value)
	local base = maskForWidth(width) + 1
	local signedLimit = base / 2
	local masked = (tonumber(value) or 0) % base
	if masked >= signedLimit then
		return masked - base
	end
	return masked
end

local function mulUnsigned32(a, b)
	a = (tonumber(a) or 0) % 0x100000000
	b = (tonumber(b) or 0) % 0x100000000
	local a0 = a % 0x10000
	local a1 = math.floor(a / 0x10000)
	local b0 = b % 0x10000
	local b1 = math.floor(b / 0x10000)
	local p0 = a0 * b0
	local p1 = a0 * b1 + a1 * b0
	local p2 = a1 * b1
	local loLow = p0 % 0x10000
	local mid = math.floor(p0 / 0x10000) + (p1 % 0x10000)
	local loHigh = mid % 0x10000
	local hi = (p2 + math.floor(p1 / 0x10000) + math.floor(mid / 0x10000)) % 0x100000000
	local lo = loLow + loHigh * 0x10000
	return hi, lo
end

local function negate64(hi, lo)
	local nextLo = -((tonumber(lo) or 0) % 0x100000000) % 0x100000000
	local carry = nextLo == 0 and 1 or 0
	local nextHi = (bit32.band(bit32.bnot((tonumber(hi) or 0) % 0x100000000), 0xFFFFFFFF) + carry) % 0x100000000
	return nextHi, nextLo
end

local function absSigned64(hi, lo)
	hi = (tonumber(hi) or 0) % 0x100000000
	lo = (tonumber(lo) or 0) % 0x100000000
	if bit32.band(hi, 0x80000000) == 0 then
		return hi, lo, false
	end
	local absHi, absLo = negate64(hi, lo)
	return absHi, absLo, true
end

local function divUnsigned64By32(hi, lo, divisor)
	hi = (tonumber(hi) or 0) % 0x100000000
	lo = (tonumber(lo) or 0) % 0x100000000
	divisor = (tonumber(divisor) or 0) % 0x100000000
	local remainder = 0
	local quotient = 0
	local overflow = false
	for bitIndex = 63, 0, -1 do
		local incoming
		if bitIndex >= 32 then
			incoming = bit32.band(bit32.rshift(hi, bitIndex - 32), 0x1)
		else
			incoming = bit32.band(bit32.rshift(lo, bitIndex), 0x1)
		end
		remainder = remainder * 2 + incoming
		if remainder >= divisor then
			remainder = remainder - divisor
			if bitIndex >= 32 then
				overflow = true
			else
				quotient = bit32.bor(quotient, bit32.lshift(1, bitIndex))
			end
		end
	end
	return quotient % 0x100000000, remainder % 0x100000000, overflow
end

function Cpu80386.new(bus, config)
	local self = Cpu8086.new(bus, config)
	setmetatable(self, Cpu80386)
	self.seg.FS = self.seg.FS or 0
	self.seg.GS = self.seg.GS or 0
	self.gdtr = { base = 0, limit = 0 }
	self.idtr = { base = 0, limit = 0x03FF }
	self.tr = { selector = 0, base = 0, limit = 0, present = false, busy = false }
	self.cr0 = 0x0010
	self.protectedMode = false
	self.segCache = {}
	self.reg32 = {}
	self.eip = 0
	self:reset()
	return self
end

function Cpu80386:_segmentName(code)
	return SEGMENT_NAMES[(tonumber(code) or 0) + 1]
end

function Cpu80386:getSeg(code)
	local name = self:_segmentName(code)
	return (name and self.seg[name]) or 0
end

function Cpu80386:_writeSegmentRegister(name, value)
	if not name then
		return
	end
	self.seg[name] = (tonumber(value) or 0) % 0x10000
end

function Cpu80386:_makeNullSegmentDescriptor(name)
	return {
		code = SEGMENT_CODE_BY_NAME[name],
		selector = 0,
		base = 0,
		limit = 0,
		default32 = false,
		present = true,
		unusable = true,
		kind = "null",
		name = name,
	}
end

function Cpu80386:_syncRealModeSegment(name)
	local selector = self.seg[name] or 0
	self.segCache[name] = {
		selector = selector,
		base = (selector % 0x10000) * 16,
		limit = 0xFFFF,
		default32 = false,
		present = true,
		unusable = false,
	}
end

function Cpu80386:_syncRealModeCaches()
	for _, name in ipairs(SEGMENT_NAMES) do
		self:_syncRealModeSegment(name)
	end
end

function Cpu80386:reset()
	Cpu8086.reset(self)
	self.seg.FS = 0
	self.seg.GS = 0
	self.reg32 = {
		EAX = 0,
		ECX = 0,
		EDX = 0,
		EBX = 0,
		ESP = 0,
		EBP = 0,
		ESI = 0,
		EDI = 0,
	}
	self.gdtr = { base = 0, limit = 0 }
	self.idtr = { base = 0, limit = 0x03FF }
	self.tr = { selector = 0, base = 0, limit = 0, present = false, busy = false }
	self.cr0 = 0x0010
	self.protectedMode = false
	self.segCache = {}
	self.eip = self.ip
	self:_syncRealModeCaches()
end

function Cpu80386:_codeDefault32()
	return self.protectedMode and self.segCache.CS and self.segCache.CS.default32 or false
end

function Cpu80386:_stackDefault32()
	return self.protectedMode and self.segCache.SS and self.segCache.SS.default32 or false
end

function Cpu80386:_currentIP()
	if self:_codeDefault32() then
		return (tonumber(self.eip) or 0) % 0x100000000
	end
	return (tonumber(self.ip) or 0) % 0x10000
end

function Cpu80386:_setInstructionPointer(value)
	local nextValue = tonumber(value) or 0
	if self:_codeDefault32() then
		self.eip = nextValue % 0x100000000
		self.ip = self.eip % 0x10000
	else
		self.ip = nextValue % 0x10000
		self.eip = self.ip
	end
end

function Cpu80386:getReg32(code)
	local name = REG32[(tonumber(code) or 0) + 1]
	if not name then
		return 0
	end
	return (self.reg32 and self.reg32[name] or 0) % 0x100000000
end

function Cpu80386:setReg32(code, value)
	local name = REG32[(tonumber(code) or 0) + 1]
	if not name then
		return
	end
	local masked = (tonumber(value) or 0) % 0x100000000
	self.reg32[name] = masked
	Cpu8086.setReg16(self, code, masked % 0x10000)
end

function Cpu80386:getReg16(code)
	return self:getReg32(code) % 0x10000
end

function Cpu80386:setReg16(code, value)
	local index = (tonumber(code) or 0)
	local name = REG32[index + 1]
	local masked = (tonumber(value) or 0) % 0x10000
	if name then
		local current = self.reg32[name] or 0
		self.reg32[name] = bit32.bor(bit32.band(current, 0xFFFF0000), masked)
	end
	Cpu8086.setReg16(self, index, masked)
end

function Cpu80386:getReg8(code)
	local regIndex = (tonumber(code) or 0) % 4
	local word = self:getReg16(regIndex)
	if code < 4 then
		return word % 0x100
	end
	return math.floor(word / 0x100) % 0x100
end

function Cpu80386:setReg8(code, value)
	local regIndex = (tonumber(code) or 0) % 4
	local word = self:getReg16(regIndex)
	local byteValue = (tonumber(value) or 0) % 0x100
	if code < 4 then
		self:setReg16(regIndex, bit32.bor(bit32.band(word, 0xFF00), byteValue))
	else
		self:setReg16(regIndex, bit32.bor(bit32.band(word, 0x00FF), bit32.lshift(byteValue, 8)))
	end
end

function Cpu80386:getLinearPC()
	return self:linearAddress("CS", self:_currentIP())
end

function Cpu80386:getStats()
	local stats = Cpu8086.getStats(self)
	stats.mode = self.protectedMode and "protected" or "real"
	stats.protectedMode = self.protectedMode
	stats.cr0 = self.cr0
	stats.gdtBase = self.gdtr.base
	stats.gdtLimit = self.gdtr.limit
	stats.idtBase = self.idtr.base
	stats.idtLimit = self.idtr.limit
	stats.trSelector = self.tr and self.tr.selector or 0
	stats.eip = self.eip
	stats.esp = self:getReg32(4)
	return stats
end

function Cpu80386:_physicalAddress(address)
	return (tonumber(address) or 0) % 0x100000000
end

function Cpu80386:readPhysical8(address)
	self.stats.memReads = self.stats.memReads + 1
	return self.bus:memRead(self:_physicalAddress(address))
end

function Cpu80386:writePhysical8(address, value)
	self.stats.memWrites = self.stats.memWrites + 1
	self.bus:memWrite(self:_physicalAddress(address), value % 0x100)
end

function Cpu80386:readPhysical16(address)
	local lo = self:readPhysical8(address)
	local hi = self:readPhysical8(address + 1)
	return lo + hi * 0x100
end

function Cpu80386:readPhysical32(address)
	local b0 = self:readPhysical8(address)
	local b1 = self:readPhysical8(address + 1)
	local b2 = self:readPhysical8(address + 2)
	local b3 = self:readPhysical8(address + 3)
	return b0 + b1 * 0x100 + b2 * 0x10000 + b3 * 0x1000000
end

function Cpu80386:writePhysical16(address, value)
	local v = (tonumber(value) or 0) % 0x10000
	self:writePhysical8(address, v % 0x100)
	self:writePhysical8(address + 1, math.floor(v / 0x100) % 0x100)
end

function Cpu80386:writePhysical32(address, value)
	local v = (tonumber(value) or 0) % 0x100000000
	self:writePhysical8(address, v % 0x100)
	self:writePhysical8(address + 1, math.floor(v / 0x100) % 0x100)
	self:writePhysical8(address + 2, math.floor(v / 0x10000) % 0x100)
	self:writePhysical8(address + 3, math.floor(v / 0x1000000) % 0x100)
end

function Cpu80386:readMem32(segment, offset)
	return self:readPhysical32(self:linearAddress(segment, offset))
end

function Cpu80386:writeMem32(segment, offset, value)
	self:writePhysical32(self:linearAddress(segment, offset), value)
end

function Cpu80386:push16(value)
	local sp = self:_stackDefault32() and self:getReg32(4) or self:getReg16(4)
	sp = (sp - 2) % 0x100000000
	if self:_stackDefault32() then
		self:setReg32(4, sp)
	else
		self:setReg16(4, sp % 0x10000)
	end
	self:writeMem16(self.seg.SS, sp, value)
end

function Cpu80386:pop16()
	local sp = self:_stackDefault32() and self:getReg32(4) or self:getReg16(4)
	local value = self:readMem16(self.seg.SS, sp)
	sp = (sp + 2) % 0x100000000
	if self:_stackDefault32() then
		self:setReg32(4, sp)
	else
		self:setReg16(4, sp % 0x10000)
	end
	return value
end

function Cpu80386:fetch8()
	local value = self:readMem8(self.seg.CS, self:_currentIP())
	self:_setInstructionPointer(self:_currentIP() + 1)
	return value
end

function Cpu80386:fetch16()
	local lo = self:fetch8()
	local hi = self:fetch8()
	return lo + hi * 0x100
end

function Cpu80386:fetch32()
	local w0 = self:fetch16()
	local w1 = self:fetch16()
	return w0 + w1 * 0x10000
end

function Cpu80386:_operand32Enabled(operandOverride)
	local default32 = self:_codeDefault32()
	if operandOverride then
		return not default32
	end
	return default32
end

function Cpu80386:_address32Enabled(addressOverride)
	local default32 = self:_codeDefault32()
	if addressOverride then
		return not default32
	end
	return default32
end

function Cpu80386:_operandWidth(operandOverride)
	return self:_operand32Enabled(operandOverride) and 32 or 16
end

function Cpu80386:_fetchImmediate(width)
	if width == 8 then
		return self:fetch8()
	elseif width == 16 then
		return self:fetch16()
	end
	return self:fetch32()
end

function Cpu80386:_readRM32(decoded)
	if decoded.mod == 3 then
		return self:getReg32(decoded.rm)
	end
	local segment, offset = self:_effectiveAddress(decoded)
	return self:readMem32(segment, offset)
end

function Cpu80386:_writeRM32(decoded, value)
	if decoded.mod == 3 then
		self:setReg32(decoded.rm, value)
		return
	end
	local segment, offset = self:_effectiveAddress(decoded)
	self:writeMem32(segment, offset, value)
end

function Cpu80386:_readRMByWidth(decoded, width)
	if width == 8 then
		return self:_readRM8(decoded)
	elseif width == 16 then
		return self:_readRM16(decoded)
	end
	return self:_readRM32(decoded)
end

function Cpu80386:_writeRMByWidth(decoded, width, value)
	if width == 8 then
		self:_writeRM8(decoded, value)
	elseif width == 16 then
		self:_writeRM16(decoded, value)
	else
		self:_writeRM32(decoded, value)
	end
end

function Cpu80386:_getRegByWidth(code, width)
	if width == 8 then
		return self:getReg8(code)
	elseif width == 16 then
		return self:getReg16(code)
	end
	return self:getReg32(code)
end

function Cpu80386:_setRegByWidth(code, width, value)
	if width == 8 then
		self:setReg8(code, value)
	elseif width == 16 then
		self:setReg16(code, value)
	else
		self:setReg32(code, value)
	end
end

function Cpu80386:_decodeModRMForAddressSize(addressOverride)
	if not self:_address32Enabled(addressOverride) then
		local decoded = self:_decodeModRM()
		decoded.addressWidth = 16
		return decoded
	end

	local byte = self:fetch8()
	local mod = bit32.rshift(byte, 6)
	local reg = bit32.band(bit32.rshift(byte, 3), 0x07)
	local rm = bit32.band(byte, 0x07)
	local sib = nil
	local disp = 0

	if mod ~= 3 and rm == 4 then
		local sibByte = self:fetch8()
		sib = {
			scale = bit32.lshift(1, bit32.rshift(sibByte, 6)),
			index = bit32.band(bit32.rshift(sibByte, 3), 0x07),
			base = bit32.band(sibByte, 0x07),
		}
	end

	if mod == 0 then
		if rm == 5 or (sib and sib.base == 5) then
			disp = signExtend32(self:fetch32())
		end
	elseif mod == 1 then
		disp = signExtend8(self:fetch8())
	elseif mod == 2 then
		disp = signExtend32(self:fetch32())
	end

	return {
		mod = mod,
		reg = reg,
		rm = rm,
		disp = disp,
		sib = sib,
		addressWidth = 32,
	}
end

function Cpu80386:_effectiveAddress(decoded)
	if decoded.mod == 3 then
		return nil, nil
	end
	if decoded.addressWidth ~= 32 then
		return Cpu8086._effectiveAddress(self, decoded)
	end

	local base = 0
	local segment = self.seg.DS
	local usesStackSegment = false
	local sib = decoded.sib

	if sib then
		if not (decoded.mod == 0 and sib.base == 5) then
			base = self:getReg32(sib.base)
			usesStackSegment = sib.base == 4 or sib.base == 5
		end
		if sib.index ~= 4 then
			base = (base + ((self:getReg32(sib.index) * sib.scale) % 0x100000000)) % 0x100000000
		end
	else
		if not (decoded.mod == 0 and decoded.rm == 5) then
			base = self:getReg32(decoded.rm)
			usesStackSegment = decoded.rm == 4 or decoded.rm == 5
		end
	end

	if usesStackSegment then
		segment = self.seg.SS
	end

	local offset = (base + (tonumber(decoded.disp) or 0)) % 0x100000000
	return self:_applySegmentOverride(segment), offset
end

function Cpu80386:_portReadByWidth(port, width)
	if width == 8 then
		return self.bus:portRead(port)
	elseif width == 16 then
		return self.bus:portRead16(port)
	end
	if type(self.bus.portRead32) == "function" then
		return self.bus:portRead32(port)
	end
	local lo = self.bus:portRead16(port)
	local hi = self.bus:portRead16(port + 2)
	return lo + hi * 0x10000
end

function Cpu80386:_portWriteByWidth(port, width, value)
	if width == 8 then
		self.bus:portWrite(port, value)
	elseif width == 16 then
		self.bus:portWrite16(port, value)
	elseif type(self.bus.portWrite32) == "function" then
		self.bus:portWrite32(port, value)
	else
		local masked = (tonumber(value) or 0) % 0x100000000
		self.bus:portWrite16(port, masked % 0x10000)
		self.bus:portWrite16(port + 2, math.floor(masked / 0x10000) % 0x10000)
	end
end

function Cpu80386:push32(value)
	local sp = self:_stackDefault32() and self:getReg32(4) or self:getReg16(4)
	sp = (sp - 4) % 0x100000000
	if self:_stackDefault32() then
		self:setReg32(4, sp)
	else
		self:setReg16(4, sp % 0x10000)
	end
	self:writeMem32(self.seg.SS, sp, value)
end

function Cpu80386:pop32()
	local sp = self:_stackDefault32() and self:getReg32(4) or self:getReg16(4)
	local value = self:readMem32(self.seg.SS, sp)
	sp = (sp + 4) % 0x100000000
	if self:_stackDefault32() then
		self:setReg32(4, sp)
	else
		self:setReg16(4, sp % 0x10000)
	end
	return value
end

function Cpu80386:_currentPrivilegeLevel()
	if not self.protectedMode then
		return 0
	end
	return bit32.band(self.seg.CS or 0, 0x03)
end

function Cpu80386:_stackPointer()
	return self:_stackDefault32() and self:getReg32(4) or self:getReg16(4)
end

function Cpu80386:_setStackPointer(value, use32Bit)
	if use32Bit == nil then
		use32Bit = self:_stackDefault32()
	end
	if use32Bit then
		self:setReg32(4, value)
	else
		self:setReg16(4, value % 0x10000)
	end
end

function Cpu80386:_makeException(vector, errorCode, message)
	return {
		__x86Exception = true,
		vector = (tonumber(vector) or 0) % 0x100,
		errorCode = errorCode ~= nil and (tonumber(errorCode) or 0) or nil,
		message = tostring(message or ("x86 exception " .. tostring(vector))),
	}
end

function Cpu80386:_raiseException(vector, errorCode, message)
	error(self:_makeException(vector, errorCode, message), 0)
end

function Cpu80386:_segmentFaultVector(segment)
	if segment == "SS" or segment == self.seg.SS then
		return VECTOR_SS
	end
	return VECTOR_GP
end

function Cpu80386:_linearFromDescriptor(descriptor, selector, offset, faultVector)
	if not descriptor then
		self:_raiseException(faultVector or VECTOR_GP, selector or 0, "missing segment descriptor")
	end
	if descriptor.unusable then
		self:_raiseException(faultVector or VECTOR_GP, selector or 0, "segment is unusable")
	end
	if descriptor.present == false then
		self:_raiseException(VECTOR_NP, selector or 0, "segment not present")
	end
	local logical = (tonumber(offset) or 0) % 0x100000000
	if descriptor.expandDown then
		local upperBound = descriptor.default32 and 0xFFFFFFFF or 0xFFFF
		if logical <= (descriptor.limit or 0) or logical > upperBound then
			self:_raiseException(faultVector or VECTOR_GP, selector or 0, "segment limit exceeded")
		end
	elseif logical > (descriptor.limit or 0xFFFFFFFF) then
		self:_raiseException(faultVector or VECTOR_GP, selector or 0, "segment limit exceeded")
	end
	return ((descriptor.base or 0) + logical) % 0x100000000
end

function Cpu80386:_readDescriptorMemory(selector, descriptor, offset, width, faultVector)
	local linear = self:_linearFromDescriptor(descriptor, selector, offset, faultVector)
	if width == 8 then
		return self:readPhysical8(linear)
	elseif width == 16 then
		return self:readPhysical16(linear)
	end
	return self:readPhysical32(linear)
end

function Cpu80386:_writeDescriptorMemory(selector, descriptor, offset, width, value, faultVector)
	local linear = self:_linearFromDescriptor(descriptor, selector, offset, faultVector)
	if width == 8 then
		self:writePhysical8(linear, value)
	elseif width == 16 then
		self:writePhysical16(linear, value)
	else
		self:writePhysical32(linear, value)
	end
end

function Cpu80386:_pushToDescriptorStack(selector, descriptor, stackWidth32, valueWidth, value)
	local stackMask = stackWidth32 and 0xFFFFFFFF or 0xFFFF
	local sp = stackWidth32 and self:getReg32(4) or self:getReg16(4)
	local nextSp = (sp - (valueWidth / 8)) % 0x100000000
	if not stackWidth32 then
		nextSp = nextSp % 0x10000
	end
	self:_writeDescriptorMemory(selector, descriptor, nextSp, valueWidth, value, VECTOR_SS)
	return bit32.band(nextSp, stackMask)
end

function Cpu80386:_readTss32Field(offset, width)
	if not self.tr or not self.tr.present then
		self:_raiseException(VECTOR_TS, 0, "task register is not loaded")
	end
	if ((tonumber(offset) or 0) + (width / 8) - 1) > (self.tr.limit or 0) then
		self:_raiseException(VECTOR_TS, self.tr.selector or 0, "tss limit exceeded")
	end
	local address = (self.tr.base or 0) + offset
	if width == 16 then
		return self:readPhysical16(address)
	end
	return self:readPhysical32(address)
end

function Cpu80386:_commitDescriptorLoad(name, selector, descriptor)
	self:_writeSegmentRegister(name, selector)
	if descriptor then
		descriptor.selector = selector
	end
	self.segCache[name] = descriptor
end

function Cpu80386:_loadTaskRegister(selector)
	local descriptor, err = self:_decodeDescriptor(selector)
	if not descriptor then
		self:_raiseException(VECTOR_TS, selector or 0, err or "invalid task register selector")
	end
	if descriptor.kind ~= "tss32" then
		self:_raiseException(VECTOR_TS, selector or 0, "ltr requires a 32-bit tss descriptor")
	end
	if not descriptor.present then
		self:_raiseException(VECTOR_NP, selector or 0, "tss descriptor is not present")
	end
	self.tr = {
		selector = bit32.band(selector, 0xFFF8),
		base = descriptor.base,
		limit = descriptor.limit,
		present = true,
		busy = true,
	}
	if descriptor.address then
		self:writePhysical8(descriptor.address + 5, bit32.bor(bit32.band(descriptor.access or 0, 0xF0), 0x0B))
	end
end

function Cpu80386:_resolveCodeSegment(selector, descriptor, reason, requestedCPL)
	local currentCPL = self:_currentPrivilegeLevel()
	local rpl = bit32.band(selector or 0, 0x03)
	local newCPL = requestedCPL

	if not descriptor then
		self:_raiseException(VECTOR_GP, selector or 0, "missing code descriptor")
	end
	if descriptor.present == false then
		self:_raiseException(VECTOR_NP, selector or 0, "target code segment is not present")
	end
	if descriptor.system or not descriptor.executable then
		self:_raiseException(VECTOR_GP, selector or 0, "control transfer target is not executable")
	end

	if reason == "interrupt" then
		if descriptor.conforming then
			if descriptor.dpl > currentCPL then
				self:_raiseException(VECTOR_GP, selector or 0, "conforming interrupt target privilege violation")
			end
			newCPL = currentCPL
		else
			if descriptor.dpl > currentCPL then
				self:_raiseException(VECTOR_GP, selector or 0, "interrupt target privilege violation")
			end
			newCPL = descriptor.dpl
		end
	elseif reason == "iret" or reason == "retf" then
		local returnCPL = requestedCPL or rpl
		if descriptor.conforming then
			if descriptor.dpl > returnCPL then
				self:_raiseException(VECTOR_GP, selector or 0, "invalid conforming return target")
			end
			newCPL = returnCPL
		else
			if descriptor.dpl ~= returnCPL then
				self:_raiseException(VECTOR_GP, selector or 0, "invalid return privilege level")
			end
			newCPL = returnCPL
		end
	else
		if descriptor.conforming then
			if descriptor.dpl > currentCPL then
				self:_raiseException(VECTOR_GP, selector or 0, "conforming code privilege violation")
			end
			newCPL = currentCPL
		else
			if descriptor.dpl ~= currentCPL or rpl > currentCPL then
				self:_raiseException(VECTOR_GP, selector or 0, "non-conforming code privilege violation")
			end
			newCPL = descriptor.dpl
		end
	end

	local loadedSelector = bit32.bor(bit32.band(selector or 0, 0xFFFC), bit32.band(newCPL or 0, 0x03))
	return loadedSelector, newCPL
end

function Cpu80386:_loadDataSegmentDescriptor(selector, descriptor, name, desiredCPL)
	local targetName = name or "DS"
	local cpl = desiredCPL
	if cpl == nil then
		cpl = self:_currentPrivilegeLevel()
	end
	local rpl = bit32.band(selector or 0, 0x03)

	if not descriptor then
		self:_raiseException(self:_segmentFaultVector(targetName), selector or 0, "missing segment descriptor")
	end
	if descriptor.present == false then
		self:_raiseException(targetName == "SS" and VECTOR_SS or VECTOR_NP, selector or 0, "segment not present")
	end
	if descriptor.system then
		self:_raiseException(
			self:_segmentFaultVector(targetName),
			selector or 0,
			"system descriptor cannot be loaded here"
		)
	end

	if targetName == "SS" then
		if descriptor.executable or not descriptor.writable or descriptor.dpl ~= cpl or rpl ~= cpl then
			self:_raiseException(VECTOR_SS, selector or 0, "invalid stack segment")
		end
		return bit32.bor(bit32.band(selector or 0, 0xFFFC), bit32.band(cpl, 0x03))
	end

	if descriptor.executable and not descriptor.readable then
		self:_raiseException(VECTOR_GP, selector or 0, "execute-only segment cannot be used as data")
	end
	if not descriptor.executable and descriptor.dpl < math.max(cpl, rpl) then
		self:_raiseException(VECTOR_GP, selector or 0, "data segment privilege violation")
	end
	return bit32.bor(bit32.band(selector or 0, 0xFFFC), bit32.band(rpl, 0x03))
end

function Cpu80386:_computePF(value)
	local low8 = bit32.band(value, 0xFF)
	local bits = 0
	for _ = 1, 8 do
		if bit32.band(low8, 1) ~= 0 then
			bits = bits + 1
		end
		low8 = bit32.rshift(low8, 1)
	end
	return bits % 2 == 0
end

function Cpu80386:_updateLogicFlags(width, value)
	local mask = maskForWidth(width)
	local masked = value % (mask + 1)
	self:setFlag(FLAG_CF, false)
	self:setFlag(FLAG_OF, false)
	self:setFlag(FLAG_AF, false)
	self:setFlag(FLAG_ZF, masked == 0)
	self:setFlag(FLAG_SF, bit32.band(masked, signBit(width)) ~= 0)
	self:setFlag(FLAG_PF, self:_computePF(masked))
end

function Cpu80386:_add(width, a, b)
	local mask = maskForWidth(width)
	local result = (a + b) % (mask + 1)
	self:setFlag(FLAG_CF, a + b > mask)
	self:setFlag(FLAG_ZF, result == 0)
	self:setFlag(FLAG_SF, bit32.band(result, signBit(width)) ~= 0)
	self:setFlag(FLAG_AF, bit32.band(a, 0x0F) + bit32.band(b, 0x0F) > 0x0F)
	self:setFlag(FLAG_PF, self:_computePF(result))
	local overflow = bit32.band(bit32.bnot(bit32.bxor(a, b)), bit32.bxor(a, result), signBit(width)) ~= 0
	self:setFlag(FLAG_OF, overflow)
	return result
end

function Cpu80386:_sub(width, a, b)
	local mask = maskForWidth(width)
	local result = (a - b) % (mask + 1)
	self:setFlag(FLAG_CF, a < b)
	self:setFlag(FLAG_ZF, result == 0)
	self:setFlag(FLAG_SF, bit32.band(result, signBit(width)) ~= 0)
	self:setFlag(FLAG_AF, bit32.band(a, 0x0F) < bit32.band(b, 0x0F))
	self:setFlag(FLAG_PF, self:_computePF(result))
	local overflow = bit32.band(bit32.bxor(a, b), bit32.bxor(a, result), signBit(width)) ~= 0
	self:setFlag(FLAG_OF, overflow)
	return result
end

function Cpu80386:_adc(width, a, b)
	local mask = maskForWidth(width)
	local carryIn = self:getFlag(FLAG_CF) and 1 or 0
	local operand = (b + carryIn) % (mask + 1)
	local total = a + operand
	local result = total % (mask + 1)
	self:setFlag(FLAG_CF, total > mask)
	self:setFlag(FLAG_ZF, result == 0)
	self:setFlag(FLAG_SF, bit32.band(result, signBit(width)) ~= 0)
	self:setFlag(FLAG_AF, bit32.band(a, 0x0F) + bit32.band(operand, 0x0F) > 0x0F)
	self:setFlag(FLAG_PF, self:_computePF(result))
	local overflow = bit32.band(bit32.bnot(bit32.bxor(a, operand)), bit32.bxor(a, result), signBit(width)) ~= 0
	self:setFlag(FLAG_OF, overflow)
	return result
end

function Cpu80386:_sbb(width, a, b)
	local mask = maskForWidth(width)
	local borrow = self:getFlag(FLAG_CF) and 1 or 0
	local fullOperand = (tonumber(b) or 0) + borrow
	local operand = fullOperand % (mask + 1)
	local result = (a - operand) % (mask + 1)
	self:setFlag(FLAG_CF, a < fullOperand)
	self:setFlag(FLAG_ZF, result == 0)
	self:setFlag(FLAG_SF, bit32.band(result, signBit(width)) ~= 0)
	self:setFlag(FLAG_AF, bit32.band(a, 0x0F) < bit32.band(operand, 0x0F))
	self:setFlag(FLAG_PF, self:_computePF(result))
	local overflow = bit32.band(bit32.bxor(a, operand), bit32.bxor(a, result), signBit(width)) ~= 0
	self:setFlag(FLAG_OF, overflow)
	return result
end

function Cpu80386:_logicBinary(width, left, right, operation)
	local mask = maskForWidth(width)
	local result
	if operation == "or" then
		result = bit32.bor(left, right)
	elseif operation == "and" then
		result = bit32.band(left, right)
	else
		result = bit32.bxor(left, right)
	end
	result = result % (mask + 1)
	self:_updateLogicFlags(width, result)
	return result
end

function Cpu80386:_inc(width, value)
	local carry = self:getFlag(FLAG_CF)
	local result = self:_add(width, value, 1)
	self:setFlag(FLAG_CF, carry)
	self:setFlag(FLAG_AF, bit32.band(value, 0x0F) == 0x0F)
	return result
end

function Cpu80386:_dec(width, value)
	local carry = self:getFlag(FLAG_CF)
	local result = self:_sub(width, value, 1)
	self:setFlag(FLAG_CF, carry)
	self:setFlag(FLAG_AF, bit32.band(value, 0x0F) == 0x00)
	return result
end

function Cpu80386:_shiftRotate(width, operation, value, count)
	local mask = maskForWidth(width)
	local topBit = signBit(width)
	local base = mask + 1
	local rawCount = bit32.band(tonumber(count) or 0, 0x1F)
	local result = (tonumber(value) or 0) % base

	if rawCount == 0 then
		return result
	end

	local effectiveCount = rawCount
	if operation == "rol" or operation == "ror" then
		effectiveCount = rawCount % width
	elseif operation == "rcl" or operation == "rcr" then
		effectiveCount = rawCount % (width + 1)
	end

	if effectiveCount == 0 then
		return result
	end

	local original = result
	for _ = 1, effectiveCount do
		if operation == "rol" then
			local carryOut = bit32.band(result, topBit) ~= 0 and 1 or 0
			result = bit32.band(bit32.lshift(result, 1), mask)
			result = bit32.bor(result, carryOut)
			self:setFlag(FLAG_CF, carryOut ~= 0)
		elseif operation == "ror" then
			local carryOut = bit32.band(result, 0x01)
			result = bit32.rshift(result, 1)
			if carryOut ~= 0 then
				result = bit32.bor(result, topBit)
			end
			self:setFlag(FLAG_CF, carryOut ~= 0)
		elseif operation == "rcl" then
			local carryIn = self:getFlag(FLAG_CF) and 1 or 0
			local carryOut = bit32.band(result, topBit) ~= 0 and 1 or 0
			result = bit32.band(bit32.lshift(result, 1), mask)
			result = bit32.bor(result, carryIn)
			self:setFlag(FLAG_CF, carryOut ~= 0)
		elseif operation == "rcr" then
			local carryIn = self:getFlag(FLAG_CF) and topBit or 0
			local carryOut = bit32.band(result, 0x01)
			result = bit32.bor(bit32.rshift(result, 1), carryIn)
			self:setFlag(FLAG_CF, carryOut ~= 0)
		elseif operation == "shl" then
			local carryOut = bit32.band(result, topBit) ~= 0 and 1 or 0
			result = bit32.band(bit32.lshift(result, 1), mask)
			self:setFlag(FLAG_CF, carryOut ~= 0)
		elseif operation == "shr" then
			local carryOut = bit32.band(result, 0x01)
			result = bit32.rshift(result, 1)
			self:setFlag(FLAG_CF, carryOut ~= 0)
		elseif operation == "sar" then
			local carryOut = bit32.band(result, 0x01)
			local signSet = bit32.band(result, topBit) ~= 0
			result = bit32.rshift(result, 1)
			if signSet then
				result = bit32.bor(result, topBit)
			end
			self:setFlag(FLAG_CF, carryOut ~= 0)
		end
	end

	if operation == "rol" or operation == "rcl" then
		if effectiveCount == 1 then
			self:setFlag(FLAG_OF, (bit32.band(result, topBit) ~= 0) ~= self:getFlag(FLAG_CF))
		end
		return result % base
	end

	if operation == "ror" or operation == "rcr" then
		if effectiveCount == 1 then
			local msb = bit32.band(result, topBit) ~= 0
			local nextBit = bit32.band(result, bit32.rshift(topBit, 1)) ~= 0
			self:setFlag(FLAG_OF, msb ~= nextBit)
		end
		return result % base
	end

	self:setFlag(FLAG_ZF, result == 0)
	self:setFlag(FLAG_SF, bit32.band(result, topBit) ~= 0)
	self:setFlag(FLAG_AF, false)
	self:setFlag(FLAG_PF, self:_computePF(result))
	if effectiveCount == 1 then
		if operation == "shl" then
			self:setFlag(FLAG_OF, (bit32.band(result, topBit) ~= 0) ~= self:getFlag(FLAG_CF))
		elseif operation == "shr" then
			self:setFlag(FLAG_OF, bit32.band(original, topBit) ~= 0)
		else
			self:setFlag(FLAG_OF, false)
		end
	end
	return result % base
end

function Cpu80386:_mulDivGroup(width, operation, value)
	local mask = maskForWidth(width)
	local base = mask + 1
	local maskedValue = (tonumber(value) or 0) % base

	if operation == "not" then
		return bit32.band(bit32.bnot(maskedValue), mask)
	elseif operation == "neg" then
		local result = self:_sub(width, 0, maskedValue)
		self:setFlag(FLAG_CF, maskedValue ~= 0)
		return result
	elseif operation == "mul" then
		if width == 8 then
			local product = self:getReg8(0) * maskedValue
			self:setReg16(0, product % 0x10000)
			local overflow = product >= 0x100
			self:setFlag(FLAG_CF, overflow)
			self:setFlag(FLAG_OF, overflow)
		elseif width == 16 then
			local product = self:getReg16(0) * maskedValue
			self:setReg16(0, product % 0x10000)
			self:setReg16(2, math.floor(product / 0x10000) % 0x10000)
			local overflow = product >= 0x10000
			self:setFlag(FLAG_CF, overflow)
			self:setFlag(FLAG_OF, overflow)
		else
			local hi, lo = mulUnsigned32(self:getReg32(0), maskedValue)
			self:setReg32(0, lo)
			self:setReg32(2, hi)
			local overflow = hi ~= 0
			self:setFlag(FLAG_CF, overflow)
			self:setFlag(FLAG_OF, overflow)
		end
		return nil
	elseif operation == "imul" then
		if width == 8 then
			local product = toSigned(8, self:getReg8(0)) * toSigned(8, maskedValue)
			self:setReg16(0, product % 0x10000)
			local overflow = product < -0x80 or product > 0x7F
			self:setFlag(FLAG_CF, overflow)
			self:setFlag(FLAG_OF, overflow)
		elseif width == 16 then
			local product = toSigned(16, self:getReg16(0)) * toSigned(16, maskedValue)
			local stored = product % 0x100000000
			self:setReg16(0, stored % 0x10000)
			self:setReg16(2, math.floor(stored / 0x10000) % 0x10000)
			local overflow = product < -0x8000 or product > 0x7FFF
			self:setFlag(FLAG_CF, overflow)
			self:setFlag(FLAG_OF, overflow)
		else
			local left = toSigned(32, self:getReg32(0))
			local right = toSigned(32, maskedValue)
			local hi, lo = mulUnsigned32(math.abs(left), math.abs(right))
			if (left < 0) ~= (right < 0) then
				hi, lo = negate64(hi, lo)
			end
			self:setReg32(0, lo)
			self:setReg32(2, hi)
			local signExtended = (hi == 0 and bit32.band(lo, 0x80000000) == 0)
				or (hi == 0xFFFFFFFF and bit32.band(lo, 0x80000000) ~= 0)
			self:setFlag(FLAG_CF, not signExtended)
			self:setFlag(FLAG_OF, not signExtended)
		end
		return nil
	elseif operation == "div" then
		if maskedValue == 0 then
			self:_raiseException(VECTOR_DE, 0, "divide by zero")
		end
		if width == 8 then
			local dividend = self:getReg16(0)
			local quotient = math.floor(dividend / maskedValue)
			local remainder = dividend % maskedValue
			if quotient > 0xFF then
				self:_raiseException(VECTOR_DE, 0, "division overflow")
			end
			self:setReg8(0, quotient)
			self:setReg8(4, remainder)
		elseif width == 16 then
			local dividend = self:getReg16(0) + self:getReg16(2) * 0x10000
			local quotient = math.floor(dividend / maskedValue)
			local remainder = dividend % maskedValue
			if quotient > 0xFFFF then
				self:_raiseException(VECTOR_DE, 0, "division overflow")
			end
			self:setReg16(0, quotient)
			self:setReg16(2, remainder)
		else
			local quotient, remainder, overflow = divUnsigned64By32(self:getReg32(2), self:getReg32(0), maskedValue)
			if overflow then
				self:_raiseException(VECTOR_DE, 0, "division overflow")
			end
			self:setReg32(0, quotient)
			self:setReg32(2, remainder)
		end
		return nil
	elseif operation == "idiv" then
		local divisor = toSigned(width, maskedValue)
		if divisor == 0 then
			self:_raiseException(VECTOR_DE, 0, "divide by zero")
		end
		if width == 8 then
			local dividend = toSigned(16, self:getReg16(0))
			local quotient = dividend / divisor
			quotient = quotient >= 0 and math.floor(quotient) or math.ceil(quotient)
			local remainder = dividend - quotient * divisor
			if quotient < -0x80 or quotient > 0x7F then
				self:_raiseException(VECTOR_DE, 0, "division overflow")
			end
			self:setReg8(0, quotient % 0x100)
			self:setReg8(4, remainder % 0x100)
		elseif width == 16 then
			local dividend = self:getReg16(0) + self:getReg16(2) * 0x10000
			if bit32.band(self:getReg16(2), 0x8000) ~= 0 then
				dividend = dividend - 0x100000000
			end
			local quotient = dividend / divisor
			quotient = quotient >= 0 and math.floor(quotient) or math.ceil(quotient)
			local remainder = dividend - quotient * divisor
			if quotient < -0x8000 or quotient > 0x7FFF then
				self:_raiseException(VECTOR_DE, 0, "division overflow")
			end
			self:setReg16(0, quotient % 0x10000)
			self:setReg16(2, remainder % 0x10000)
		else
			local absHi, absLo, negativeDividend = absSigned64(self:getReg32(2), self:getReg32(0))
			local absDivisor = math.abs(divisor)
			local quotientAbs, remainderAbs, overflow = divUnsigned64By32(absHi, absLo, absDivisor)
			if overflow then
				self:_raiseException(VECTOR_DE, 0, "division overflow")
			end
			local negativeQuotient = negativeDividend ~= (divisor < 0)
			if
				(negativeQuotient and quotientAbs > 0x80000000) or ((not negativeQuotient) and quotientAbs > 0x7FFFFFFF)
			then
				self:_raiseException(VECTOR_DE, 0, "division overflow")
			end
			local quotient = negativeQuotient and (-quotientAbs % 0x100000000) or quotientAbs
			local remainder = negativeDividend and (-remainderAbs % 0x100000000) or remainderAbs
			self:setReg32(0, quotient)
			self:setReg32(2, remainder)
		end
		return nil
	end
	self:_raiseException(VECTOR_UD, 0, "unsupported F6/F7 group op")
end

function Cpu80386:_stringAddressRegister(code, use32)
	if use32 then
		return self:getReg32(code)
	end
	return self:getReg16(code)
end

function Cpu80386:_setStringAddressRegister(code, value, use32)
	if use32 then
		self:setReg32(code, value)
	else
		self:setReg16(code, value)
	end
end

function Cpu80386:_stringCount(use32)
	if use32 then
		return self:getReg32(1)
	end
	return self:getReg16(1)
end

function Cpu80386:_setStringCount(value, use32)
	if use32 then
		self:setReg32(1, value)
	else
		self:setReg16(1, value)
	end
end

function Cpu80386:_stringDelta(width)
	local bytes = width == 8 and 1 or (width == 16 and 2 or 4)
	return self:getFlag(FLAG_DF) and -bytes or bytes
end

function Cpu80386:_readMemByWidth(segment, offset, width)
	if width == 8 then
		return self:readMem8(segment, offset)
	elseif width == 16 then
		return self:readMem16(segment, offset)
	end
	return self:readMem32(segment, offset)
end

function Cpu80386:_writeMemByWidth(segment, offset, width, value)
	if width == 8 then
		self:writeMem8(segment, offset, value)
	elseif width == 16 then
		self:writeMem16(segment, offset, value)
	else
		self:writeMem32(segment, offset, value)
	end
end

function Cpu80386:_executeStringOp(opcode, repeatPrefix, operandWidth, addressOverride)
	local width
	if
		opcode == 0xA4
		or opcode == 0xA6
		or opcode == 0xAA
		or opcode == 0xAC
		or opcode == 0xAE
		or opcode == 0x6C
		or opcode == 0x6E
	then
		width = 8
	else
		width = operandWidth
	end
	local use32Addresses = self:_address32Enabled(addressOverride)
	local repeated = repeatPrefix ~= nil
	local remaining = repeated and self:_stringCount(use32Addresses) or 1
	local sourceSegment = self._segmentOverride ~= nil and self:getSeg(self._segmentOverride) or self.seg.DS
	if repeated and remaining == 0 then
		return true
	end

	while remaining > 0 do
		local delta = self:_stringDelta(width)
		local si = self:_stringAddressRegister(6, use32Addresses)
		local di = self:_stringAddressRegister(7, use32Addresses)
		if opcode == 0xA4 or opcode == 0xA5 then
			local value = self:_readMemByWidth(sourceSegment, si, width)
			self:_writeMemByWidth(self.seg.ES, di, width, value)
			self:_setStringAddressRegister(6, si + delta, use32Addresses)
			self:_setStringAddressRegister(7, di + delta, use32Addresses)
		elseif opcode == 0xA6 or opcode == 0xA7 then
			local left = self:_readMemByWidth(sourceSegment, si, width)
			local right = self:_readMemByWidth(self.seg.ES, di, width)
			self:_sub(width, left, right)
			self:_setStringAddressRegister(6, si + delta, use32Addresses)
			self:_setStringAddressRegister(7, di + delta, use32Addresses)
		elseif opcode == 0xAA or opcode == 0xAB then
			local value = self:_getRegByWidth(0, width)
			self:_writeMemByWidth(self.seg.ES, di, width, value)
			self:_setStringAddressRegister(7, di + delta, use32Addresses)
		elseif opcode == 0xAC or opcode == 0xAD then
			local value = self:_readMemByWidth(sourceSegment, si, width)
			self:_setRegByWidth(0, width, value)
			self:_setStringAddressRegister(6, si + delta, use32Addresses)
		elseif opcode == 0xAE or opcode == 0xAF then
			local left = self:_getRegByWidth(0, width)
			local right = self:_readMemByWidth(self.seg.ES, di, width)
			self:_sub(width, left, right)
			self:_setStringAddressRegister(7, di + delta, use32Addresses)
		elseif opcode == 0x6C or opcode == 0x6D then
			self.stats.portReads = self.stats.portReads + 1
			local value = self:_portReadByWidth(self:_getRegByWidth(2, width), width)
			self:_writeMemByWidth(self.seg.ES, di, width, value)
			self:_setStringAddressRegister(7, di + delta, use32Addresses)
		elseif opcode == 0x6E or opcode == 0x6F then
			local value = self:_readMemByWidth(sourceSegment, si, width)
			self.stats.portWrites = self.stats.portWrites + 1
			self:_portWriteByWidth(self:_getRegByWidth(2, width), width, value)
			self:_setStringAddressRegister(6, si + delta, use32Addresses)
		end

		remaining = remaining - 1
		if repeated then
			self:_setStringCount(remaining, use32Addresses)
			if opcode == 0xA6 or opcode == 0xA7 or opcode == 0xAE or opcode == 0xAF then
				if repeatPrefix == 0xF3 and not self:getFlag(FLAG_ZF) then
					break
				elseif repeatPrefix == 0xF2 and self:getFlag(FLAG_ZF) then
					break
				end
			end
		else
			break
		end
	end
	return true
end

function Cpu80386:_decodeDescriptor(selector)
	local value = (tonumber(selector) or 0) % 0x10000
	if value == 0 then
		return nil, "null selector"
	end
	if bit32.band(value, 0x04) ~= 0 then
		return nil, "ldt selectors are not supported"
	end

	local index = bit32.rshift(value, 3)
	local offset = index * 8
	if (offset + 7) > (self.gdtr.limit or 0) then
		return nil, "selector outside gdt limit"
	end

	local baseAddress = (self.gdtr.base or 0) + offset
	local b0 = self:readPhysical8(baseAddress + 0)
	local b1 = self:readPhysical8(baseAddress + 1)
	local b2 = self:readPhysical8(baseAddress + 2)
	local b3 = self:readPhysical8(baseAddress + 3)
	local b4 = self:readPhysical8(baseAddress + 4)
	local b5 = self:readPhysical8(baseAddress + 5)
	local b6 = self:readPhysical8(baseAddress + 6)
	local b7 = self:readPhysical8(baseAddress + 7)

	local limit = b0 + b1 * 0x100 + bit32.lshift(bit32.band(b6, 0x0F), 16)
	if bit32.band(b6, 0x80) ~= 0 then
		limit = limit * 0x1000 + 0x0FFF
	end

	local base = b2 + b3 * 0x100 + b4 * 0x10000 + b7 * 0x1000000
	local access = b5
	local present = bit32.band(access, 0x80) ~= 0
	local dpl = bit32.band(bit32.rshift(access, 5), 0x03)
	local system = bit32.band(access, 0x10) == 0
	local descriptorType = bit32.band(access, 0x0F)
	local descriptor = {
		selector = value,
		address = baseAddress,
		base = base,
		limit = limit,
		access = access,
		flags = b6,
		dpl = dpl,
		system = system,
		type = descriptorType,
		default32 = bit32.band(b6, 0x40) ~= 0,
		present = present,
		rpl = bit32.band(value, 0x03),
	}

	if not system then
		descriptor.executable = bit32.band(descriptorType, 0x08) ~= 0
		descriptor.conforming = descriptor.executable and bit32.band(descriptorType, 0x04) ~= 0
		descriptor.readable = descriptor.executable and bit32.band(descriptorType, 0x02) ~= 0
		descriptor.expandDown = (not descriptor.executable) and bit32.band(descriptorType, 0x04) ~= 0
		descriptor.writable = (not descriptor.executable) and bit32.band(descriptorType, 0x02) ~= 0
		descriptor.kind = descriptor.executable and "code" or "data"
		return descriptor
	end

	if descriptorType == 0x09 or descriptorType == 0x0B then
		descriptor.kind = "tss32"
		descriptor.busy = descriptorType == 0x0B
	elseif descriptorType == 0x04 or descriptorType == 0x0C then
		descriptor.kind = "call_gate"
		descriptor.gate32 = descriptorType == 0x0C
		descriptor.selector = b2 + b3 * 0x100
		descriptor.offset = b0 + b1 * 0x100 + b6 * 0x10000 + b7 * 0x1000000
		descriptor.parameterCount = bit32.band(b4, 0x1F)
	elseif descriptorType == 0x05 then
		descriptor.kind = "task_gate"
		descriptor.selector = b2 + b3 * 0x100
	elseif descriptorType == 0x06 or descriptorType == 0x07 then
		descriptor.kind = descriptorType == 0x06 and "interrupt_gate" or "trap_gate"
		descriptor.gate32 = false
		descriptor.selector = b2 + b3 * 0x100
		descriptor.offset = b0 + b1 * 0x100
	elseif descriptorType == 0x0E or descriptorType == 0x0F then
		descriptor.kind = descriptorType == 0x0E and "interrupt_gate" or "trap_gate"
		descriptor.gate32 = true
		descriptor.selector = b2 + b3 * 0x100
		descriptor.offset = b0 + b1 * 0x100 + b6 * 0x10000 + b7 * 0x1000000
	else
		descriptor.kind = "system"
	end

	return descriptor
end

function Cpu80386:_segmentCacheFor(segment)
	if type(segment) == "string" then
		return self.segCache[segment]
	end

	local value = (tonumber(segment) or 0) % 0x10000
	for _, name in ipairs(SEGMENT_NAMES) do
		if value == (self.seg[name] or 0) then
			return self.segCache[name]
		end
	end

	local descriptor = self:_decodeDescriptor(value)
	if descriptor then
		return descriptor
	end
	return nil
end

function Cpu80386:linearAddress(segment, offset)
	if not self.protectedMode then
		return (((tonumber(segment) or 0) % 0x10000) * 16 + ((tonumber(offset) or 0) % 0x10000)) % 0x100000000
	end

	local descriptor = self:_segmentCacheFor(segment)
	local selector = type(segment) == "string" and self.seg[segment] or segment
	return self:_linearFromDescriptor(descriptor, selector, offset, self:_segmentFaultVector(segment))
end

function Cpu80386:setSeg(code, value)
	local name = self:_segmentName(code)
	if not name then
		return
	end
	local selector = (tonumber(value) or 0) % 0x10000

	if self.protectedMode then
		if selector == 0 then
			if name == "CS" or name == "SS" then
				self:_raiseException(self:_segmentFaultVector(name), 0, "null selector is not allowed for " .. name)
			end
			self:_commitDescriptorLoad(name, 0, self:_makeNullSegmentDescriptor(name))
			return
		end
		local descriptor, err = self:_decodeDescriptor(selector)
		if not descriptor then
			self:_raiseException(self:_segmentFaultVector(name), selector, err or "invalid protected-mode selector")
		end
		local loadedSelector = self:_loadDataSegmentDescriptor(selector, descriptor, name)
		self:_commitDescriptorLoad(name, loadedSelector, descriptor)
	else
		self:_writeSegmentRegister(name, selector)
		self:_syncRealModeSegment(name)
	end
end

function Cpu80386:_loadTableRegister(decoded, target)
	if decoded.mod == 3 then
		self:_raiseException(VECTOR_UD, 0, target:upper() .. " requires a memory operand")
	end
	local segment, offset = self:_effectiveAddress(decoded)
	local limit = self:readMem16(segment, offset)
	local baseLo = self:readMem16(segment, offset + 2)
	local baseHi = self:readMem16(segment, offset + 4)
	self[target] = {
		base = baseLo + baseHi * 0x10000,
		limit = limit,
	}
end

function Cpu80386:_decodeInterruptGate(vector)
	local entryOffset = ((tonumber(vector) or 0) % 0x100) * 8
	if (entryOffset + 7) > (self.idtr.limit or 0) then
		return nil, "interrupt vector outside idt limit", VECTOR_GP
	end

	local base = (self.idtr.base or 0) + entryOffset
	local offsetLo = self:readPhysical16(base + 0)
	local selector = self:readPhysical16(base + 2)
	local typeAttr = self:readPhysical8(base + 5)
	local offsetHi = self:readPhysical16(base + 6)
	local present = bit32.band(typeAttr, 0x80) ~= 0
	local gateType = bit32.band(typeAttr, 0x1F)
	local dpl = bit32.band(bit32.rshift(typeAttr, 5), 0x03)

	return {
		vector = (tonumber(vector) or 0) % 0x100,
		selector = selector,
		offset = offsetLo + offsetHi * 0x10000,
		dpl = dpl,
		present = present,
		type = gateType,
		kind = (gateType == 0x06 or gateType == 0x0E) and "interrupt_gate"
			or ((gateType == 0x07 or gateType == 0x0F) and "trap_gate")
			or (gateType == 0x05 and "task_gate")
			or "unsupported",
		trapGate = gateType == 0x07 or gateType == 0x0F,
		gate32 = gateType == 0x0E or gateType == 0x0F,
	}
end

function Cpu80386:_readFarPointer(decoded, operandWidth)
	if decoded.mod == 3 then
		self:_raiseException(VECTOR_UD, 0, "far pointer operand must be in memory")
	end
	local segment, offset = self:_effectiveAddress(decoded)
	local pointerOffset
	local selectorOffset
	if operandWidth == 32 then
		pointerOffset = self:readMem32(segment, offset)
		selectorOffset = offset + 4
	else
		pointerOffset = self:readMem16(segment, offset)
		selectorOffset = offset + 2
	end
	return pointerOffset, self:readMem16(segment, selectorOffset)
end

function Cpu80386:_loadFarPointerRegister(decoded, segmentCode, operandWidth)
	local farOffset, farSelector = self:_readFarPointer(decoded, operandWidth)
	self:setSeg(segmentCode, farSelector)
	self:_setRegByWidth(decoded.reg, operandWidth, farOffset)
end

function Cpu80386:_applyCodeTransfer(selector, descriptor, offset, reason, requestedCPL)
	local loadedSelector, newCPL = self:_resolveCodeSegment(selector, descriptor, reason, requestedCPL)
	self:_commitDescriptorLoad("CS", loadedSelector, descriptor)
	self:_setInstructionPointer(offset)
	return newCPL
end

function Cpu80386:_executeFarJump(selector, offset)
	if not self.protectedMode then
		Cpu8086.setSeg(self, 1, selector)
		self:_syncRealModeSegment("CS")
		self:_setInstructionPointer(offset)
		return
	end
	local descriptor, err = self:_decodeDescriptor(selector)
	if not descriptor then
		self:_raiseException(VECTOR_GP, selector or 0, err or "invalid far jump target")
	end
	if descriptor.kind == "task_gate" or descriptor.kind == "tss32" then
		self:_raiseException(VECTOR_TS, selector or 0, "hardware task switching is not implemented")
	end
	if descriptor.kind == "call_gate" then
		self:_raiseException(VECTOR_GP, selector or 0, "far jumps through call gates are not supported")
	end
	self:_applyCodeTransfer(selector, descriptor, offset, "jump")
end

function Cpu80386:_executeFarCall(selector, offset, operandWidth)
	if not self.protectedMode then
		local returnIP = self:_currentIP()
		if operandWidth == 32 then
			self:push32(self.seg.CS)
			self:push32(returnIP)
		else
			self:push16(self.seg.CS)
			self:push16(returnIP % 0x10000)
		end
		Cpu8086.setSeg(self, 1, selector)
		self:_syncRealModeSegment("CS")
		self:_setInstructionPointer(offset)
		return
	end
	local descriptor, err = self:_decodeDescriptor(selector)
	if not descriptor then
		self:_raiseException(VECTOR_GP, selector or 0, err or "invalid far call target")
	end
	if descriptor.kind == "task_gate" or descriptor.kind == "tss32" then
		self:_raiseException(VECTOR_TS, selector or 0, "hardware task switching is not implemented")
	end
	if descriptor.kind == "call_gate" then
		if not descriptor.present then
			self:_raiseException(VECTOR_NP, selector or 0, "call gate not present")
		end
		if descriptor.parameterCount ~= 0 then
			self:_raiseException(VECTOR_TS, selector or 0, "call gates with parameter copying are not implemented")
		end
		local targetDescriptor, targetErr = self:_decodeDescriptor(descriptor.selector)
		if not targetDescriptor then
			self:_raiseException(VECTOR_GP, descriptor.selector or 0, targetErr or "invalid call gate target")
		end
		offset = descriptor.offset
		selector = descriptor.selector
		descriptor = targetDescriptor
	end

	local returnIP = self:_currentIP()
	if operandWidth == 32 then
		self:push32(self.seg.CS)
		self:push32(returnIP)
	else
		self:push16(self.seg.CS)
		self:push16(returnIP % 0x10000)
	end
	self:_applyCodeTransfer(selector, descriptor, offset, "call")
end

function Cpu80386:_returnFar(operandWidth, stackAdjust, isInterruptReturn)
	if not self.protectedMode then
		local nextIP = operandWidth == 32 and self:pop32() or self:pop16()
		local nextCS = (operandWidth == 32 and self:pop32() or self:pop16()) % 0x10000
		if isInterruptReturn then
			local poppedFlags = operandWidth == 32 and self:pop32() or self:pop16()
			local mask = operandWidth == 32 and EFLAGS_WRITE_MASK or FLAGS16_WRITE_MASK
			self.flags = bit32.bor(bit32.band(poppedFlags, mask), 0x0002)
		end
		Cpu8086.setSeg(self, 1, nextCS)
		self:_syncRealModeSegment("CS")
		self:_setInstructionPointer(nextIP)
		if stackAdjust and stackAdjust ~= 0 then
			self:_setStackPointer(self:_stackPointer() + stackAdjust, self:_stackDefault32())
		end
		return
	end
	local oldCPL = self:_currentPrivilegeLevel()
	local nextIP = operandWidth == 32 and self:pop32() or self:pop16()
	local nextCS = (operandWidth == 32 and self:pop32() or self:pop16()) % 0x10000
	local nextFlags = nil
	if isInterruptReturn then
		nextFlags = operandWidth == 32 and self:pop32() or self:pop16()
	end

	local returnCPL = bit32.band(nextCS, 0x03)
	local descriptor, err = self:_decodeDescriptor(nextCS)
	if not descriptor then
		self:_raiseException(VECTOR_GP, nextCS, err or "invalid far return target")
	end

	local samePrivilege = returnCPL == oldCPL
	local restoredESP
	local restoredSS
	local ssDescriptor
	if not samePrivilege then
		restoredESP = operandWidth == 32 and self:pop32() or self:pop16()
		restoredSS = (operandWidth == 32 and self:pop32() or self:pop16()) % 0x10000
		ssDescriptor = self:_decodeDescriptor(restoredSS)
		if not ssDescriptor then
			self:_raiseException(VECTOR_SS, restoredSS, "invalid return stack segment")
		end
		restoredSS = self:_loadDataSegmentDescriptor(restoredSS, ssDescriptor, "SS", returnCPL)
	end

	self:_applyCodeTransfer(nextCS, descriptor, nextIP, isInterruptReturn and "iret" or "retf", returnCPL)
	if isInterruptReturn then
		local mask = operandWidth == 32 and EFLAGS_WRITE_MASK or FLAGS16_WRITE_MASK
		self.flags = bit32.bor(bit32.band(nextFlags or 0, mask), 0x0002)
	end
	if not samePrivilege then
		self:_commitDescriptorLoad("SS", restoredSS, ssDescriptor)
		self:_setStackPointer(restoredESP, ssDescriptor.default32)
	end
	if stackAdjust and stackAdjust ~= 0 then
		self:_setStackPointer(self:_stackPointer() + stackAdjust, self:_stackDefault32())
	end
end

function Cpu80386:_invokeInterrupt(vector, hardware, errorCode, isFault)
	self.halted = false
	if self.protectedMode then
		local gate, err, faultVector = self:_decodeInterruptGate(vector)
		if not gate then
			self:_raiseException(faultVector or VECTOR_GP, vector or 0, err or "invalid interrupt gate")
		end
		if gate.kind == "task_gate" then
			self:_raiseException(VECTOR_TS, gate.selector or 0, "task gates are not implemented")
		end
		if gate.kind == "unsupported" then
			self:_raiseException(VECTOR_GP, vector or 0, string.format("unsupported gate type 0x%02X", gate.type or 0))
		end
		if not gate.present then
			self:_raiseException(VECTOR_NP, gate.selector or 0, "interrupt gate not present")
		end
		local cpl = self:_currentPrivilegeLevel()
		if not hardware and not isFault and gate.dpl < cpl then
			self:_raiseException(VECTOR_GP, vector or 0, "software interrupt privilege violation")
		end

		local targetDescriptor, targetErr = self:_decodeDescriptor(gate.selector)
		if not targetDescriptor then
			self:_raiseException(VECTOR_GP, gate.selector or 0, targetErr or "invalid interrupt target")
		end
		local loadedSelector, newCPL = self:_resolveCodeSegment(gate.selector, targetDescriptor, "interrupt")
		local stackWidth32 = gate.gate32 or (self.segCache.SS and self.segCache.SS.default32) or false
		local oldSS = self.seg.SS
		local oldSP = self:_stackPointer()
		local oldCS = self.seg.CS
		local oldIP = self:_currentIP()
		local stackSelector = self.seg.SS
		local stackDescriptor = self.segCache.SS

		if newCPL < cpl then
			local tssEsp = self:_readTss32Field(4, 32)
			local tssSS = self:_readTss32Field(8, 16)
			local newSSDescriptor, stackErr = self:_decodeDescriptor(tssSS)
			if not newSSDescriptor then
				self:_raiseException(VECTOR_TS, tssSS, stackErr or "invalid ring transition stack segment")
			end
			local loadedSS = self:_loadDataSegmentDescriptor(tssSS, newSSDescriptor, "SS", newCPL)
			self:_commitDescriptorLoad("SS", loadedSS, newSSDescriptor)
			self:_setStackPointer(tssEsp, newSSDescriptor.default32)
			stackWidth32 = gate.gate32 or newSSDescriptor.default32
			stackSelector = loadedSS
			stackDescriptor = newSSDescriptor
			local switchedSP = self:_pushToDescriptorStack(
				stackSelector,
				stackDescriptor,
				stackWidth32,
				gate.gate32 and 32 or 16,
				oldSS
			)
			self:_setStackPointer(switchedSP, stackWidth32)
			switchedSP = self:_pushToDescriptorStack(
				stackSelector,
				stackDescriptor,
				stackWidth32,
				gate.gate32 and 32 or 16,
				oldSP
			)
			self:_setStackPointer(switchedSP, stackWidth32)
		end

		if gate.gate32 then
			self:push32(self.flags)
			self:push32(oldCS)
			self:push32(oldIP)
			if errorCode ~= nil then
				self:push32(errorCode)
			end
		else
			self:push16(self.flags)
			self:push16(oldCS)
			self:push16(oldIP % 0x10000)
			if errorCode ~= nil then
				self:push16(errorCode % 0x10000)
			end
		end
		if not gate.trapGate then
			self:setFlag(FLAG_IF, false)
		end
		self:setFlag(FLAG_TF, false)
		self:_commitDescriptorLoad("CS", loadedSelector, targetDescriptor)
		self:_setInstructionPointer(gate.offset)
		self.stats.interrupts = self.stats.interrupts + 1
		return true
	end
	return Cpu8086._invokeInterrupt(self, vector, hardware)
end

function Cpu80386:_stepInternal()
	self.stats.cycles = self.stats.cycles + 1

	if self:_serviceExternalInterrupt() then
		self.stats.instructions = self.stats.instructions + 1
		return "INT"
	end

	if self.halted then
		return "HLT"
	end

	local startIP = self:_currentIP()
	local startCS = self.seg.CS
	local operandOverride = false
	local addressOverride = false
	local repeatPrefix = nil
	self._segmentOverride = nil
	local opcode = self:fetch8()
	while opcode == 0x66 or opcode == 0x67 or opcode == 0xF2 or opcode == 0xF3 or SEGMENT_PREFIX_TO_CODE[opcode] ~= nil do
		if opcode == 0x66 then
			operandOverride = not operandOverride
		elseif opcode == 0xF2 or opcode == 0xF3 then
			repeatPrefix = opcode
		elseif opcode == 0x67 then
			addressOverride = not addressOverride
		else
			self._segmentOverride = SEGMENT_PREFIX_TO_CODE[opcode]
		end
		opcode = self:fetch8()
	end
	local operandWidth = self:_operandWidth(operandOverride)
	self._lastStep.opcode = opcode
	self._lastStep.cs = startCS
	self._lastStep.ip = startIP % 0x10000
	self._lastStep.eip = startIP

	if opcode == 0x0F then
		local extended = self:fetch8()
		self._lastStep.opcode = bit32.bor(0x0F00, extended)
		if extended == 0x00 then
			local decoded = self:_decodeModRMForAddressSize(addressOverride)
			if decoded.reg == 3 then
				self:_loadTaskRegister(self:_readRM16(decoded))
			else
				self:_raiseException(VECTOR_UD, 0, string.format("unsupported 0F 00 group /%d", decoded.reg))
			end
		elseif extended == 0x01 then
			local decoded = self:_decodeModRMForAddressSize(addressOverride)
			if decoded.reg == 2 then
				self:_loadTableRegister(decoded, "gdtr")
			elseif decoded.reg == 3 then
				self:_loadTableRegister(decoded, "idtr")
			elseif decoded.reg == 4 then
				self:_writeRM16(decoded, bit32.band(self.cr0, 0xFFFF))
			elseif decoded.reg == 6 then
				local value = self:_readRM16(decoded)
				self.cr0 = bit32.bor(bit32.band(self.cr0, bit32.bnot(0x3F)), bit32.band(value, 0x3F))
				if bit32.band(self.cr0, 0x0001) ~= 0 then
					self.protectedMode = true
				else
					self.protectedMode = false
					self:_syncRealModeCaches()
				end
			else
				self:_raiseException(VECTOR_UD, 0, string.format("unsupported 0F 01 group /%d", decoded.reg))
			end
		elseif extended == 0xB2 or extended == 0xB4 or extended == 0xB5 then
			local decoded = self:_decodeModRMForAddressSize(addressOverride)
			local segmentCode = extended == 0xB2 and 2 or (extended == 0xB4 and 4 or 5)
			self:_loadFarPointerRegister(decoded, segmentCode, operandWidth)
		else
			self:_raiseException(VECTOR_UD, 0, string.format("unsupported 0F opcode 0x%02X", extended))
		end
		self.stats.instructions = self.stats.instructions + 1
		return self._lastStep.opcode
	end

	if opcode >= 0xB8 and opcode <= 0xBF then
		self:_setRegByWidth(opcode - 0xB8, operandWidth, self:_fetchImmediate(operandWidth))
	elseif opcode >= 0xB0 and opcode <= 0xB7 then
		self:setReg8(opcode - 0xB0, self:fetch8())
	elseif opcode == 0x90 then
		self:_setInstructionPointer(self:_currentIP())
	elseif opcode >= 0x91 and opcode <= 0x97 then
		local reg = opcode - 0x90
		if operandWidth == 32 then
			local eax = self:getReg32(0)
			local other = self:getReg32(reg)
			self:setReg32(0, other)
			self:setReg32(reg, eax)
		else
			local ax = self:getReg16(0)
			local other = self:getReg16(reg)
			self:setReg16(0, other)
			self:setReg16(reg, ax)
		end
	elseif opcode == 0x9E then
		local ah = self:getReg8(4)
		local newFlags = bit32.bor(bit32.band(self.flags, 0xFFFFFF00), ah)
		if bit32.band(ah, 0x80) ~= 0 then
			newFlags = bit32.bor(newFlags, FLAG_SF)
		else
			newFlags = bit32.band(newFlags, bit32.bnot(FLAG_SF))
		end
		if bit32.band(ah, 0x40) ~= 0 then
			newFlags = bit32.bor(newFlags, FLAG_ZF)
		else
			newFlags = bit32.band(newFlags, bit32.bnot(FLAG_ZF))
		end
		if bit32.band(ah, 0x10) ~= 0 then
			newFlags = bit32.bor(newFlags, FLAG_AF)
		else
			newFlags = bit32.band(newFlags, bit32.bnot(FLAG_AF))
		end
		if bit32.band(ah, 0x04) ~= 0 then
			newFlags = bit32.bor(newFlags, FLAG_PF)
		else
			newFlags = bit32.band(newFlags, bit32.bnot(FLAG_PF))
		end
		if bit32.band(ah, 0x01) ~= 0 then
			newFlags = bit32.bor(newFlags, FLAG_CF)
		else
			newFlags = bit32.band(newFlags, bit32.bnot(FLAG_CF))
		end
		self.flags = bit32.bor(newFlags, 0x0002)
	elseif opcode == 0x9F then
		local newFlags = 0x02
		if bit32.band(self.flags, FLAG_SF) ~= 0 then
			newFlags = bit32.bor(newFlags, 0x80)
		end
		if bit32.band(self.flags, FLAG_ZF) ~= 0 then
			newFlags = bit32.bor(newFlags, 0x40)
		end
		if bit32.band(self.flags, FLAG_AF) ~= 0 then
			newFlags = bit32.bor(newFlags, 0x10)
		end
		if bit32.band(self.flags, FLAG_PF) ~= 0 then
			newFlags = bit32.bor(newFlags, 0x04)
		end
		if bit32.band(self.flags, FLAG_CF) ~= 0 then
			newFlags = bit32.bor(newFlags, 0x01)
		end
		self:_setReg8(7, newFlags)
	elseif opcode == 0xCC then
		self:_invokeInterrupt(3, false)
	elseif opcode == 0xCE then
		if self:getFlag(FLAG_OF) then
			self:_invokeInterrupt(4, false)
		end
	elseif opcode == 0x60 then
		if operandWidth == 32 then
			local originalSP = self:getReg32(4)
			self:push32(self:getReg32(0))
			self:push32(self:getReg32(1))
			self:push32(self:getReg32(2))
			self:push32(self:getReg32(3))
			self:push32(originalSP)
			self:push32(self:getReg32(5))
			self:push32(self:getReg32(6))
			self:push32(self:getReg32(7))
		else
			local originalSP = self:getReg16(4)
			self:push16(self:getReg16(0))
			self:push16(self:getReg16(1))
			self:push16(self:getReg16(2))
			self:push16(self:getReg16(3))
			self:push16(originalSP)
			self:push16(self:getReg16(5))
			self:push16(self:getReg16(6))
			self:push16(self:getReg16(7))
		end
	elseif opcode == 0x61 then
		if operandWidth == 32 then
			self:setReg32(7, self:pop32())
			self:setReg32(6, self:pop32())
			self:setReg32(5, self:pop32())
			self:pop32()
			self:setReg32(3, self:pop32())
			self:setReg32(2, self:pop32())
			self:setReg32(1, self:pop32())
			self:setReg32(0, self:pop32())
		else
			self:setReg16(7, self:pop16())
			self:setReg16(6, self:pop16())
			self:setReg16(5, self:pop16())
			self:pop16()
			self:setReg16(3, self:pop16())
			self:setReg16(2, self:pop16())
			self:setReg16(1, self:pop16())
			self:setReg16(0, self:pop16())
		end
	elseif opcode == 0x9C then
		if operandWidth == 32 then
			self:push32(self.flags)
		else
			self:push16(self.flags)
		end
	elseif opcode == 0x9D then
		if operandWidth == 32 then
			self.flags = bit32.bor(bit32.band(self:pop32(), 0x3F7FD5), 0x0002)
		else
			self.flags = bit32.bor(bit32.band(self:pop16(), 0x0FD5), 0x0002)
		end
	elseif opcode == 0x06 then
		if operandWidth == 32 then
			self:push32(self.seg.ES)
		else
			self:push16(self.seg.ES)
		end
	elseif opcode == 0x07 then
		local value = operandWidth == 32 and self:pop32() or self:pop16()
		self:setSeg(0, value % 0x10000)
	elseif opcode == 0x0E then
		if operandWidth == 32 then
			self:push32(self.seg.CS)
		else
			self:push16(self.seg.CS)
		end
	elseif opcode == 0x16 then
		if operandWidth == 32 then
			self:push32(self.seg.SS)
		else
			self:push16(self.seg.SS)
		end
	elseif opcode == 0x17 then
		local value = operandWidth == 32 and self:pop32() or self:pop16()
		self:setSeg(2, value % 0x10000)
	elseif opcode == 0x1E then
		if operandWidth == 32 then
			self:push32(self.seg.DS)
		else
			self:push16(self.seg.DS)
		end
	elseif opcode == 0x1F then
		local value = operandWidth == 32 and self:pop32() or self:pop16()
		self:setSeg(3, value % 0x10000)
	elseif opcode == 0xF8 then
		self:setFlag(FLAG_CF, false)
	elseif opcode == 0xF9 then
		self:setFlag(FLAG_CF, true)
	elseif opcode == 0xFA then
		self:setFlag(FLAG_IF, false)
	elseif opcode == 0xFB then
		self:setFlag(FLAG_IF, true)
	elseif opcode == 0xFC then
		self:setFlag(FLAG_DF, false)
	elseif opcode == 0xFD then
		self:setFlag(FLAG_DF, true)
	elseif opcode == 0xF4 then
		self.halted = true
	elseif opcode >= 0x40 and opcode <= 0x47 then
		local reg = opcode - 0x40
		self:_setRegByWidth(reg, operandWidth, self:_inc(operandWidth, self:_getRegByWidth(reg, operandWidth)))
	elseif opcode >= 0x48 and opcode <= 0x4F then
		local reg = opcode - 0x48
		self:_setRegByWidth(reg, operandWidth, self:_dec(operandWidth, self:_getRegByWidth(reg, operandWidth)))
	elseif opcode >= 0x50 and opcode <= 0x57 then
		if operandWidth == 32 then
			self:push32(self:getReg32(opcode - 0x50))
		else
			self:push16(self:getReg16(opcode - 0x50))
		end
	elseif opcode >= 0x58 and opcode <= 0x5F then
		if operandWidth == 32 then
			self:setReg32(opcode - 0x58, self:pop32())
		else
			self:setReg16(opcode - 0x58, self:pop16())
		end
	elseif opcode == 0x68 then
		if operandWidth == 32 then
			self:push32(self:fetch32())
		else
			self:push16(self:fetch16())
		end
	elseif opcode == 0x6A then
		local value = signExtend8(self:fetch8())
		if operandWidth == 32 then
			self:push32(value % 0x100000000)
		else
			self:push16(value % 0x10000)
		end
	elseif opcode == 0x8E then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		if decoded.reg == 1 then
			self:_raiseException(VECTOR_UD, 0, "unsupported MOV CS, r/m16")
		end
		self:setSeg(decoded.reg, self:_readRM16(decoded))
	elseif opcode == 0x8C then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRM16(decoded, self:getSeg(decoded.reg))
	elseif opcode == 0x8B then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_setRegByWidth(decoded.reg, operandWidth, self:_readRMByWidth(decoded, operandWidth))
	elseif opcode == 0x8D then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local _segment, offset = self:_effectiveAddress(decoded)
		self:_setRegByWidth(decoded.reg, operandWidth, offset)
	elseif opcode == 0xC4 then
		self:_loadFarPointerRegister(self:_decodeModRMForAddressSize(addressOverride), 0, operandWidth)
	elseif opcode == 0xC5 then
		self:_loadFarPointerRegister(self:_decodeModRMForAddressSize(addressOverride), 3, operandWidth)
	elseif opcode == 0x89 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRMByWidth(decoded, operandWidth, self:_getRegByWidth(decoded.reg, operandWidth))
	elseif opcode == 0x8A then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:setReg8(decoded.reg, self:_readRM8(decoded))
	elseif opcode == 0x88 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRM8(decoded, self:getReg8(decoded.reg))
	elseif opcode == 0xC6 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local imm = self:fetch8()
		self:_writeRM8(decoded, imm)
	elseif opcode == 0xC7 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local imm = self:_fetchImmediate(operandWidth)
		self:_writeRMByWidth(decoded, operandWidth, imm)
	elseif opcode == 0x00 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRM8(decoded, self:_add(8, self:_readRM8(decoded), self:getReg8(decoded.reg)))
	elseif opcode == 0x01 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRMByWidth(
			decoded,
			operandWidth,
			self:_add(operandWidth, self:_readRMByWidth(decoded, operandWidth), self:_getRegByWidth(decoded.reg, operandWidth))
		)
	elseif opcode == 0x02 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:setReg8(decoded.reg, self:_add(8, self:getReg8(decoded.reg), self:_readRM8(decoded)))
	elseif opcode == 0x03 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_setRegByWidth(
			decoded.reg,
			operandWidth,
			self:_add(operandWidth, self:_getRegByWidth(decoded.reg, operandWidth), self:_readRMByWidth(decoded, operandWidth))
		)
	elseif opcode == 0x04 then
		self:setReg8(0, self:_add(8, self:getReg8(0), self:fetch8()))
	elseif opcode == 0x05 then
		self:_setRegByWidth(
			0,
			operandWidth,
			self:_add(operandWidth, self:_getRegByWidth(0, operandWidth), self:_fetchImmediate(operandWidth))
		)
	elseif opcode == 0x08 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRM8(decoded, self:_logicBinary(8, self:_readRM8(decoded), self:getReg8(decoded.reg), "or"))
	elseif opcode == 0x09 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRMByWidth(
			decoded,
			operandWidth,
			self:_logicBinary(operandWidth, self:_readRMByWidth(decoded, operandWidth), self:_getRegByWidth(decoded.reg, operandWidth), "or")
		)
	elseif opcode == 0x0A then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:setReg8(decoded.reg, self:_logicBinary(8, self:getReg8(decoded.reg), self:_readRM8(decoded), "or"))
	elseif opcode == 0x0B then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_setRegByWidth(
			decoded.reg,
			operandWidth,
			self:_logicBinary(operandWidth, self:_getRegByWidth(decoded.reg, operandWidth), self:_readRMByWidth(decoded, operandWidth), "or")
		)
	elseif opcode == 0x0C then
		self:setReg8(0, self:_logicBinary(8, self:getReg8(0), self:fetch8(), "or"))
	elseif opcode == 0x0D then
		self:_setRegByWidth(
			0,
			operandWidth,
			self:_logicBinary(operandWidth, self:_getRegByWidth(0, operandWidth), self:_fetchImmediate(operandWidth), "or")
		)
	elseif opcode == 0x20 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRM8(decoded, self:_logicBinary(8, self:_readRM8(decoded), self:getReg8(decoded.reg), "and"))
	elseif opcode == 0x21 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRMByWidth(
			decoded,
			operandWidth,
			self:_logicBinary(operandWidth, self:_readRMByWidth(decoded, operandWidth), self:_getRegByWidth(decoded.reg, operandWidth), "and")
		)
	elseif opcode == 0x22 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:setReg8(decoded.reg, self:_logicBinary(8, self:getReg8(decoded.reg), self:_readRM8(decoded), "and"))
	elseif opcode == 0x23 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_setRegByWidth(
			decoded.reg,
			operandWidth,
			self:_logicBinary(operandWidth, self:_getRegByWidth(decoded.reg, operandWidth), self:_readRMByWidth(decoded, operandWidth), "and")
		)
	elseif opcode == 0x24 then
		self:setReg8(0, self:_logicBinary(8, self:getReg8(0), self:fetch8(), "and"))
	elseif opcode == 0x25 then
		self:_setRegByWidth(
			0,
			operandWidth,
			self:_logicBinary(operandWidth, self:_getRegByWidth(0, operandWidth), self:_fetchImmediate(operandWidth), "and")
		)
	elseif opcode == 0x28 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRM8(decoded, self:_sub(8, self:_readRM8(decoded), self:getReg8(decoded.reg)))
	elseif opcode == 0x29 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRMByWidth(
			decoded,
			operandWidth,
			self:_sub(operandWidth, self:_readRMByWidth(decoded, operandWidth), self:_getRegByWidth(decoded.reg, operandWidth))
		)
	elseif opcode == 0x2A then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:setReg8(decoded.reg, self:_sub(8, self:getReg8(decoded.reg), self:_readRM8(decoded)))
	elseif opcode == 0x2B then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_setRegByWidth(
			decoded.reg,
			operandWidth,
			self:_sub(operandWidth, self:_getRegByWidth(decoded.reg, operandWidth), self:_readRMByWidth(decoded, operandWidth))
		)
	elseif opcode == 0x2C then
		self:setReg8(0, self:_sub(8, self:getReg8(0), self:fetch8()))
	elseif opcode == 0x2D then
		self:_setRegByWidth(
			0,
			operandWidth,
			self:_sub(operandWidth, self:_getRegByWidth(0, operandWidth), self:_fetchImmediate(operandWidth))
		)
	elseif opcode == 0x30 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRM8(decoded, self:_logicBinary(8, self:_readRM8(decoded), self:getReg8(decoded.reg), "xor"))
	elseif opcode == 0x31 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_writeRMByWidth(
			decoded,
			operandWidth,
			self:_logicBinary(operandWidth, self:_readRMByWidth(decoded, operandWidth), self:_getRegByWidth(decoded.reg, operandWidth), "xor")
		)
	elseif opcode == 0x33 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local value =
			bit32.bxor(self:_getRegByWidth(decoded.reg, operandWidth), self:_readRMByWidth(decoded, operandWidth))
		self:_setRegByWidth(decoded.reg, operandWidth, value)
		self:_updateLogicFlags(operandWidth, value)
	elseif opcode == 0x32 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local value = bit32.bxor(self:getReg8(decoded.reg), self:_readRM8(decoded))
		self:setReg8(decoded.reg, value)
		self:_updateLogicFlags(8, value)
	elseif opcode == 0x34 then
		self:setReg8(0, self:_logicBinary(8, self:getReg8(0), self:fetch8(), "xor"))
	elseif opcode == 0x35 then
		self:_setRegByWidth(
			0,
			operandWidth,
			self:_logicBinary(operandWidth, self:_getRegByWidth(0, operandWidth), self:_fetchImmediate(operandWidth), "xor")
		)
	elseif opcode == 0x84 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_test(8, self:_readRM8(decoded), self:getReg8(decoded.reg))
	elseif opcode == 0x85 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_test(
			operandWidth,
			self:_readRMByWidth(decoded, operandWidth),
			self:_getRegByWidth(decoded.reg, operandWidth)
		)
	elseif opcode == 0x80 or opcode == 0x81 or opcode == 0x83 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local width = opcode == 0x80 and 8 or operandWidth
		local imm
		if opcode == 0x83 then
			imm = signExtend8(self:fetch8()) % (maskForWidth(width) + 1)
		else
			imm = self:_fetchImmediate(width)
		end
		local left = self:_readRMByWidth(decoded, width)
		local result = nil
		if decoded.reg == 0 then
			result = self:_add(width, left, imm)
		elseif decoded.reg == 1 then
			result = self:_logicBinary(width, left, imm, "or")
		elseif decoded.reg == 2 then
			result = self:_adc(width, left, imm)
		elseif decoded.reg == 3 then
			result = self:_sbb(width, left, imm)
		elseif decoded.reg == 4 then
			result = self:_logicBinary(width, left, imm, "and")
		elseif decoded.reg == 5 then
			result = self:_sub(width, left, imm)
		elseif decoded.reg == 6 then
			result = self:_logicBinary(width, left, imm, "xor")
		elseif decoded.reg == 7 then
			self:_sub(width, left, imm)
		else
			self:_raiseException(VECTOR_UD, 0, "unsupported group 80/81 op")
		end
		if result ~= nil then
			self:_writeRMByWidth(decoded, width, result)
		end
	elseif (opcode >= 0xD0 and opcode <= 0xD3) or opcode == 0xC0 or opcode == 0xC1 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local width
		local count
		if opcode == 0xD0 then
			width = 8
			count = 1
		elseif opcode == 0xD1 then
			width = operandWidth
			count = 1
		elseif opcode == 0xD2 then
			width = 8
			count = self:getReg8(1)
		elseif opcode == 0xD3 then
			width = operandWidth
			count = self:getReg8(1)
		elseif opcode == 0xC0 then
			width = 8
			count = self:fetch8()
		else
			width = operandWidth
			count = self:fetch8()
		end
		local operation = (
			{ [0] = "rol", [1] = "ror", [2] = "rcl", [3] = "rcr", [4] = "shl", [5] = "shr", [7] = "sar" }
		)[decoded.reg]
		if not operation then
			self:_raiseException(VECTOR_UD, 0, string.format("unsupported shift/rotate group /%d", decoded.reg))
		end
		local value = self:_readRMByWidth(decoded, width)
		local result = self:_shiftRotate(width, operation, value, count)
		self:_writeRMByWidth(decoded, width, result)
	elseif opcode == 0xFE then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local value = self:_readRM8(decoded)
		if decoded.reg == 0 then
			self:_writeRM8(decoded, self:_inc(8, value))
		elseif decoded.reg == 1 then
			self:_writeRM8(decoded, self:_dec(8, value))
		else
			self:_raiseException(VECTOR_UD, 0, string.format("unsupported FE group /%d", decoded.reg))
		end
	elseif opcode == 0xF6 or opcode == 0xF7 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		local width = opcode == 0xF6 and 8 or operandWidth
		local value = self:_readRMByWidth(decoded, width)
		if decoded.reg == 0 then
			local imm = self:_fetchImmediate(width == 8 and 8 or width)
			local result = bit32.band(value, imm)
			self:_updateLogicFlags(width, result)
		elseif decoded.reg == 2 then
			self:_writeRMByWidth(decoded, width, self:_mulDivGroup(width, "not", value))
		elseif decoded.reg == 3 then
			self:_writeRMByWidth(decoded, width, self:_mulDivGroup(width, "neg", value))
		elseif decoded.reg == 4 then
			self:_mulDivGroup(width, "mul", value)
		elseif decoded.reg == 5 then
			self:_mulDivGroup(width, "imul", value)
		elseif decoded.reg == 6 then
			self:_mulDivGroup(width, "div", value)
		elseif decoded.reg == 7 then
			self:_mulDivGroup(width, "idiv", value)
		else
			self:_raiseException(VECTOR_UD, 0, string.format("unsupported F6/F7 group /%d", decoded.reg))
		end
	elseif opcode == 0x38 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_sub(8, self:_readRM8(decoded), self:getReg8(decoded.reg))
	elseif opcode == 0x39 then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_sub(
			operandWidth,
			self:_readRMByWidth(decoded, operandWidth),
			self:_getRegByWidth(decoded.reg, operandWidth)
		)
	elseif opcode == 0x3A then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_sub(8, self:getReg8(decoded.reg), self:_readRM8(decoded))
	elseif opcode == 0x3B then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		self:_sub(
			operandWidth,
			self:_getRegByWidth(decoded.reg, operandWidth),
			self:_readRMByWidth(decoded, operandWidth)
		)
	elseif opcode == 0x3C then
		self:_sub(8, self:getReg8(0), self:fetch8())
	elseif opcode == 0x3D then
		self:_sub(operandWidth, self:_getRegByWidth(0, operandWidth), self:_fetchImmediate(operandWidth))
	elseif opcode == 0xE8 then
		local rel = operandWidth == 32 and signExtend32(self:fetch32()) or signExtend16(self:fetch16())
		local returnIP = self:_currentIP()
		if operandWidth == 32 then
			self:push32(returnIP)
		else
			self:push16(returnIP % 0x10000)
		end
		self:_setInstructionPointer(returnIP + rel)
	elseif opcode == 0xE9 then
		local rel = operandWidth == 32 and signExtend32(self:fetch32()) or signExtend16(self:fetch16())
		self:_setInstructionPointer(self:_currentIP() + rel)
	elseif opcode == 0x9A then
		local offset = operandWidth == 32 and self:fetch32() or self:fetch16()
		local selector = self:fetch16()
		self:_executeFarCall(selector, offset, operandWidth)
	elseif opcode == 0xEA then
		local offset = operandWidth == 32 and self:fetch32() or self:fetch16()
		local selector = self:fetch16()
		self:_executeFarJump(selector, offset)
	elseif opcode == 0xEB then
		local rel = signExtend8(self:fetch8())
		self:_setInstructionPointer(self:_currentIP() + rel)
	elseif opcode >= 0x70 and opcode <= 0x7F then
		local rel = signExtend8(self:fetch8())
		if self:_conditionTrue(opcode) then
			self:_setInstructionPointer(self:_currentIP() + rel)
		end
	elseif opcode == 0xE0 then
		local rel = signExtend8(self:fetch8())
		local useECX = self:_address32Enabled(addressOverride)
		if useECX then
			self:setReg32(1, (self:getReg32(1) - 1) % 0x100000000)
			if self:getReg32(1) ~= 0 and not self:getFlag(FLAG_ZF) then
				self:_setInstructionPointer(self:_currentIP() + rel)
			end
		else
			self:setReg16(1, (self:getReg16(1) - 1) % 0x10000)
			if self:getReg16(1) ~= 0 and not self:getFlag(FLAG_ZF) then
				self:_setInstructionPointer(self:_currentIP() + rel)
			end
		end
	elseif opcode == 0xE1 then
		local rel = signExtend8(self:fetch8())
		local useECX = self:_address32Enabled(addressOverride)
		if useECX then
			self:setReg32(1, (self:getReg32(1) - 1) % 0x100000000)
			if self:getReg32(1) ~= 0 and self:getFlag(FLAG_ZF) then
				self:_setInstructionPointer(self:_currentIP() + rel)
			end
		else
			self:setReg16(1, (self:getReg16(1) - 1) % 0x10000)
			if self:getReg16(1) ~= 0 and self:getFlag(FLAG_ZF) then
				self:_setInstructionPointer(self:_currentIP() + rel)
			end
		end
	elseif opcode == 0xE2 then
		local rel = signExtend8(self:fetch8())
		local useECX = self:_address32Enabled(addressOverride)
		if useECX then
			self:setReg32(1, (self:getReg32(1) - 1) % 0x100000000)
			if self:getReg32(1) ~= 0 then
				self:_setInstructionPointer(self:_currentIP() + rel)
			end
		else
			self:setReg16(1, (self:getReg16(1) - 1) % 0x10000)
			if self:getReg16(1) ~= 0 then
				self:_setInstructionPointer(self:_currentIP() + rel)
			end
		end
	elseif opcode == 0xE3 then
		local rel = signExtend8(self:fetch8())
		if self:_address32Enabled(addressOverride) then
			if self:getReg32(1) == 0 then
				self:_setInstructionPointer(self:_currentIP() + rel)
			end
		elseif self:getReg16(1) == 0 then
			self:_setInstructionPointer(self:_currentIP() + rel)
		end
	elseif opcode == 0xA0 then
		local offset = self:_address32Enabled(addressOverride) and self:fetch32() or self:fetch16()
		self:setReg8(0, self:_readMoffsByWidth(offset, 8))
	elseif opcode == 0xA1 then
		local offset = self:_address32Enabled(addressOverride) and self:fetch32() or self:fetch16()
		self:_setRegByWidth(0, operandWidth, self:_readMoffsByWidth(offset, operandWidth))
	elseif opcode == 0xA2 then
		local offset = self:_address32Enabled(addressOverride) and self:fetch32() or self:fetch16()
		self:_writeMoffsByWidth(offset, 8, self:getReg8(0))
	elseif opcode == 0xA3 then
		local offset = self:_address32Enabled(addressOverride) and self:fetch32() or self:fetch16()
		self:_writeMoffsByWidth(offset, operandWidth, self:_getRegByWidth(0, operandWidth))
	elseif opcode == 0xA8 then
		self:_test(8, self:getReg8(0), self:fetch8())
	elseif opcode == 0xA9 then
		self:_test(operandWidth, self:_getRegByWidth(0, operandWidth), self:_fetchImmediate(operandWidth))
	elseif
		opcode == 0xA4
		or opcode == 0xA5
		or opcode == 0xA6
		or opcode == 0xA7
		or opcode == 0xAA
		or opcode == 0xAB
		or opcode == 0xAC
		or opcode == 0xAD
		or opcode == 0xAE
		or opcode == 0xAF
		or opcode == 0x6C
		or opcode == 0x6D
		or opcode == 0x6E
		or opcode == 0x6F
	then
		self:_executeStringOp(opcode, repeatPrefix, operandWidth, addressOverride)
	elseif opcode == 0xFF then
		local decoded = self:_decodeModRMForAddressSize(addressOverride)
		if decoded.reg == 0 then
			self:_writeRMByWidth(
				decoded,
				operandWidth,
				self:_inc(operandWidth, self:_readRMByWidth(decoded, operandWidth))
			)
		elseif decoded.reg == 1 then
			self:_writeRMByWidth(
				decoded,
				operandWidth,
				self:_dec(operandWidth, self:_readRMByWidth(decoded, operandWidth))
			)
		elseif decoded.reg == 2 then
			local target = self:_readRMByWidth(decoded, operandWidth)
			local returnIP = self:_currentIP()
			if operandWidth == 32 then
				self:push32(returnIP)
			else
				self:push16(returnIP % 0x10000)
			end
			self:_setInstructionPointer(target)
		elseif decoded.reg == 3 then
			local farOffset, farSelector = self:_readFarPointer(decoded, operandWidth)
			self:_executeFarCall(farSelector, farOffset, operandWidth)
		elseif decoded.reg == 4 then
			self:_setInstructionPointer(self:_readRMByWidth(decoded, operandWidth))
		elseif decoded.reg == 5 then
			local farOffset, farSelector = self:_readFarPointer(decoded, operandWidth)
			self:_executeFarJump(farSelector, farOffset)
		elseif decoded.reg == 6 then
			local value = self:_readRMByWidth(decoded, operandWidth)
			if operandWidth == 32 then
				self:push32(value)
			else
				self:push16(value)
			end
		else
			self:_raiseException(
				VECTOR_UD,
				0,
				string.format("unsupported FF group /%d at %04X:%04X", decoded.reg, self.seg.CS, startIP)
			)
		end
	elseif opcode == 0xC3 then
		if operandWidth == 32 then
			self:_setInstructionPointer(self:pop32())
		else
			self:_setInstructionPointer(self:pop16())
		end
	elseif opcode == 0xC2 then
		local adjust = self:fetch16()
		if operandWidth == 32 then
			self:_setInstructionPointer(self:pop32())
		else
			self:_setInstructionPointer(self:pop16())
		end
		self:_setStackPointer((self:_stackPointer() + adjust) % 0x100000000, self:_stackDefault32())
	elseif opcode == 0xCB then
		self:_returnFar(operandWidth, 0, false)
	elseif opcode == 0xCA then
		local adjust = self:fetch16()
		self:_returnFar(operandWidth, adjust, false)
	elseif opcode == 0xC9 then
		local use32BitStack = self:_stackDefault32()
		self:_setStackPointer(use32BitStack and self:getReg32(5) or self:getReg16(5), use32BitStack)
		if operandWidth == 32 then
			self:setReg32(5, self:pop32())
		else
			self:setReg16(5, self:pop16())
		end
	elseif opcode == 0xCF then
		self:_returnFar(operandWidth, 0, true)
	elseif opcode == 0xCD then
		local vector = self:fetch8()
		self:_invokeInterrupt(vector, false, nil, false)
	elseif opcode == 0xE4 then
		local port = self:fetch8()
		self.stats.portReads = self.stats.portReads + 1
		self:setReg8(0, self.bus:portRead(port))
	elseif opcode == 0xE5 then
		local port = self:fetch8()
		self.stats.portReads = self.stats.portReads + 1
		self:_setRegByWidth(0, operandWidth, self:_portReadByWidth(port, operandWidth))
	elseif opcode == 0xEC then
		local port = self.reg16.DX
		self.stats.portReads = self.stats.portReads + 1
		self:setReg8(0, self.bus:portRead(port))
	elseif opcode == 0xED then
		local port = self.reg16.DX
		self.stats.portReads = self.stats.portReads + 1
		self:_setRegByWidth(0, operandWidth, self:_portReadByWidth(port, operandWidth))
	elseif opcode == 0xE6 then
		local port = self:fetch8()
		self.stats.portWrites = self.stats.portWrites + 1
		self.bus:portWrite(port, self:getReg8(0))
	elseif opcode == 0xE7 then
		local port = self:fetch8()
		self.stats.portWrites = self.stats.portWrites + 1
		self:_portWriteByWidth(port, operandWidth, self:_getRegByWidth(0, operandWidth))
	elseif opcode == 0xEE then
		local port = self.reg16.DX
		self.stats.portWrites = self.stats.portWrites + 1
		self.bus:portWrite(port, self:getReg8(0))
	elseif opcode == 0xEF then
		local port = self.reg16.DX
		self.stats.portWrites = self.stats.portWrites + 1
		self:_portWriteByWidth(port, operandWidth, self:_getRegByWidth(0, operandWidth))
	else
		self:_raiseException(
			VECTOR_UD,
			0,
			string.format("unsupported opcode 0x%02X at %04X:%08X", opcode, self.seg.CS, startIP)
		)
	end

	self.stats.instructions = self.stats.instructions + 1
	self._segmentOverride = nil
	return opcode
end

function Cpu80386:step()
	local ok, result = xpcall(function()
		return self:_stepInternal()
	end, function(err)
		return err
	end)
	self._segmentOverride = nil

	if ok then
		return result
	end

	if type(result) == "table" and result.__x86Exception then
		local delivered, deliveryResult = xpcall(function()
			return self:_invokeInterrupt(result.vector, false, result.errorCode, true)
		end, function(err)
			return err
		end)
		if delivered and deliveryResult then
			self.stats.instructions = self.stats.instructions + 1
			return string.format("EX_%02X", result.vector)
		end
		result = delivered and result.message or deliveryResult
	end

	self._lastError = type(result) == "table" and result.message or tostring(result)
	self.halted = true
	error(self._lastError)
end

return Cpu80386
