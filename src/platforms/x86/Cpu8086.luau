local Cpu8086 = {}
Cpu8086.__index = Cpu8086

local FLAG_CF = 0x0001
local FLAG_PF = 0x0004
local FLAG_AF = 0x0010
local FLAG_ZF = 0x0040
local FLAG_SF = 0x0080
local FLAG_IF = 0x0200
local FLAG_DF = 0x0400
local FLAG_OF = 0x0800
local FLAGS16_WRITE_MASK = 0x0FD5

local REG16_NAMES = { "AX", "CX", "DX", "BX", "SP", "BP", "SI", "DI" }
local SEGMENT_NAMES = { "ES", "CS", "SS", "DS" }
local SEGMENT_PREFIX_TO_CODE = {
	[0x26] = 0,
	[0x2E] = 1,
	[0x36] = 2,
	[0x3E] = 3,
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

local function maskForWidth(width)
	return width == 8 and 0xFF or 0xFFFF
end

local function signBit(width)
	return width == 8 and 0x80 or 0x8000
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

function Cpu8086.new(bus, config)
	local self = setmetatable({}, Cpu8086)
	self.bus = bus
	self.config = config
	self.x86 = config.X86 or {}
	self.reg16 = {
		AX = 0,
		CX = 0,
		DX = 0,
		BX = 0,
		SP = 0,
		BP = 0,
		SI = 0,
		DI = 0,
	}
	self.seg = {
		ES = 0,
		CS = 0,
		SS = 0,
		DS = 0,
	}
	self.ip = 0
	self.flags = 0x0002
	self.halted = false
	self._bios = nil
	self._lastError = nil
	self._lastStep = {
		opcode = nil,
		cs = 0,
		ip = 0,
	}
	self._segmentOverride = nil
	self.stats = {
		cycles = 0,
		instructions = 0,
		interrupts = 0,
		memReads = 0,
		memWrites = 0,
		portReads = 0,
		portWrites = 0,
	}
	self:reset()
	return self
end

function Cpu8086:attachBIOS(bios)
	self._bios = bios
end

function Cpu8086:reset()
	for name in pairs(self.reg16) do
		self.reg16[name] = 0
	end
	self.seg.ES = 0
	self.seg.DS = 0
	self.seg.SS = 0
	self.seg.CS = self.x86.RESET_VECTOR_SEG or 0xF000
	self.ip = self.x86.RESET_VECTOR_OFF or 0xFFF0
	self.flags = 0x0002
	self.halted = false
	self._lastError = nil
	self._lastStep.opcode = nil
	self._lastStep.cs = self.seg.CS
	self._lastStep.ip = self.ip
	self._segmentOverride = nil
	for name in pairs(self.stats) do
		self.stats[name] = 0
	end
end

function Cpu8086:getLinearPC()
	return bit32.band(self.seg.CS * 16 + self.ip, 0xFFFFF)
end

function Cpu8086:getStats()
	return {
		cycles = self.stats.cycles,
		instructions = self.stats.instructions,
		interrupts = self.stats.interrupts,
		memReads = self.stats.memReads,
		memWrites = self.stats.memWrites,
		portReads = self.stats.portReads,
		portWrites = self.stats.portWrites,
		halted = self.halted,
		lastError = self._lastError,
		pc = self:getLinearPC(),
		cs = self.seg.CS,
		ip = self.ip,
		lastOpcode = self._lastStep.opcode,
		lastCS = self._lastStep.cs,
		lastIP = self._lastStep.ip,
	}
end

function Cpu8086:getFlag(mask)
	return bit32.band(self.flags, mask) ~= 0
end

function Cpu8086:setFlag(mask, enabled)
	if enabled then
		self.flags = bit32.bor(self.flags, mask)
	else
		self.flags = bit32.band(self.flags, bit32.bnot(mask))
	end
end

function Cpu8086:getReg16(code)
	local name = REG16_NAMES[(tonumber(code) or 0) + 1]
	return (name and self.reg16[name]) or 0
end

function Cpu8086:setReg16(code, value)
	local name = REG16_NAMES[(tonumber(code) or 0) + 1]
	if not name then
		return
	end

	local v = (tonumber(value) or 0) % 0x10000
	self.reg16[name] = v
end

function Cpu8086:getReg8(code)
	local regIndex = code % 4
	local word = self:getReg16(regIndex)
	if code < 4 then
		return word % 0x100
	end
	return math.floor(word / 0x100) % 0x100
end

function Cpu8086:setReg8(code, value)
	local regIndex = code % 4
	local word = self:getReg16(regIndex)
	local byteValue = (tonumber(value) or 0) % 0x100
	if code < 4 then
		self:setReg16(regIndex, bit32.bor(bit32.band(word, 0xFF00), byteValue))
	else
		self:setReg16(regIndex, bit32.bor(bit32.band(word, 0x00FF), bit32.lshift(byteValue, 8)))
	end
end

function Cpu8086:getSeg(code)
	local name = SEGMENT_NAMES[(tonumber(code) or 0) + 1]
	return (name and self.seg[name]) or 0
end

function Cpu8086:setSeg(code, value)
	local name = SEGMENT_NAMES[(tonumber(code) or 0) + 1]
	if not name then
		return
	end

	local v = (tonumber(value) or 0) % 0x10000
	self.seg[name] = v
end

function Cpu8086:_applySegmentOverride(segment)
	if self._segmentOverride == nil then
		return segment
	end
	return self:getSeg(self._segmentOverride)
end

function Cpu8086:_conditionTrue(opcode)
	local cf = self:getFlag(FLAG_CF)
	local zf = self:getFlag(FLAG_ZF)
	local sf = self:getFlag(FLAG_SF)
	local of = self:getFlag(FLAG_OF)
	local pf = self:getFlag(FLAG_PF)
	local signedLess = sf ~= of

	if opcode == 0x70 then
		return of
	elseif opcode == 0x71 then
		return not of
	elseif opcode == 0x72 then
		return cf
	elseif opcode == 0x73 then
		return not cf
	elseif opcode == 0x74 then
		return zf
	elseif opcode == 0x75 then
		return not zf
	elseif opcode == 0x76 then
		return cf or zf
	elseif opcode == 0x77 then
		return not cf and not zf
	elseif opcode == 0x78 then
		return sf
	elseif opcode == 0x79 then
		return not sf
	elseif opcode == 0x7A then
		return pf
	elseif opcode == 0x7B then
		return not pf
	elseif opcode == 0x7C then
		return signedLess
	elseif opcode == 0x7D then
		return not signedLess
	elseif opcode == 0x7E then
		return signedLess or zf
	elseif opcode == 0x7F then
		return not signedLess and not zf
	end

	return false
end

function Cpu8086:linearAddress(segment, offset)
	return ((segment % 0x10000) * 16 + (offset % 0x10000)) % 0x100000000
end

function Cpu8086:readPhysical8(address)
	self.stats.memReads = self.stats.memReads + 1
	return self.bus:memRead(address)
end

function Cpu8086:writePhysical8(address, value)
	self.stats.memWrites = self.stats.memWrites + 1
	self.bus:memWrite(address, value % 0x100)
end

function Cpu8086:readPhysical16(address)
	local lo = self:readPhysical8(address)
	local hi = self:readPhysical8(address + 1)
	return lo + hi * 256
end

function Cpu8086:writePhysical16(address, value)
	local v = (tonumber(value) or 0) % 0x10000
	self:writePhysical8(address, v % 0x100)
	self:writePhysical8(address + 1, math.floor(v / 0x100) % 0x100)
end

function Cpu8086:readMem8(segment, offset)
	return self:readPhysical8(self:linearAddress(segment, offset))
end

function Cpu8086:readMem16(segment, offset)
	return self:readPhysical16(self:linearAddress(segment, offset))
end

function Cpu8086:writeMem8(segment, offset, value)
	self:writePhysical8(self:linearAddress(segment, offset), value)
end

function Cpu8086:writeMem16(segment, offset, value)
	self:writePhysical16(self:linearAddress(segment, offset), value)
end

function Cpu8086:fetch8()
	local value = self:readMem8(self.seg.CS, self.ip)
	self.ip = (self.ip + 1) % 0x10000
	return value
end

function Cpu8086:fetch16()
	local lo = self:fetch8()
	local hi = self:fetch8()
	return lo + hi * 256
end

function Cpu8086:push16(value)
	self.reg16.SP = (self.reg16.SP - 2) % 0x10000
	self:writeMem16(self.seg.SS, self.reg16.SP, value)
end

function Cpu8086:pop16()
	local value = self:readMem16(self.seg.SS, self.reg16.SP)
	self.reg16.SP = (self.reg16.SP + 2) % 0x10000
	return value
end

function Cpu8086:_decodeModRM()
	local byte = self:fetch8()
	local mod = bit32.rshift(byte, 6)
	local reg = bit32.band(bit32.rshift(byte, 3), 0x07)
	local rm = bit32.band(byte, 0x07)
	local disp = 0
	if mod == 1 then
		disp = signExtend8(self:fetch8())
	elseif mod == 2 or (mod == 0 and rm == 6) then
		disp = signExtend16(self:fetch16())
	end
	return {
		mod = mod,
		reg = reg,
		rm = rm,
		disp = disp,
	}
end

function Cpu8086:_effectiveAddress(decoded)
	if decoded.mod == 3 then
		return nil, nil
	end

	local base = 0
	local segment = self.seg.DS
	if decoded.mod == 0 and decoded.rm == 6 then
		base = decoded.disp
	else
		if decoded.rm == 0 then
			base = self.reg16.BX + self.reg16.SI
		elseif decoded.rm == 1 then
			base = self.reg16.BX + self.reg16.DI
		elseif decoded.rm == 2 then
			base = self.reg16.BP + self.reg16.SI
			segment = self.seg.SS
		elseif decoded.rm == 3 then
			base = self.reg16.BP + self.reg16.DI
			segment = self.seg.SS
		elseif decoded.rm == 4 then
			base = self.reg16.SI
		elseif decoded.rm == 5 then
			base = self.reg16.DI
		elseif decoded.rm == 6 then
			base = self.reg16.BP
			segment = self.seg.SS
		elseif decoded.rm == 7 then
			base = self.reg16.BX
		end
		base = base + decoded.disp
	end

	return self:_applySegmentOverride(segment), base % 0x10000
end

function Cpu8086:_readRM8(decoded)
	if decoded.mod == 3 then
		return self:getReg8(decoded.rm)
	end
	local segment, offset = self:_effectiveAddress(decoded)
	return self:readMem8(segment, offset)
end

function Cpu8086:_readRM16(decoded)
	if decoded.mod == 3 then
		return self:getReg16(decoded.rm)
	end
	local segment, offset = self:_effectiveAddress(decoded)
	return self:readMem16(segment, offset)
end

function Cpu8086:_writeRM8(decoded, value)
	if decoded.mod == 3 then
		self:setReg8(decoded.rm, value)
		return
	end
	local segment, offset = self:_effectiveAddress(decoded)
	self:writeMem8(segment, offset, value)
end

function Cpu8086:_writeRM16(decoded, value)
	if decoded.mod == 3 then
		self:setReg16(decoded.rm, value)
		return
	end
	local segment, offset = self:_effectiveAddress(decoded)
	self:writeMem16(segment, offset, value)
end

function Cpu8086:_updateLogicFlags(width, value)
	local masked = value % (maskForWidth(width) + 1)
	self:setFlag(FLAG_CF, false)
	self:setFlag(FLAG_OF, false)
	self:setFlag(FLAG_AF, false)
	self:setFlag(FLAG_ZF, masked == 0)
	self:setFlag(FLAG_SF, bit32.band(masked, signBit(width)) ~= 0)
	self:setFlag(FLAG_PF, self:_computePF(masked))
end

function Cpu8086:_test(width, a, b)
	local result = bit32.band(tonumber(a) or 0, tonumber(b) or 0)
	self:_updateLogicFlags(width, result)
	return result
end

function Cpu8086:_readMoffsByWidth(offset, width)
	local segment = self:_applySegmentOverride(self.seg.DS)
	if width == 8 then
		return self:readMem8(segment, offset)
	elseif width == 16 then
		return self:readMem16(segment, offset)
	elseif self.readMem32 then
		return self:readMem32(segment, offset)
	end
	return 0
end

function Cpu8086:_writeMoffsByWidth(offset, width, value)
	local segment = self:_applySegmentOverride(self.seg.DS)
	if width == 8 then
		self:writeMem8(segment, offset, value)
	elseif width == 16 then
		self:writeMem16(segment, offset, value)
	elseif self.writeMem32 then
		self:writeMem32(segment, offset, value)
	end
end

function Cpu8086:_add(width, a, b)
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

function Cpu8086:_computePF(value)
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

function Cpu8086:_sub(width, a, b)
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

function Cpu8086:_adc(width, a, b)
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

function Cpu8086:_sbb(width, a, b)
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

function Cpu8086:_logicBinary(width, left, right, operation)
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

function Cpu8086:_inc(width, value)
	local carry = self:getFlag(FLAG_CF)
	local result = self:_add(width, value, 1)
	self:setFlag(FLAG_CF, carry)
	self:setFlag(FLAG_AF, bit32.band(value, 0x0F) == 0x0F)
	return result
end

function Cpu8086:_dec(width, value)
	local carry = self:getFlag(FLAG_CF)
	local result = self:_sub(width, value, 1)
	self:setFlag(FLAG_CF, carry)
	self:setFlag(FLAG_AF, bit32.band(value, 0x0F) == 0x00)
	return result
end

function Cpu8086:_shiftRotate(width, operation, value, count)
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

function Cpu8086:_raiseDivideError()
	self._lastError = "divide error"
	error(self._lastError)
end

function Cpu8086:_mulDivGroup(width, operation, value)
	local mask = maskForWidth(width)
	local base = mask + 1
	local maskedValue = (tonumber(value) or 0) % base

	if operation == "not" then
		return bit32.band(bit32.bnot(maskedValue), mask)
	elseif operation == "neg" then
		local result = self:_sub(width, 0, maskedValue)
		self:setFlag(FLAG_CF, maskedValue ~= 0)
		self:setFlag(FLAG_PF, self:_computePF(result))
		return result
	elseif operation == "mul" then
		if width == 8 then
			local product = self:getReg8(0) * maskedValue
			self:setReg16(0, product % 0x10000)
			local overflow = product >= 0x100
			self:setFlag(FLAG_CF, overflow)
			self:setFlag(FLAG_OF, overflow)
		else
			local product = self:getReg16(0) * maskedValue
			self:setReg16(0, product % 0x10000)
			self:setReg16(2, math.floor(product / 0x10000) % 0x10000)
			local overflow = product >= 0x10000
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
		else
			local product = toSigned(16, self:getReg16(0)) * toSigned(16, maskedValue)
			local stored = product % 0x100000000
			self:setReg16(0, stored % 0x10000)
			self:setReg16(2, math.floor(stored / 0x10000) % 0x10000)
			local overflow = product < -0x8000 or product > 0x7FFF
			self:setFlag(FLAG_CF, overflow)
			self:setFlag(FLAG_OF, overflow)
		end
		return nil
	elseif operation == "div" then
		if maskedValue == 0 then
			self:_raiseDivideError()
		end
		if width == 8 then
			local dividend = self:getReg16(0)
			local quotient = math.floor(dividend / maskedValue)
			local remainder = dividend % maskedValue
			if quotient > 0xFF then
				self:_raiseDivideError()
			end
			self:setReg8(0, quotient)
			self:setReg8(4, remainder)
		else
			local dividend = self:getReg16(0) + self:getReg16(2) * 0x10000
			local quotient = math.floor(dividend / maskedValue)
			local remainder = dividend % maskedValue
			if quotient > 0xFFFF then
				self:_raiseDivideError()
			end
			self:setReg16(0, quotient)
			self:setReg16(2, remainder)
		end
		return nil
	elseif operation == "idiv" then
		local divisor = toSigned(width, maskedValue)
		if divisor == 0 then
			self:_raiseDivideError()
		end
		if width == 8 then
			local dividend = toSigned(16, self:getReg16(0))
			local quotient = dividend / divisor
			quotient = quotient >= 0 and math.floor(quotient) or math.ceil(quotient)
			local remainder = dividend - quotient * divisor
			if quotient < -0x80 or quotient > 0x7F then
				self:_raiseDivideError()
			end
			self:setReg8(0, quotient % 0x100)
			self:setReg8(4, remainder % 0x100)
		else
			local dividend = self:getReg16(0) + self:getReg16(2) * 0x10000
			if bit32.band(self:getReg16(2), 0x8000) ~= 0 then
				dividend = dividend - 0x100000000
			end
			local quotient = dividend / divisor
			quotient = quotient >= 0 and math.floor(quotient) or math.ceil(quotient)
			local remainder = dividend - quotient * divisor
			if quotient < -0x8000 or quotient > 0x7FFF then
				self:_raiseDivideError()
			end
			self:setReg16(0, quotient % 0x10000)
			self:setReg16(2, remainder % 0x10000)
		end
		return nil
	end
	error("unsupported F6/F7 group op")
end

function Cpu8086:_stringDelta(width)
	local bytes = width == 8 and 1 or 2
	return self:getFlag(FLAG_DF) and -bytes or bytes
end

function Cpu8086:_applyStringDelta(delta)
	self.reg16.SI = (self.reg16.SI + delta) % 0x10000
	self.reg16.DI = (self.reg16.DI + delta) % 0x10000
end

function Cpu8086:_stringRepeatCount(prefix)
	if prefix == nil then
		return 1, false
	end
	return self:getReg16(1), true
end

function Cpu8086:_storeRepeatCount(active, count)
	if active then
		self:setReg16(1, count % 0x10000)
	end
end

function Cpu8086:_stringSourceSegment()
	if self._segmentOverride ~= nil then
		return self:getSeg(self._segmentOverride)
	end
	return self.seg.DS
end

function Cpu8086:_readFarPointer16(decoded)
	if decoded.mod == 3 then
		error("far pointer operand must be in memory")
	end
	local segment, offset = self:_effectiveAddress(decoded)
	return self:readMem16(segment, offset), self:readMem16(segment, offset + 2)
end

function Cpu8086:_loadFarPointerRegister16(decoded, segmentCode)
	local offset, selector = self:_readFarPointer16(decoded)
	self:setSeg(segmentCode, selector)
	self:setReg16(decoded.reg, offset)
end

function Cpu8086:_executeStringOp(opcode, repeatPrefix)
	local width = (
		opcode == 0xA4
		or opcode == 0xA6
		or opcode == 0xAA
		or opcode == 0xAC
		or opcode == 0xAE
		or opcode == 0x6C
		or opcode == 0x6E
	)
			and 8
		or 16
	local count, repeated = self:_stringRepeatCount(repeatPrefix)
	if repeated and count == 0 then
		return true
	end

	local remaining = count
	local sourceSegment = self:_stringSourceSegment()
	while remaining > 0 do
		local delta = self:_stringDelta(width)
		if opcode == 0xA4 or opcode == 0xA5 then
			local value = width == 8 and self:readMem8(sourceSegment, self.reg16.SI)
				or self:readMem16(sourceSegment, self.reg16.SI)
			if width == 8 then
				self:writeMem8(self.seg.ES, self.reg16.DI, value)
			else
				self:writeMem16(self.seg.ES, self.reg16.DI, value)
			end
			self:_applyStringDelta(delta)
		elseif opcode == 0xA6 or opcode == 0xA7 then
			local left = width == 8 and self:readMem8(sourceSegment, self.reg16.SI)
				or self:readMem16(sourceSegment, self.reg16.SI)
			local right = width == 8 and self:readMem8(self.seg.ES, self.reg16.DI)
				or self:readMem16(self.seg.ES, self.reg16.DI)
			self:_sub(width, left, right)
			self:_applyStringDelta(delta)
		elseif opcode == 0xAA or opcode == 0xAB then
			local value = width == 8 and self:getReg8(0) or self:getReg16(0)
			if width == 8 then
				self:writeMem8(self.seg.ES, self.reg16.DI, value)
			else
				self:writeMem16(self.seg.ES, self.reg16.DI, value)
			end
			self.reg16.DI = (self.reg16.DI + delta) % 0x10000
		elseif opcode == 0xAC or opcode == 0xAD then
			local value = width == 8 and self:readMem8(sourceSegment, self.reg16.SI)
				or self:readMem16(sourceSegment, self.reg16.SI)
			if width == 8 then
				self:setReg8(0, value)
			else
				self:setReg16(0, value)
			end
			self.reg16.SI = (self.reg16.SI + delta) % 0x10000
		elseif opcode == 0xAE or opcode == 0xAF then
			local left = width == 8 and self:getReg8(0) or self:getReg16(0)
			local right = width == 8 and self:readMem8(self.seg.ES, self.reg16.DI)
				or self:readMem16(self.seg.ES, self.reg16.DI)
			self:_sub(width, left, right)
			self.reg16.DI = (self.reg16.DI + delta) % 0x10000
		elseif opcode == 0x6C or opcode == 0x6D then
			local value = width == 8 and self.bus:portRead(self.reg16.DX) or self.bus:portRead16(self.reg16.DX)
			self.stats.portReads = self.stats.portReads + 1
			if width == 8 then
				self:writeMem8(self.seg.ES, self.reg16.DI, value)
			else
				self:writeMem16(self.seg.ES, self.reg16.DI, value)
			end
			self.reg16.DI = (self.reg16.DI + delta) % 0x10000
		elseif opcode == 0x6E or opcode == 0x6F then
			local value = width == 8 and self:readMem8(sourceSegment, self.reg16.SI)
				or self:readMem16(sourceSegment, self.reg16.SI)
			self.stats.portWrites = self.stats.portWrites + 1
			if width == 8 then
				self.bus:portWrite(self.reg16.DX, value)
			else
				self.bus:portWrite16(self.reg16.DX, value)
			end
			self.reg16.SI = (self.reg16.SI + delta) % 0x10000
		end

		remaining = remaining - 1
		if repeatPrefix ~= nil then
			self:_storeRepeatCount(true, remaining)
			if opcode == 0xA6 or opcode == 0xA7 or opcode == 0xAE or opcode == 0xAF then
				if repeatPrefix == 0xF3 and not self:getFlag(FLAG_ZF) then
					break
				elseif repeatPrefix == 0xF2 and self:getFlag(FLAG_ZF) then
					break
				end
			end
		end
		if not repeated then
			break
		end
	end
	return true
end

function Cpu8086:_serviceExternalInterrupt()
	if not self:getFlag(FLAG_IF) then
		return false
	end
	if not self.bus or type(self.bus.getPendingInterruptVector) ~= "function" then
		return false
	end
	local vector = self.bus:getPendingInterruptVector()
	if vector == nil then
		return false
	end
	return self:_invokeInterrupt(vector, true)
end

function Cpu8086:_invokeInterrupt(vector, _hardware)
	vector = (tonumber(vector) or 0) % 0x100
	self.halted = false
	self:push16(self.flags)
	self:push16(self.seg.CS)
	self:push16(self.ip)
	self:setFlag(FLAG_IF, false)
	if self._bios and type(self._bios.handleInterrupt) == "function" then
		local handled = self._bios:handleInterrupt(self, vector)
		if handled then
			local returnIP = self:pop16()
			local returnCS = self:pop16()
			local savedFlags = self:pop16()
			local statusMask = bit32.bor(FLAG_CF, FLAG_ZF, FLAG_SF, FLAG_OF)
			self.ip = returnIP
			self.seg.CS = returnCS
			self.flags =
				bit32.bor(bit32.band(savedFlags, bit32.bnot(statusMask)), bit32.band(self.flags, statusMask), 0x0002)
			self.stats.interrupts = self.stats.interrupts + 1
			return true
		end
	end

	local ivt = vector * 4
	local offset = self:readPhysical16(ivt)
	local segment = self:readPhysical16(ivt + 2)
	self.seg.CS = segment
	self.ip = offset
	self.stats.interrupts = self.stats.interrupts + 1
	return true
end

function Cpu8086:step()
	self.stats.cycles = self.stats.cycles + 1
	self._segmentOverride = nil

	if self:_serviceExternalInterrupt() then
		self.stats.instructions = self.stats.instructions + 1
		return "INT"
	end

	if self.halted then
		return "HLT"
	end

	local startIP = self.ip
	local startCS = self.seg.CS
	local repeatPrefix = nil
	local opcode = self:fetch8()
	while opcode == 0xF2 or opcode == 0xF3 or SEGMENT_PREFIX_TO_CODE[opcode] ~= nil do
		if opcode == 0xF2 or opcode == 0xF3 then
			repeatPrefix = opcode
		else
			self._segmentOverride = SEGMENT_PREFIX_TO_CODE[opcode]
		end
		opcode = self:fetch8()
	end
	self._lastStep.opcode = opcode
	self._lastStep.cs = startCS
	self._lastStep.ip = startIP

	if opcode >= 0xB8 and opcode <= 0xBF then
		self:setReg16(opcode - 0xB8, self:fetch16())
	elseif opcode >= 0xB0 and opcode <= 0xB7 then
		self:setReg8(opcode - 0xB0, self:fetch8())
	elseif opcode == 0x90 then
		self.ip = self.ip % 0x10000
	elseif opcode >= 0x91 and opcode <= 0x97 then
		local reg = opcode - 0x90
		local ax = self:getReg16(0)
		local other = self:getReg16(reg)
		self:setReg16(0, other)
		self:setReg16(reg, ax)
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
	elseif opcode == 0x9C then
		self:push16(self.flags)
	elseif opcode == 0x9D then
		self.flags = bit32.bor(bit32.band(self:pop16(), 0x0FD5), 0x0002)
	elseif opcode == 0x06 then
		self:push16(self.seg.ES)
	elseif opcode == 0x07 then
		self:setSeg(0, self:pop16())
	elseif opcode == 0x0E then
		self:push16(self.seg.CS)
	elseif opcode == 0x16 then
		self:push16(self.seg.SS)
	elseif opcode == 0x17 then
		self:setSeg(2, self:pop16())
	elseif opcode == 0x1E then
		self:push16(self.seg.DS)
	elseif opcode == 0x1F then
		self:setSeg(3, self:pop16())
	elseif opcode >= 0x40 and opcode <= 0x47 then
		local reg = opcode - 0x40
		self:setReg16(reg, self:_inc(16, self:getReg16(reg)))
	elseif opcode >= 0x48 and opcode <= 0x4F then
		local reg = opcode - 0x48
		self:setReg16(reg, self:_dec(16, self:getReg16(reg)))
	elseif opcode >= 0x50 and opcode <= 0x57 then
		self:push16(self:getReg16(opcode - 0x50))
	elseif opcode >= 0x58 and opcode <= 0x5F then
		self:setReg16(opcode - 0x58, self:pop16())
	elseif opcode == 0x68 then
		self:push16(self:fetch16())
	elseif opcode == 0x6A then
		self:push16(signExtend8(self:fetch8()) % 0x10000)
	elseif opcode == 0x8E then
		local decoded = self:_decodeModRM()
		if decoded.reg == 1 then
			error("unsupported MOV CS, r/m16")
		end
		self:setSeg(decoded.reg, self:_readRM16(decoded))
	elseif opcode == 0x8C then
		local decoded = self:_decodeModRM()
		self:_writeRM16(decoded, self:getSeg(decoded.reg))
	elseif opcode == 0x8B then
		local decoded = self:_decodeModRM()
		self:setReg16(decoded.reg, self:_readRM16(decoded))
	elseif opcode == 0x89 then
		local decoded = self:_decodeModRM()
		self:_writeRM16(decoded, self:getReg16(decoded.reg))
	elseif opcode == 0x8A then
		local decoded = self:_decodeModRM()
		self:setReg8(decoded.reg, self:_readRM8(decoded))
	elseif opcode == 0x8D then
		local decoded = self:_decodeModRM()
		local _segment, offset = self:_effectiveAddress(decoded)
		self:setReg16(decoded.reg, offset % 0x10000)
	elseif opcode == 0xC4 then
		self:_loadFarPointerRegister16(self:_decodeModRM(), 0)
	elseif opcode == 0xC5 then
		self:_loadFarPointerRegister16(self:_decodeModRM(), 3)
	elseif opcode == 0x88 then
		local decoded = self:_decodeModRM()
		self:_writeRM8(decoded, self:getReg8(decoded.reg))
	elseif opcode == 0xC6 then
		local decoded = self:_decodeModRM()
		local imm = self:fetch8()
		self:_writeRM8(decoded, imm)
	elseif opcode == 0xC7 then
		local decoded = self:_decodeModRM()
		local imm = self:fetch16()
		self:_writeRM16(decoded, imm)
	elseif opcode == 0x00 then
		local decoded = self:_decodeModRM()
		self:_writeRM8(decoded, self:_add(8, self:_readRM8(decoded), self:getReg8(decoded.reg)))
	elseif opcode == 0x01 then
		local decoded = self:_decodeModRM()
		self:_writeRM16(decoded, self:_add(16, self:_readRM16(decoded), self:getReg16(decoded.reg)))
	elseif opcode == 0x02 then
		local decoded = self:_decodeModRM()
		self:setReg8(decoded.reg, self:_add(8, self:getReg8(decoded.reg), self:_readRM8(decoded)))
	elseif opcode == 0x03 then
		local decoded = self:_decodeModRM()
		self:setReg16(decoded.reg, self:_add(16, self:getReg16(decoded.reg), self:_readRM16(decoded)))
	elseif opcode == 0x04 then
		self:setReg8(0, self:_add(8, self:getReg8(0), self:fetch8()))
	elseif opcode == 0x05 then
		self:setReg16(0, self:_add(16, self:getReg16(0), self:fetch16()))
	elseif opcode == 0x08 then
		local decoded = self:_decodeModRM()
		self:_writeRM8(decoded, self:_logicBinary(8, self:_readRM8(decoded), self:getReg8(decoded.reg), "or"))
	elseif opcode == 0x09 then
		local decoded = self:_decodeModRM()
		self:_writeRM16(decoded, self:_logicBinary(16, self:_readRM16(decoded), self:getReg16(decoded.reg), "or"))
	elseif opcode == 0x0A then
		local decoded = self:_decodeModRM()
		self:setReg8(decoded.reg, self:_logicBinary(8, self:getReg8(decoded.reg), self:_readRM8(decoded), "or"))
	elseif opcode == 0x0B then
		local decoded = self:_decodeModRM()
		self:setReg16(decoded.reg, self:_logicBinary(16, self:getReg16(decoded.reg), self:_readRM16(decoded), "or"))
	elseif opcode == 0x0C then
		self:setReg8(0, self:_logicBinary(8, self:getReg8(0), self:fetch8(), "or"))
	elseif opcode == 0x0D then
		self:setReg16(0, self:_logicBinary(16, self:getReg16(0), self:fetch16(), "or"))
	elseif opcode == 0x20 then
		local decoded = self:_decodeModRM()
		self:_writeRM8(decoded, self:_logicBinary(8, self:_readRM8(decoded), self:getReg8(decoded.reg), "and"))
	elseif opcode == 0x21 then
		local decoded = self:_decodeModRM()
		self:_writeRM16(decoded, self:_logicBinary(16, self:_readRM16(decoded), self:getReg16(decoded.reg), "and"))
	elseif opcode == 0x22 then
		local decoded = self:_decodeModRM()
		self:setReg8(decoded.reg, self:_logicBinary(8, self:getReg8(decoded.reg), self:_readRM8(decoded), "and"))
	elseif opcode == 0x23 then
		local decoded = self:_decodeModRM()
		self:setReg16(decoded.reg, self:_logicBinary(16, self:getReg16(decoded.reg), self:_readRM16(decoded), "and"))
	elseif opcode == 0x24 then
		self:setReg8(0, self:_logicBinary(8, self:getReg8(0), self:fetch8(), "and"))
	elseif opcode == 0x25 then
		self:setReg16(0, self:_logicBinary(16, self:getReg16(0), self:fetch16(), "and"))
	elseif opcode == 0x28 then
		local decoded = self:_decodeModRM()
		self:_writeRM8(decoded, self:_sub(8, self:_readRM8(decoded), self:getReg8(decoded.reg)))
	elseif opcode == 0x29 then
		local decoded = self:_decodeModRM()
		self:_writeRM16(decoded, self:_sub(16, self:_readRM16(decoded), self:getReg16(decoded.reg)))
	elseif opcode == 0x2A then
		local decoded = self:_decodeModRM()
		self:setReg8(decoded.reg, self:_sub(8, self:getReg8(decoded.reg), self:_readRM8(decoded)))
	elseif opcode == 0x2B then
		local decoded = self:_decodeModRM()
		self:setReg16(decoded.reg, self:_sub(16, self:getReg16(decoded.reg), self:_readRM16(decoded)))
	elseif opcode == 0x2C then
		self:setReg8(0, self:_sub(8, self:getReg8(0), self:fetch8()))
	elseif opcode == 0x2D then
		self:setReg16(0, self:_sub(16, self:getReg16(0), self:fetch16()))
	elseif opcode == 0x30 then
		local decoded = self:_decodeModRM()
		self:_writeRM8(decoded, self:_logicBinary(8, self:_readRM8(decoded), self:getReg8(decoded.reg), "xor"))
	elseif opcode == 0x31 then
		local decoded = self:_decodeModRM()
		self:_writeRM16(decoded, self:_logicBinary(16, self:_readRM16(decoded), self:getReg16(decoded.reg), "xor"))
	elseif opcode == 0x33 then
		local decoded = self:_decodeModRM()
		local value = bit32.bxor(self:getReg16(decoded.reg), self:_readRM16(decoded))
		self:setReg16(decoded.reg, value)
		self:_updateLogicFlags(16, value)
	elseif opcode == 0x32 then
		local decoded = self:_decodeModRM()
		local value = bit32.bxor(self:getReg8(decoded.reg), self:_readRM8(decoded))
		self:setReg8(decoded.reg, value)
		self:_updateLogicFlags(8, value)
	elseif opcode == 0x34 then
		self:setReg8(0, self:_logicBinary(8, self:getReg8(0), self:fetch8(), "xor"))
	elseif opcode == 0x35 then
		self:setReg16(0, self:_logicBinary(16, self:getReg16(0), self:fetch16(), "xor"))
	elseif opcode == 0x84 then
		local decoded = self:_decodeModRM()
		self:_test(8, self:_readRM8(decoded), self:getReg8(decoded.reg))
	elseif opcode == 0x85 then
		local decoded = self:_decodeModRM()
		self:_test(16, self:_readRM16(decoded), self:getReg16(decoded.reg))
	elseif opcode == 0x80 or opcode == 0x81 then
		local decoded = self:_decodeModRM()
		local width = opcode == 0x80 and 8 or 16
		local imm = width == 8 and self:fetch8() or self:fetch16()
		local left = width == 8 and self:_readRM8(decoded) or self:_readRM16(decoded)
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
			error("unsupported group 80/81 op")
		end
		if result ~= nil then
			if width == 8 then
				self:_writeRM8(decoded, result)
			else
				self:_writeRM16(decoded, result)
			end
		end
	elseif opcode >= 0xD0 and opcode <= 0xD3 then
		local decoded = self:_decodeModRM()
		local width = (opcode == 0xD0 or opcode == 0xD2) and 8 or 16
		local count = (opcode == 0xD0 or opcode == 0xD1) and 1 or self:getReg8(1)
		local operation = (
			{ [0] = "rol", [1] = "ror", [2] = "rcl", [3] = "rcr", [4] = "shl", [5] = "shr", [7] = "sar" }
		)[decoded.reg]
		if not operation then
			error(string.format("unsupported shift/rotate group /%d", decoded.reg))
		end
		local value = width == 8 and self:_readRM8(decoded) or self:_readRM16(decoded)
		local result = self:_shiftRotate(width, operation, value, count)
		if width == 8 then
			self:_writeRM8(decoded, result)
		else
			self:_writeRM16(decoded, result)
		end
	elseif opcode == 0xFE then
		local decoded = self:_decodeModRM()
		local value = self:_readRM8(decoded)
		if decoded.reg == 0 then
			self:_writeRM8(decoded, self:_inc(8, value))
		elseif decoded.reg == 1 then
			self:_writeRM8(decoded, self:_dec(8, value))
		else
			error(string.format("unsupported FE group /%d at %04X:%04X", decoded.reg, self.seg.CS, startIP))
		end
	elseif opcode == 0xF6 or opcode == 0xF7 then
		local decoded = self:_decodeModRM()
		local width = opcode == 0xF6 and 8 or 16
		local value = width == 8 and self:_readRM8(decoded) or self:_readRM16(decoded)
		if decoded.reg == 0 then
			local imm = width == 8 and self:fetch8() or self:fetch16()
			local result = bit32.band(value, imm)
			self:setFlag(FLAG_CF, false)
			self:setFlag(FLAG_OF, false)
			self:setFlag(FLAG_AF, false)
			self:setFlag(FLAG_ZF, result == 0)
			self:setFlag(FLAG_SF, bit32.band(result, signBit(width)) ~= 0)
			self:setFlag(FLAG_PF, self:_computePF(result))
		elseif decoded.reg == 2 then
			local result = self:_mulDivGroup(width, "not", value)
			if width == 8 then
				self:_writeRM8(decoded, result)
			else
				self:_writeRM16(decoded, result)
			end
		elseif decoded.reg == 3 then
			local result = self:_mulDivGroup(width, "neg", value)
			if width == 8 then
				self:_writeRM8(decoded, result)
			else
				self:_writeRM16(decoded, result)
			end
		elseif decoded.reg == 4 then
			self:_mulDivGroup(width, "mul", value)
		elseif decoded.reg == 5 then
			self:_mulDivGroup(width, "imul", value)
		elseif decoded.reg == 6 then
			self:_mulDivGroup(width, "div", value)
		elseif decoded.reg == 7 then
			self:_mulDivGroup(width, "idiv", value)
		else
			error(string.format("unsupported F6/F7 group /%d at %04X:%04X", decoded.reg, self.seg.CS, startIP))
		end
	elseif opcode == 0x38 then
		local decoded = self:_decodeModRM()
		self:_sub(8, self:_readRM8(decoded), self:getReg8(decoded.reg))
	elseif opcode == 0x39 then
		local decoded = self:_decodeModRM()
		self:_sub(16, self:_readRM16(decoded), self:getReg16(decoded.reg))
	elseif opcode == 0x3A then
		local decoded = self:_decodeModRM()
		self:_sub(8, self:getReg8(decoded.reg), self:_readRM8(decoded))
	elseif opcode == 0x3B then
		local decoded = self:_decodeModRM()
		self:_sub(16, self:getReg16(decoded.reg), self:_readRM16(decoded))
	elseif opcode == 0x3C then
		self:_sub(8, self:getReg8(0), self:fetch8())
	elseif opcode == 0x3D then
		self:_sub(16, self:getReg16(0), self:fetch16())
	elseif opcode == 0xE8 then
		local rel = signExtend16(self:fetch16())
		self:push16(self.ip)
		self.ip = (self.ip + rel) % 0x10000
	elseif opcode == 0xE9 then
		local rel = signExtend16(self:fetch16())
		self.ip = (self.ip + rel) % 0x10000
	elseif opcode == 0xEA then
		local offset = self:fetch16()
		local segment = self:fetch16()
		self.seg.CS = segment
		self.ip = offset
	elseif opcode == 0xEB then
		local rel = signExtend8(self:fetch8())
		self.ip = (self.ip + rel) % 0x10000
	elseif opcode >= 0x70 and opcode <= 0x7F then
		local rel = signExtend8(self:fetch8())
		if self:_conditionTrue(opcode) then
			self.ip = (self.ip + rel) % 0x10000
		end
	elseif opcode == 0xE0 then
		local rel = signExtend8(self:fetch8())
		self:setReg16(1, (self:getReg16(1) - 1) % 0x10000)
		if self:getReg16(1) ~= 0 and not self:getFlag(FLAG_ZF) then
			self.ip = (self.ip + rel) % 0x10000
		end
	elseif opcode == 0xE1 then
		local rel = signExtend8(self:fetch8())
		self:setReg16(1, (self:getReg16(1) - 1) % 0x10000)
		if self:getReg16(1) ~= 0 and self:getFlag(FLAG_ZF) then
			self.ip = (self.ip + rel) % 0x10000
		end
	elseif opcode == 0xE2 then
		local rel = signExtend8(self:fetch8())
		self:setReg16(1, (self:getReg16(1) - 1) % 0x10000)
		if self:getReg16(1) ~= 0 then
			self.ip = (self.ip + rel) % 0x10000
		end
	elseif opcode == 0xE3 then
		local rel = signExtend8(self:fetch8())
		if self:getReg16(1) == 0 then
			self.ip = (self.ip + rel) % 0x10000
		end
	elseif opcode == 0xA0 then
		local offset = self:fetch16()
		self:setReg8(0, self:_readMoffsByWidth(offset, 8))
	elseif opcode == 0xA1 then
		local offset = self:fetch16()
		self:setReg16(0, self:_readMoffsByWidth(offset, 16))
	elseif opcode == 0xA2 then
		local offset = self:fetch16()
		self:_writeMoffsByWidth(offset, 8, self:getReg8(0))
	elseif opcode == 0xA3 then
		local offset = self:fetch16()
		self:_writeMoffsByWidth(offset, 16, self:getReg16(0))
	elseif opcode == 0xA8 then
		self:_test(8, self:getReg8(0), self:fetch8())
	elseif opcode == 0xA9 then
		self:_test(16, self:getReg16(0), self:fetch16())
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
	then
		self:_executeStringOp(opcode, repeatPrefix)
	elseif opcode == 0xFF then
		local decoded = self:_decodeModRM()
		if decoded.reg == 0 then
			self:_writeRM16(decoded, self:_inc(16, self:_readRM16(decoded)))
		elseif decoded.reg == 1 then
			self:_writeRM16(decoded, self:_dec(16, self:_readRM16(decoded)))
		elseif decoded.reg == 2 then
			local target = self:_readRM16(decoded)
			self:push16(self.ip)
			self.ip = target
		elseif decoded.reg == 4 then
			self.ip = self:_readRM16(decoded)
		elseif decoded.reg == 6 then
			self:push16(self:_readRM16(decoded))
		else
			error(string.format("unsupported FF group /%d at %04X:%04X", decoded.reg, self.seg.CS, startIP))
		end
	elseif opcode == 0xC3 then
		self.ip = self:pop16()
	elseif opcode == 0xC2 then
		local adjust = self:fetch16()
		self.ip = self:pop16()
		self.reg16.SP = (self.reg16.SP + adjust) % 0x10000
	elseif opcode == 0xCB then
		self.ip = self:pop16()
		self.seg.CS = self:pop16()
	elseif opcode == 0xC9 then
		self.reg16.SP = self.reg16.BP
		self.reg16.BP = self:pop16()
	elseif opcode == 0xCF then
		self.ip = self:pop16()
		self.seg.CS = self:pop16()
		self.flags = bit32.bor(bit32.band(self:pop16(), FLAGS16_WRITE_MASK), 0x0002)
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
		self:setReg8(7, newFlags)
	elseif opcode == 0xCC then
		self:_invokeInterrupt(3, false)
	elseif opcode == 0xCE then
		if self:getFlag(FLAG_OF) then
			self:_invokeInterrupt(4, false)
		end
	elseif opcode == 0xCD then
		local vector = self:fetch8()
		self:_invokeInterrupt(vector, false)
	elseif opcode == 0xE4 then
		local port = self:fetch8()
		self.stats.portReads = self.stats.portReads + 1
		self:setReg8(0, self.bus:portRead(port))
	elseif opcode == 0xE5 then
		local port = self:fetch8()
		self.stats.portReads = self.stats.portReads + 1
		self:setReg16(0, self.bus:portRead16(port))
	elseif opcode == 0xEC then
		local port = self.reg16.DX
		self.stats.portReads = self.stats.portReads + 1
		self:setReg8(0, self.bus:portRead(port))
	elseif opcode == 0xED then
		local port = self.reg16.DX
		self.stats.portReads = self.stats.portReads + 1
		self:setReg16(0, self.bus:portRead16(port))
	elseif opcode == 0xE6 then
		local port = self:fetch8()
		self.stats.portWrites = self.stats.portWrites + 1
		self.bus:portWrite(port, self:getReg8(0))
	elseif opcode == 0xE7 then
		local port = self:fetch8()
		self.stats.portWrites = self.stats.portWrites + 1
		self.bus:portWrite16(port, self:getReg16(0))
	elseif opcode == 0xEE then
		local port = self.reg16.DX
		self.stats.portWrites = self.stats.portWrites + 1
		self.bus:portWrite(port, self:getReg8(0))
	elseif opcode == 0xEF then
		local port = self.reg16.DX
		self.stats.portWrites = self.stats.portWrites + 1
		self.bus:portWrite16(port, self:getReg16(0))
	else
		self._lastError = string.format("unsupported opcode 0x%02X at %04X:%04X", opcode, self.seg.CS, startIP)
		self.halted = true
		error(self._lastError)
	end

	self.stats.instructions = self.stats.instructions + 1
	self._segmentOverride = nil
	return opcode
end

return Cpu8086
