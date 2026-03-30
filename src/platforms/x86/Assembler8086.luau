local Assembler8086 = {}

local REG16 = {
	AX = 0,
	CX = 1,
	DX = 2,
	BX = 3,
	SP = 4,
	BP = 5,
	SI = 6,
	DI = 7,
}

local REG32 = {
	EAX = 0,
	ECX = 1,
	EDX = 2,
	EBX = 3,
	ESP = 4,
	EBP = 5,
	ESI = 6,
	EDI = 7,
}

local REG8 = {
	AL = 0,
	CL = 1,
	DL = 2,
	BL = 3,
	AH = 4,
	CH = 5,
	DH = 6,
	BH = 7,
}

local SEGREG = {
	ES = 0,
	CS = 1,
	SS = 2,
	DS = 3,
}

local MEM_BASE = {
	["BX+SI"] = 0,
	["BX+DI"] = 1,
	["BP+SI"] = 2,
	["BP+DI"] = 3,
	SI = 4,
	DI = 5,
	BP = 6,
	BX = 7,
}

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function upper(text)
	return string.upper(text)
end

local function stripComment(line)
	local inString = false
	local quote = nil
	for i = 1, #line do
		local ch = line:sub(i, i)
		if inString then
			if ch == quote then
				inString = false
				quote = nil
			elseif ch == "\\" then
				i = i + 1
			end
		elseif ch == '"' or ch == "'" then
			inString = true
			quote = ch
		elseif ch == ";" then
			return trim(line:sub(1, i - 1))
		end
	end
	return trim(line)
end

local function splitCsv(text)
	local out = {}
	local cur = {}
	local depth = 0
	local quote = nil
	local i = 1
	while i <= #text do
		local ch = text:sub(i, i)
		if quote then
			table.insert(cur, ch)
			if ch == quote then
				quote = nil
			elseif ch == "\\" and i < #text then
				i = i + 1
				table.insert(cur, text:sub(i, i))
			end
		elseif ch == '"' or ch == "'" then
			quote = ch
			table.insert(cur, ch)
		elseif ch == "[" then
			depth = depth + 1
			table.insert(cur, ch)
		elseif ch == "]" then
			depth = math.max(0, depth - 1)
			table.insert(cur, ch)
		elseif ch == "," and depth == 0 then
			table.insert(out, trim(table.concat(cur)))
			cur = {}
		else
			table.insert(cur, ch)
		end
		i = i + 1
	end
	if #cur > 0 then
		table.insert(out, trim(table.concat(cur)))
	end
	return out
end

local function parseNumber(text)
	if text:match("^0x[%da-fA-F]+$") then
		return tonumber(text)
	end
	if text:match("^%d+$") then
		return tonumber(text)
	end
	if text:match("^'.'$") then
		return string.byte(text:sub(2, 2))
	end
	return nil
end

local function evalExpr(expr, symbols, currentAddress, origin)
	local text = trim(expr or "")
	if text == "" then
		return 0
	end

	local total = 0
	local sign = 1
	local i = 1
	while i <= #text do
		while i <= #text and text:sub(i, i):match("%s") do
			i = i + 1
		end
		if i > #text then
			break
		end
		local ch = text:sub(i, i)
		if ch == "+" then
			sign = 1
			i = i + 1
		elseif ch == "-" then
			sign = -1
			i = i + 1
		else
			local j = i
			while j <= #text and not text:sub(j, j):match("[%+%-]") do
				j = j + 1
			end
			local term = trim(text:sub(i, j - 1))
			local value
			if term == "$" then
				value = currentAddress
			elseif term == "$$" then
				value = origin
			else
				value = parseNumber(term)
				if value == nil then
					value = symbols and symbols[upper(term)] or nil
				end
			end
			assert(value ~= nil, "Unknown symbol in expression: " .. tostring(term))
			total = total + sign * value
			sign = 1
			i = j
		end
	end

	return total
end

local function parseOperand(raw)
	local text = trim(raw or "")
	local width = nil
	local upperText = upper(text)
	if upperText:sub(1, 5) == "BYTE " then
		width = 8
		text = trim(text:sub(6))
		upperText = upper(text)
	elseif upperText:sub(1, 5) == "WORD " then
		width = 16
		text = trim(text:sub(6))
		upperText = upper(text)
	elseif upperText:sub(1, 6) == "DWORD " then
		width = 32
		text = trim(text:sub(7))
		upperText = upper(text)
	end

	if REG32[upperText] ~= nil then
		return { kind = "reg32", code = REG32[upperText], text = upperText }
	end
	if REG16[upperText] ~= nil then
		return { kind = "reg16", code = REG16[upperText], text = upperText }
	end
	if REG8[upperText] ~= nil then
		return { kind = "reg8", code = REG8[upperText], text = upperText }
	end
	if SEGREG[upperText] ~= nil then
		return { kind = "seg", code = SEGREG[upperText], text = upperText }
	end
	if text:sub(1, 1) == "[" and text:sub(-1) == "]" then
		local inner = trim(text:sub(2, -2))
		local base = MEM_BASE[upper(inner)]
		if base ~= nil then
			return { kind = "mem", base = base, mode = "base", width = width }
		end
		return { kind = "mem", expr = inner, mode = "direct", width = width }
	end
	return { kind = "imm", expr = text, width = width }
end

local function encodeWord(bytes, value)
	local v = (tonumber(value) or 0) % 0x10000
	bytes[#bytes + 1] = v % 256
	bytes[#bytes + 1] = math.floor(v / 256) % 256
end

local function encodeDword(bytes, value)
	local v = (tonumber(value) or 0) % 0x100000000
	bytes[#bytes + 1] = v % 256
	bytes[#bytes + 1] = math.floor(v / 256) % 256
	bytes[#bytes + 1] = math.floor(v / 0x10000) % 256
	bytes[#bytes + 1] = math.floor(v / 0x1000000) % 256
end

local function operandWidth(operand, default32)
	if not operand then
		return nil
	end
	if operand.kind == "reg8" then
		return 8
	end
	if operand.kind == "reg16" then
		return 16
	end
	if operand.kind == "reg32" then
		return 32
	end
	if operand.kind == "mem" and operand.width then
		return operand.width
	end
	if operand.kind == "mem" then
		return default32 and 32 or 16
	end
	return nil
end

local function needsOperandPrefix(width, default32)
	if width == nil or width == 8 then
		return false
	end
	if default32 then
		return width == 16
	end
	return width == 32
end

local function controlTransferWidth(operand, default32)
	if not operand then
		return default32 and 32 or 16
	end
	return operandWidth(operand, default32) or operand.width or (default32 and 32 or 16)
end

local function needsAddressPrefix(operand, default32)
	return default32 and operand and operand.kind == "mem"
end

local function emitPrefixes(bytes, addressOperand, width, default32)
	if needsAddressPrefix(addressOperand, default32) then
		bytes[#bytes + 1] = 0x67
	end
	if needsOperandPrefix(width, default32) then
		bytes[#bytes + 1] = 0x66
	end
end

local function modrm(mod, reg, rm)
	return bit32.bor(bit32.lshift(mod, 6), bit32.lshift(reg, 3), rm)
end

local function encodeMem(bytes, operand, regField, symbols, currentAddress, origin)
	if operand.mode == "direct" then
		bytes[#bytes + 1] = modrm(0, regField, 6)
		encodeWord(bytes, evalExpr(operand.expr, symbols, currentAddress, origin))
		return
	end

	local rm = operand.base
	if rm == 6 then
		bytes[#bytes + 1] = modrm(1, regField, rm)
		bytes[#bytes + 1] = 0
		return
	end
	bytes[#bytes + 1] = modrm(0, regField, rm)
end

local function memSize(operand)
	if operand.mode == "direct" then
		return 3
	end
	if operand.base == 6 then
		return 2
	end
	return 1
end

local function isCondJump(name)
	return name == "JE" or name == "JZ" or name == "JNE" or name == "JNZ" or name == "JC" or name == "JNC"
end

local function estimateInstruction(name, operands, default32)
	if
		name == "NOP"
		or name == "RET"
		or name == "RETF"
		or name == "IRET"
		or name == "CLI"
		or name == "STI"
		or name == "HLT"
	then
		return 1
	end
	if name == "INT" then
		return 2
	end
	if name == "IN" then
		local dst = operands[1]
		local src = operands[2]
		assert(dst and src, "Assembler8086: IN requires two operands")
		local dstWidth = operandWidth(dst, default32)
		local dstIsAccumulator = (dst.kind == "reg8" and dst.code == 0)
			or ((dstWidth == 16 or dstWidth == 32) and dst.code == 0)
		local srcIsPort = src.kind == "imm" or (src.kind == "reg16" and src.code == REG16.DX)
		assert(dstIsAccumulator and srcIsPort, "Assembler8086: supported IN forms are IN AL|AX|EAX, imm8|DX")
		return src.kind == "imm" and 2 or 1
	end
	if name == "OUT" then
		local dst = operands[1]
		local src = operands[2]
		assert(dst and src, "Assembler8086: OUT requires two operands")
		local dstIsPort = dst.kind == "imm" or (dst.kind == "reg16" and dst.code == REG16.DX)
		local srcWidth = operandWidth(src, default32)
		local srcIsAccumulator = (src.kind == "reg8" and src.code == 0)
			or ((srcWidth == 16 or srcWidth == 32) and src.code == 0)
		assert(dstIsPort and srcIsAccumulator, "Assembler8086: supported OUT forms are OUT imm8|DX, AL|AX|EAX")
		return dst.kind == "imm" and 2 or 1
	end
	if name == "LGDT" or name == "LIDT" then
		local op = operands[1]
		assert(op and op.kind == "mem", "Assembler8086: " .. name .. " requires a memory operand")
		return (needsAddressPrefix(op, default32) and 1 or 0) + 2 + memSize(op)
	end
	if name == "LMSW" or name == "SMSW" then
		local op = operands[1]
		assert(op and (op.kind == "reg16" or op.kind == "mem"), "Assembler8086: " .. name .. " requires r/m16")
		return (needsAddressPrefix(op, default32) and 1 or 0) + 2 + (op.kind == "mem" and memSize(op) or 1)
	end
	if name == "JMP" or name == "CALL" then
		local dst = operands[1]
		local width = controlTransferWidth(dst, default32)
		local prefix = needsOperandPrefix(width, default32) and 1 or 0
		local addressPrefix = needsAddressPrefix(dst, default32) and 1 or 0
		if dst and ((dst.kind == "reg16" or dst.kind == "reg32") or dst.kind == "mem") then
			return addressPrefix + prefix + 2 + (dst.kind == "mem" and (memSize(dst) - 1) or 0)
		end
		return prefix + 1 + (width == 32 and 4 or 2)
	end
	if isCondJump(name) then
		return default32 and 7 or 5
	end
	if name == "PUSH" or name == "POP" then
		local op = operands[1]
		local width = operandWidth(op, default32)
		local prefix = needsOperandPrefix(width, default32) and 1 or 0
		if op and op.kind == "imm" then
			return prefix + (default32 and 5 or 3)
		end
		return prefix + 1
	end
	if name == "INC" or name == "DEC" then
		local width = operandWidth(operands[1], default32)
		return (needsOperandPrefix(width, default32) and 1 or 0) + 1
	end
	if name == "DB" then
		local size = 0
		for _, operand in ipairs(operands) do
			if operand:match('^".*"$') then
				size = size + (#operand - 2)
			else
				size = size + 1
			end
		end
		return size
	end
	if name == "DW" then
		return #operands * 2
	end
	if name == "DD" then
		return #operands * 4
	end
	if name == "PADTO" then
		return 0
	end
	if name == "MOV" then
		local dst = operands[1]
		local src = operands[2]
		if not dst or not src then
			return 0
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and src.kind == "imm" then
			local width = operandWidth(dst, default32)
			return (needsOperandPrefix(width, default32) and 1 or 0) + 1 + (width == 32 and 4 or 2)
		end
		if dst.kind == "reg8" and src.kind == "imm" then
			return 2
		end
		if dst.kind == "seg" and src.kind == "reg16" then
			assert(dst.code ~= 1, "Assembler8086: MOV CS, r/m16 is not supported")
			return (default32 and 1 or 0) + 2
		end
		if dst.kind == "reg16" and src.kind == "seg" then
			return (default32 and 1 or 0) + 2
		end
		if
			(dst.kind == "reg16" or dst.kind == "reg32")
			and ((src.kind == "reg16" or src.kind == "reg32") or src.kind == "mem")
		then
			local width = operandWidth(dst, default32)
			return (needsAddressPrefix(src, default32) and 1 or 0)
				+ (needsOperandPrefix(width, default32) and 1 or 0)
				+ 1
				+ (src.kind == "mem" and memSize(src) or 1)
		end
		if dst.kind == "reg8" and (src.kind == "reg8" or src.kind == "mem") then
			return (needsAddressPrefix(src, default32) and 1 or 0) + 1 + (src.kind == "mem" and memSize(src) or 1)
		end
		if dst.kind == "mem" and (src.kind == "reg16" or src.kind == "reg32" or src.kind == "reg8") then
			local width = operandWidth(src, default32)
			return (needsAddressPrefix(dst, default32) and 1 or 0)
				+ (needsOperandPrefix(width, default32) and 1 or 0)
				+ 1
				+ memSize(dst)
		end
		if dst.kind == "mem" and src.kind == "imm" then
			local width = operandWidth(dst, default32)
			local immSize = width == 32 and 4 or width == 16 and 2 or 1
			return (needsAddressPrefix(dst, default32) and 1 or 0)
				+ (needsOperandPrefix(width, default32) and 1 or 0)
				+ 1
				+ memSize(dst)
				+ immSize
		end
	end
	if name == "ADD" or name == "SUB" then
		local dst = operands[1]
		local src = operands[2]
		if not dst or not src then
			return 0
		end
		assert(src.kind == "imm", "Assembler8086: only immediate ADD/SUB forms are supported")
		if dst.kind == "reg16" or dst.kind == "reg32" then
			local width = operandWidth(dst, default32)
			return (needsOperandPrefix(width, default32) and 1 or 0) + 2 + (width == 32 and 4 or 2)
		end
		if dst.kind == "reg8" then
			return 3
		end
		if dst.kind == "mem" then
			local width = operandWidth(dst, default32)
			local immSize = width == 32 and 4 or width == 16 and 2 or 1
			return (needsAddressPrefix(dst, default32) and 1 or 0)
				+ (needsOperandPrefix(width, default32) and 1 or 0)
				+ 1
				+ memSize(dst)
				+ immSize
		end
	end
	if name == "CMP" then
		local dst = operands[1]
		local src = operands[2]
		if not dst or not src then
			return 0
		end
		if src.kind == "imm" then
			if dst.kind == "reg16" or dst.kind == "reg32" then
				local width = operandWidth(dst, default32)
				return (needsOperandPrefix(width, default32) and 1 or 0) + 2 + (width == 32 and 4 or 2)
			end
			if dst.kind == "reg8" then
				return 3
			end
			if dst.kind == "mem" then
				local width = operandWidth(dst, default32)
				local immSize = width == 32 and 4 or width == 16 and 2 or 1
				return (needsAddressPrefix(dst, default32) and 1 or 0)
					+ (needsOperandPrefix(width, default32) and 1 or 0)
					+ 1
					+ memSize(dst)
					+ immSize
			end
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(dst, default32)
			return (needsOperandPrefix(width, default32) and 1 or 0) + 2
		end
		if dst.kind == "reg8" and src.kind == "reg8" then
			return 2
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and src.kind == "mem" then
			local width = operandWidth(dst, default32)
			return (needsAddressPrefix(src, default32) and 1 or 0)
				+ (needsOperandPrefix(width, default32) and 1 or 0)
				+ 1
				+ memSize(src)
		end
		if dst.kind == "reg8" and src.kind == "mem" then
			return (needsAddressPrefix(src, default32) and 1 or 0) + 1 + memSize(src)
		end
		if dst.kind == "mem" and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(src, default32)
			return (needsAddressPrefix(dst, default32) and 1 or 0)
				+ (needsOperandPrefix(width, default32) and 1 or 0)
				+ 1
				+ memSize(dst)
		end
		if dst.kind == "mem" and src.kind == "reg8" then
			return (needsAddressPrefix(dst, default32) and 1 or 0) + 1 + memSize(dst)
		end
	end
	if name == "XOR" then
		local dst = operands[1]
		local src = operands[2]
		if not dst or not src then
			return 0
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(dst, default32)
			return (needsOperandPrefix(width, default32) and 1 or 0) + 2
		end
		if dst.kind == "reg8" and src.kind == "reg8" then
			return 2
		end
		assert(false, "Assembler8086: only register XOR forms are supported")
	end
	error("Assembler8086: cannot estimate instruction " .. tostring(name))
end

local function parseLine(line)
	local text = stripComment(line)
	if text == "" then
		return nil
	end

	local labels = {}
	while true do
		local label, rest = text:match("^([%a_][%w_]*):%s*(.*)$")
		if not label then
			break
		end
		table.insert(labels, upper(label))
		text = rest
	end

	if text == "" then
		return { labels = labels }
	end

	local mnemonic, rest = text:match("^(%S+)%s*(.*)$")
	local name = upper(mnemonic)
	local operandsText = rest ~= "" and splitCsv(rest) or {}
	local operands = {}
	if name == "DB" or name == "DW" or name == "DD" or name == "PADTO" or name == "ORG" then
		operands = operandsText
	else
		for _, operand in ipairs(operandsText) do
			table.insert(operands, parseOperand(operand))
		end
	end

	return {
		labels = labels,
		name = name,
		operands = operands,
		rawOperands = operandsText,
	}
end

local function appendTextBytes(bytes, operand, symbols, currentAddress, origin)
	if operand:match('^".*"$') then
		local text = operand:sub(2, -2)
		text = text:gsub("\\n", "\n"):gsub("\\r", "\r"):gsub("\\t", "\t")
		for i = 1, #text do
			bytes[#bytes + 1] = string.byte(text, i)
		end
	else
		bytes[#bytes + 1] = evalExpr(operand, symbols, currentAddress, origin) % 256
	end
end

local function encodeGroupImm(bytes, opcode8, opcode16, subcode, dst, src, symbols, currentAddress, origin, default32)
	local value = evalExpr(src.expr, symbols, currentAddress, origin)
	local width = operandWidth(dst, default32) or 8
	emitPrefixes(bytes, dst.kind == "mem" and dst or nil, width, default32)
	if width == 16 or width == 32 then
		bytes[#bytes + 1] = opcode16
		if dst.kind == "reg16" or dst.kind == "reg32" then
			bytes[#bytes + 1] = modrm(3, subcode, dst.code)
		else
			encodeMem(bytes, dst, subcode, symbols, currentAddress, origin)
		end
		if width == 32 then
			encodeDword(bytes, value)
		else
			encodeWord(bytes, value)
		end
	else
		bytes[#bytes + 1] = opcode8
		if dst.kind == "reg8" then
			bytes[#bytes + 1] = modrm(3, subcode, dst.code)
		else
			encodeMem(bytes, dst, subcode, symbols, currentAddress, origin)
		end
		bytes[#bytes + 1] = value % 256
	end
end

local function encodeInstruction(inst, bytes, symbols, currentAddress, origin, default32)
	local name = inst.name
	local operands = inst.operands
	if name == "ORG" then
		return "ORG"
	end
	if name == "DB" then
		for _, operand in ipairs(inst.rawOperands) do
			appendTextBytes(bytes, operand, symbols, currentAddress, origin)
		end
		return
	end
	if name == "DW" then
		for _, operand in ipairs(inst.rawOperands) do
			encodeWord(bytes, evalExpr(operand, symbols, currentAddress, origin))
		end
		return
	end
	if name == "DD" then
		for _, operand in ipairs(inst.rawOperands) do
			encodeDword(bytes, evalExpr(operand, symbols, currentAddress, origin))
		end
		return
	end
	if name == "PADTO" then
		local target = evalExpr(inst.rawOperands[1], symbols, currentAddress, origin)
		local fill = inst.rawOperands[2] and evalExpr(inst.rawOperands[2], symbols, currentAddress, origin) or 0
		while origin + #bytes < target do
			bytes[#bytes + 1] = fill % 256
		end
		return
	end
	if name == "NOP" then
		bytes[#bytes + 1] = 0x90
		return
	end
	if name == "CLI" then
		bytes[#bytes + 1] = 0xFA
		return
	end
	if name == "STI" then
		bytes[#bytes + 1] = 0xFB
		return
	end
	if name == "HLT" then
		bytes[#bytes + 1] = 0xF4
		return
	end
	if name == "RET" then
		bytes[#bytes + 1] = 0xC3
		return
	end
	if name == "RETF" then
		bytes[#bytes + 1] = 0xCB
		return
	end
	if name == "IRET" then
		bytes[#bytes + 1] = 0xCF
		return
	end
	if name == "INT" then
		bytes[#bytes + 1] = 0xCD
		bytes[#bytes + 1] = evalExpr(operands[1].expr, symbols, currentAddress, origin) % 256
		return
	end
	if name == "LGDT" or name == "LIDT" then
		local op = operands[1]
		local regField = name == "LGDT" and 2 or 3
		if needsAddressPrefix(op, default32) then
			bytes[#bytes + 1] = 0x67
		end
		bytes[#bytes + 1] = 0x0F
		bytes[#bytes + 1] = 0x01
		encodeMem(bytes, op, regField, symbols, currentAddress, origin)
		return
	end
	if name == "SMSW" or name == "LMSW" then
		local op = operands[1]
		local regField = name == "SMSW" and 4 or 6
		if needsAddressPrefix(op, default32) then
			bytes[#bytes + 1] = 0x67
		end
		bytes[#bytes + 1] = 0x0F
		bytes[#bytes + 1] = 0x01
		if op.kind == "reg16" then
			bytes[#bytes + 1] = modrm(3, regField, op.code)
		else
			encodeMem(bytes, op, regField, symbols, currentAddress, origin)
		end
		return
	end
	if name == "IN" then
		local dst = operands[1]
		local src = operands[2]
		local width = operandWidth(dst, default32)
		local dstIsWord = (width == 16 or width == 32) and dst.code == 0
		if needsOperandPrefix(width, default32) then
			bytes[#bytes + 1] = 0x66
		end
		if src.kind == "imm" then
			bytes[#bytes + 1] = dstIsWord and 0xE5 or 0xE4
			bytes[#bytes + 1] = evalExpr(src.expr, symbols, currentAddress, origin) % 256
			return
		end
		assert(src.kind == "reg16" and src.code == REG16.DX, "Assembler8086: supported IN forms are IN AL|AX, imm8|DX")
		bytes[#bytes + 1] = dstIsWord and 0xED or 0xEC
		return
	end
	if name == "OUT" then
		local dst = operands[1]
		local src = operands[2]
		local width = operandWidth(src, default32)
		local srcIsWord = (width == 16 or width == 32) and src.code == 0
		if needsOperandPrefix(width, default32) then
			bytes[#bytes + 1] = 0x66
		end
		if dst.kind == "imm" then
			bytes[#bytes + 1] = srcIsWord and 0xE7 or 0xE6
			bytes[#bytes + 1] = evalExpr(dst.expr, symbols, currentAddress, origin) % 256
			return
		end
		assert(
			dst.kind == "reg16" and dst.code == REG16.DX,
			"Assembler8086: supported OUT forms are OUT imm8|DX, AL|AX"
		)
		bytes[#bytes + 1] = srcIsWord and 0xEF or 0xEE
		return
	end
	if name == "PUSH" then
		local op = operands[1]
		local width = operandWidth(op, default32)
		if needsOperandPrefix(width, default32) then
			bytes[#bytes + 1] = 0x66
		end
		if op.kind == "reg16" or op.kind == "reg32" then
			bytes[#bytes + 1] = 0x50 + op.code
		else
			bytes[#bytes + 1] = 0x68
			if width == 32 then
				encodeDword(bytes, evalExpr(op.expr, symbols, currentAddress, origin))
			else
				encodeWord(bytes, evalExpr(op.expr, symbols, currentAddress, origin))
			end
		end
		return
	end
	if name == "POP" then
		local width = operandWidth(operands[1], default32)
		if needsOperandPrefix(width, default32) then
			bytes[#bytes + 1] = 0x66
		end
		bytes[#bytes + 1] = 0x58 + operands[1].code
		return
	end
	if name == "INC" then
		local width = operandWidth(operands[1], default32)
		if needsOperandPrefix(width, default32) then
			bytes[#bytes + 1] = 0x66
		end
		bytes[#bytes + 1] = 0x40 + operands[1].code
		return
	end
	if name == "DEC" then
		local width = operandWidth(operands[1], default32)
		if needsOperandPrefix(width, default32) then
			bytes[#bytes + 1] = 0x66
		end
		bytes[#bytes + 1] = 0x48 + operands[1].code
		return
	end
	if name == "JMP" then
		local op = operands[1]
		local width = controlTransferWidth(op, default32)
		emitPrefixes(bytes, op.kind == "mem" and op or nil, width, default32)
		if op.kind == "reg16" or op.kind == "reg32" then
			bytes[#bytes + 1] = 0xFF
			bytes[#bytes + 1] = modrm(3, 4, op.code)
		elseif op.kind == "mem" then
			bytes[#bytes + 1] = 0xFF
			encodeMem(bytes, op, 4, symbols, currentAddress, origin)
		else
			local target = evalExpr(op.expr, symbols, currentAddress, origin)
			local rel = target
				- (currentAddress + (needsOperandPrefix(width, default32) and 1 or 0) + 1 + (width == 32 and 4 or 2))
			bytes[#bytes + 1] = 0xE9
			if width == 32 then
				encodeDword(bytes, rel)
			else
				encodeWord(bytes, rel)
			end
		end
		return
	end
	if name == "CALL" then
		local op = operands[1]
		local width = controlTransferWidth(op, default32)
		emitPrefixes(bytes, op.kind == "mem" and op or nil, width, default32)
		if op.kind == "reg16" or op.kind == "reg32" then
			bytes[#bytes + 1] = 0xFF
			bytes[#bytes + 1] = modrm(3, 2, op.code)
		elseif op.kind == "mem" then
			bytes[#bytes + 1] = 0xFF
			encodeMem(bytes, op, 2, symbols, currentAddress, origin)
		else
			local target = evalExpr(op.expr, symbols, currentAddress, origin)
			local rel = target
				- (currentAddress + (needsOperandPrefix(width, default32) and 1 or 0) + 1 + (width == 32 and 4 or 2))
			bytes[#bytes + 1] = 0xE8
			if width == 32 then
				encodeDword(bytes, rel)
			else
				encodeWord(bytes, rel)
			end
		end
		return
	end
	if isCondJump(name) then
		local inverseOpcode = ({
			JE = 0x75,
			JZ = 0x75,
			JNE = 0x74,
			JNZ = 0x74,
			JC = 0x73,
			JNC = 0x72,
		})[name]
		local target = evalExpr(operands[1].expr, symbols, currentAddress, origin)
		local rel = target - (currentAddress + (default32 and 7 or 5))
		bytes[#bytes + 1] = inverseOpcode
		bytes[#bytes + 1] = default32 and 0x05 or 0x03
		bytes[#bytes + 1] = 0xE9
		if default32 then
			encodeDword(bytes, rel)
		else
			encodeWord(bytes, rel)
		end
		return
	end
	if name == "MOV" then
		local dst = operands[1]
		local src = operands[2]
		if (dst.kind == "reg16" or dst.kind == "reg32") and src.kind == "imm" then
			local width = operandWidth(dst, default32)
			if needsOperandPrefix(width, default32) then
				bytes[#bytes + 1] = 0x66
			end
			bytes[#bytes + 1] = 0xB8 + dst.code
			if width == 32 then
				encodeDword(bytes, evalExpr(src.expr, symbols, currentAddress, origin))
			else
				encodeWord(bytes, evalExpr(src.expr, symbols, currentAddress, origin))
			end
			return
		end
		if dst.kind == "reg8" and src.kind == "imm" then
			bytes[#bytes + 1] = 0xB0 + dst.code
			bytes[#bytes + 1] = evalExpr(src.expr, symbols, currentAddress, origin) % 256
			return
		end
		if dst.kind == "seg" and src.kind == "reg16" then
			assert(dst.code ~= 1, "Assembler8086: MOV CS, r/m16 is not supported")
			if default32 then
				bytes[#bytes + 1] = 0x66
			end
			bytes[#bytes + 1] = 0x8E
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if dst.kind == "reg16" and src.kind == "seg" then
			if default32 then
				bytes[#bytes + 1] = 0x66
			end
			bytes[#bytes + 1] = 0x8C
			bytes[#bytes + 1] = modrm(3, src.code, dst.code)
			return
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, nil, width, default32)
			bytes[#bytes + 1] = 0x8B
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if dst.kind == "reg8" and src.kind == "reg8" then
			bytes[#bytes + 1] = 0x8A
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and src.kind == "mem" then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, src, width, default32)
			bytes[#bytes + 1] = 0x8B
			encodeMem(bytes, src, dst.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "reg8" and src.kind == "mem" then
			emitPrefixes(bytes, src, 8, default32)
			bytes[#bytes + 1] = 0x8A
			encodeMem(bytes, src, dst.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(src, default32)
			emitPrefixes(bytes, dst, width, default32)
			bytes[#bytes + 1] = 0x89
			encodeMem(bytes, dst, src.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and src.kind == "reg8" then
			emitPrefixes(bytes, dst, 8, default32)
			bytes[#bytes + 1] = 0x88
			encodeMem(bytes, dst, src.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and src.kind == "imm" then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, dst, width, default32)
			if width == 32 then
				bytes[#bytes + 1] = 0xC7
				encodeMem(bytes, dst, 0, symbols, currentAddress, origin)
				encodeDword(bytes, evalExpr(src.expr, symbols, currentAddress, origin))
			elseif width == 16 then
				bytes[#bytes + 1] = 0xC7
				encodeMem(bytes, dst, 0, symbols, currentAddress, origin)
				encodeWord(bytes, evalExpr(src.expr, symbols, currentAddress, origin))
			else
				bytes[#bytes + 1] = 0xC6
				encodeMem(bytes, dst, 0, symbols, currentAddress, origin)
				bytes[#bytes + 1] = evalExpr(src.expr, symbols, currentAddress, origin) % 256
			end
			return
		end
	end
	if name == "OR" then
		local dst = operands[1]
		local src = operands[2]
		if src.kind == "imm" then
			encodeGroupImm(bytes, 0x80, 0x81, 1, dst, src, symbols, currentAddress, origin, default32)
			return
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, nil, width, default32)
			bytes[#bytes + 1] = 0x0B
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if dst.kind == "reg8" and src.kind == "reg8" then
			bytes[#bytes + 1] = 0x0A
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and src.kind == "mem" then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, src, width, default32)
			bytes[#bytes + 1] = 0x0B
			encodeMem(bytes, src, dst.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "reg8" and src.kind == "mem" then
			emitPrefixes(bytes, src, 8, default32)
			bytes[#bytes + 1] = 0x0A
			encodeMem(bytes, src, dst.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(src, default32)
			emitPrefixes(bytes, dst, width, default32)
			bytes[#bytes + 1] = 0x09
			encodeMem(bytes, dst, src.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and src.kind == "reg8" then
			emitPrefixes(bytes, dst, 8, default32)
			bytes[#bytes + 1] = 0x08
			encodeMem(bytes, dst, src.code, symbols, currentAddress, origin)
			return
		end
	end
	if name == "AND" then
		local dst = operands[1]
		local src = operands[2]
		if src.kind == "imm" then
			encodeGroupImm(bytes, 0x80, 0x81, 4, dst, src, symbols, currentAddress, origin, default32)
			return
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, nil, width, default32)
			bytes[#bytes + 1] = 0x23
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if dst.kind == "reg8" and src.kind == "reg8" then
			bytes[#bytes + 1] = 0x22
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and src.kind == "mem" then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, src, width, default32)
			bytes[#bytes + 1] = 0x23
			encodeMem(bytes, src, dst.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "reg8" and src.kind == "mem" then
			emitPrefixes(bytes, src, 8, default32)
			bytes[#bytes + 1] = 0x22
			encodeMem(bytes, src, dst.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(src, default32)
			emitPrefixes(bytes, dst, width, default32)
			bytes[#bytes + 1] = 0x21
			encodeMem(bytes, dst, src.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and src.kind == "reg8" then
			emitPrefixes(bytes, dst, 8, default32)
			bytes[#bytes + 1] = 0x20
			encodeMem(bytes, dst, src.code, symbols, currentAddress, origin)
			return
		end
	end
	if name == "ADD" then
		local dst = operands[1]
		local src = operands[2]
		if src.kind == "imm" then
			encodeGroupImm(bytes, 0x80, 0x81, 0, dst, src, symbols, currentAddress, origin, default32)
			return
		end
	end
	if name == "SUB" then
		local dst = operands[1]
		local src = operands[2]
		if src.kind == "imm" then
			encodeGroupImm(bytes, 0x80, 0x81, 5, dst, src, symbols, currentAddress, origin, default32)
			return
		end
	end
	if name == "CMP" then
		local dst = operands[1]
		local src = operands[2]
		if src.kind == "imm" then
			encodeGroupImm(bytes, 0x80, 0x81, 7, dst, src, symbols, currentAddress, origin, default32)
			return
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, nil, width, default32)
			bytes[#bytes + 1] = 0x3B
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if dst.kind == "reg8" and src.kind == "reg8" then
			bytes[#bytes + 1] = 0x3A
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if (dst.kind == "reg16" or dst.kind == "reg32") and src.kind == "mem" then
			local width = operandWidth(dst, default32)
			emitPrefixes(bytes, src, width, default32)
			bytes[#bytes + 1] = 0x3B
			encodeMem(bytes, src, dst.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "reg8" and src.kind == "mem" then
			emitPrefixes(bytes, src, 8, default32)
			bytes[#bytes + 1] = 0x3A
			encodeMem(bytes, src, dst.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(src, default32)
			emitPrefixes(bytes, dst, width, default32)
			bytes[#bytes + 1] = 0x39
			encodeMem(bytes, dst, src.code, symbols, currentAddress, origin)
			return
		end
		if dst.kind == "mem" and src.kind == "reg8" then
			emitPrefixes(bytes, dst, 8, default32)
			bytes[#bytes + 1] = 0x38
			encodeMem(bytes, dst, src.code, symbols, currentAddress, origin)
			return
		end
	end
	if name == "XOR" then
		local dst = operands[1]
		local src = operands[2]
		if (dst.kind == "reg16" or dst.kind == "reg32") and (src.kind == "reg16" or src.kind == "reg32") then
			local width = operandWidth(dst, default32)
			if needsOperandPrefix(width, default32) then
				bytes[#bytes + 1] = 0x66
			end
			bytes[#bytes + 1] = 0x33
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
		if dst.kind == "reg8" and src.kind == "reg8" then
			bytes[#bytes + 1] = 0x32
			bytes[#bytes + 1] = modrm(3, dst.code, src.code)
			return
		end
	end

	error("Assembler8086: unsupported instruction " .. tostring(name))
end

function Assembler8086.compile(source, opts)
	opts = opts or {}
	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		local parsed = parseLine(line)
		if parsed then
			table.insert(lines, parsed)
		end
	end

	local origin = opts.origin or 0
	local defaultOperand32 = opts.defaultOperand32 == true
	local address = origin
	local symbols = {}

	for _, inst in ipairs(lines) do
		for _, label in ipairs(inst.labels or {}) do
			symbols[label] = address
		end
		if inst.name == "ORG" then
			origin = evalExpr(inst.rawOperands[1], symbols, address, origin)
			address = origin
		elseif inst.name == "PADTO" then
			address = math.max(address, evalExpr(inst.rawOperands[1], symbols, address, origin))
		elseif inst.name then
			address = address + estimateInstruction(inst.name, inst.operands, defaultOperand32)
		end
	end

	local bytes = {}
	origin = opts.origin or 0
	address = origin
	for _, inst in ipairs(lines) do
		if inst.name == "ORG" then
			origin = evalExpr(inst.rawOperands[1], symbols, address, origin)
			address = origin
		elseif inst.name then
			local before = #bytes
			encodeInstruction(inst, bytes, symbols, address, origin, defaultOperand32)
			address = address + (#bytes - before)
		end
	end

	return {
		bytes = bytes,
		symbols = symbols,
		origin = origin,
	}
end

return Assembler8086
