local Assembler8086 = require("@src/platforms/x86/Assembler8086")
local BiosRom = require("@src/platforms/x86/BiosRom")
local MachineProfile = require("@src/platforms/x86/MachineProfile")

local BootImageCatalogUtils = {}

function BootImageCatalogUtils.sectorCountForBytes(bytes)
	return math.max(1, math.ceil(#bytes / 512))
end

function BootImageCatalogUtils.writeChunk(sectors, startLba, bytes)
	local count = BootImageCatalogUtils.sectorCountForBytes(bytes)
	for sectorIndex = 0, count - 1 do
		local sector = {}
		for index = 1, 512 do
			sector[index] = bytes[sectorIndex * 512 + index] or 0
		end
		sectors[startLba + sectorIndex] = sector
	end
	return count
end

function BootImageCatalogUtils.sectorToCHS(x86, sectorNumber)
	local spt = x86.SECTORS_PER_TRACK or 18
	local heads = x86.HEADS or 1
	local index = math.max(0, (tonumber(sectorNumber) or 1) - 1)
	local trackSize = math.max(1, spt * heads)
	local cylinder = math.floor(index / trackSize)
	local head = math.floor(index / spt) % heads
	local sector = (index % spt) + 1
	return cylinder, head, sector
end

function BootImageCatalogUtils.encodeCHSWord(x86, sectorNumber)
	local cylinder, _, sector = BootImageCatalogUtils.sectorToCHS(x86, sectorNumber)
	return bit32.bor(
		bit32.lshift(bit32.band(cylinder, 0xFF), 8),
		bit32.lshift(bit32.band(bit32.rshift(cylinder, 8), 0x03), 6),
		bit32.band(sector, 0x3F)
	)
end

function BootImageCatalogUtils.hex16(value)
	return string.format("0x%04X", (tonumber(value) or 0) % 0x10000)
end

function BootImageCatalogUtils.descriptorWords(base, access, limit, flags)
	local linear = (tonumber(base) or 0) % 0x100000000
	local segmentLimit = (tonumber(limit) or 0x000FFFFF) % 0x100000
	local baseLow = linear % 0x10000
	local baseMid = math.floor(linear / 0x10000) % 0x100
	local baseHigh = math.floor(linear / 0x1000000) % 0x100
	local limitLow = segmentLimit % 0x10000
	local limitHigh = math.floor(segmentLimit / 0x10000) % 0x10
	local flagsByte = bit32.bor(bit32.lshift((tonumber(flags) or 0x0C) % 0x10, 4), limitHigh)
	return {
		limitLow = limitLow,
		baseLow = baseLow,
		accessBaseMid = (access % 0x100) * 0x100 + baseMid,
		flagsBaseHigh = baseHigh * 0x100 + flagsByte,
	}
end

function BootImageCatalogUtils.concatBytes(first, second)
	local out = {}
	for _, byte in ipairs(first or {}) do
		out[#out + 1] = byte
	end
	for _, byte in ipairs(second or {}) do
		out[#out + 1] = byte
	end
	return out
end

function BootImageCatalogUtils.buildStandaloneBootImage(config, name, bootSource)
	MachineProfile.validateConfig(config)

	local biosArtifact = BiosRom.buildArtifact(config)
	local bootArtifact = Assembler8086.compile(bootSource)
	assert(#bootArtifact.bytes <= 512, name .. " boot sector exceeds 512 bytes")

	local sectors = {}
	local bootSector = {}
	for index = 1, 512 do
		bootSector[index] = bootArtifact.bytes[index] or 0
	end
	sectors[0] = bootSector

	return {
		name = name,
		romBytes = BiosRom.buildROMBytes(config, biosArtifact),
		sectors = sectors,
		layout = {
			kernelSectorStart = 0,
			kernelSectorCount = 0,
			fsSuperSector = 0,
			rootDirSector = 0,
			rootDirSectorCount = 0,
			dataStartSector = 0,
			fileCount = 0,
		},
		files = {},
		symbols = {
			bios = biosArtifact.symbols,
			bootSector = bootArtifact.symbols,
			kernel = {},
		},
	}
end

function BootImageCatalogUtils.buildTextValidationBootSource(passText)
	return table.concat({
		"ORG 0x7C00",
		"START:",
		"  MOV AX, 0x0003",
		"  INT 0x10",
		"  MOV SI, PASS_MSG",
		"  CALL PRINT_STRING",
		"HANG:",
		"  HLT",
		"  JMP HANG",
		"PRINT_STRING:",
		"  MOV AL, [SI]",
		"  CMP AL, 0",
		"  JE PRINT_DONE",
		"  MOV AH, 0x0E",
		"  INT 0x10",
		"  INC SI",
		"  JMP PRINT_STRING",
		"PRINT_DONE:",
		"  RET",
		"PASS_MSG:",
		string.format('  DB "%s", 13, 10, 0', passText),
		"PADTO 0x7DFE, 0",
		"DW 0xAA55",
	}, "\n")
end

function BootImageCatalogUtils.buildLoadedBootImage(config, name, kernelSource, options)
	MachineProfile.validateConfig(config)

	options = options or {}
	local kernelOrigin = options.kernelOrigin or 0x0500
	local kernelAssemblerOptions = {
		origin = kernelOrigin,
		defaultOperand32 = options.defaultOperand32 == true,
	}
	local kernelArtifact = Assembler8086.compile(kernelSource, kernelAssemblerOptions)
	local kernelSectorCount = BootImageCatalogUtils.sectorCountForBytes(kernelArtifact.bytes)
	local bootMessage = options.bootMessage

	local bootLines = {
		"ORG 0x7C00",
		"START:",
		"  CLI",
		"  XOR AX, AX",
		"  MOV DS, AX",
		"  MOV ES, AX",
		"  MOV SS, AX",
		"  MOV SP, 0x7C00",
		"  MOV [BOOT_DRIVE], DL",
	}
	if bootMessage then
		bootLines[#bootLines + 1] = "  MOV SI, BOOT_MSG"
		bootLines[#bootLines + 1] = "  CALL PRINT_STRING"
	end
	bootLines[#bootLines + 1] = "  MOV AX, " .. BootImageCatalogUtils.hex16(bit32.bor(0x0200, kernelSectorCount))
	bootLines[#bootLines + 1] = "  MOV BX, " .. BootImageCatalogUtils.hex16(kernelOrigin)
	bootLines[#bootLines + 1] = "  MOV CX, 0x0002"
	bootLines[#bootLines + 1] = "  MOV DL, [BOOT_DRIVE]"
	bootLines[#bootLines + 1] = "  INT 0x13"
	bootLines[#bootLines + 1] = "  JC LOAD_FAIL"
	bootLines[#bootLines + 1] = "  PUSH 0x0000"
	bootLines[#bootLines + 1] = "  PUSH " .. BootImageCatalogUtils.hex16(kernelOrigin)
	bootLines[#bootLines + 1] = "  RETF"
	bootLines[#bootLines + 1] = "LOAD_FAIL:"
	bootLines[#bootLines + 1] = "  MOV SI, FAIL_MSG"
	bootLines[#bootLines + 1] = "  CALL PRINT_STRING"
	bootLines[#bootLines + 1] = "  HLT"
	bootLines[#bootLines + 1] = "  JMP LOAD_FAIL"
	bootLines[#bootLines + 1] = "PRINT_STRING:"
	bootLines[#bootLines + 1] = "  MOV AL, [SI]"
	bootLines[#bootLines + 1] = "  CMP AL, 0"
	bootLines[#bootLines + 1] = "  JE PRINT_DONE"
	bootLines[#bootLines + 1] = "  MOV AH, 0x0E"
	bootLines[#bootLines + 1] = "  INT 0x10"
	bootLines[#bootLines + 1] = "  INC SI"
	bootLines[#bootLines + 1] = "  JMP PRINT_STRING"
	bootLines[#bootLines + 1] = "PRINT_DONE:"
	bootLines[#bootLines + 1] = "  RET"
	bootLines[#bootLines + 1] = "BOOT_DRIVE:"
	bootLines[#bootLines + 1] = "  DB 0"
	if bootMessage then
		bootLines[#bootLines + 1] = "BOOT_MSG:"
		bootLines[#bootLines + 1] = string.format('  DB "%s", 13, 10, 0', bootMessage)
	end
	bootLines[#bootLines + 1] = "FAIL_MSG:"
	bootLines[#bootLines + 1] = '  DB "FAIL boot loader", 13, 10, 0'
	bootLines[#bootLines + 1] = "PADTO 0x7DFE, 0"
	bootLines[#bootLines + 1] = "DW 0xAA55"

	local bootSource = table.concat(bootLines, "\n")
	local biosArtifact = BiosRom.buildArtifact(config)
	local bootArtifact = Assembler8086.compile(bootSource)
	assert(#bootArtifact.bytes <= 512, name .. " boot sector exceeds 512 bytes")

	local sectors = {}
	local bootSector = {}
	for index = 1, 512 do
		bootSector[index] = bootArtifact.bytes[index] or 0
	end
	sectors[0] = bootSector
	BootImageCatalogUtils.writeChunk(sectors, 1, kernelArtifact.bytes or {})

	return {
		name = name,
		romBytes = BiosRom.buildROMBytes(config, biosArtifact),
		sectors = sectors,
		layout = {
			kernelSectorStart = 1,
			kernelSectorCount = kernelSectorCount,
			fsSuperSector = 0,
			rootDirSector = 0,
			rootDirSectorCount = 0,
			dataStartSector = 0,
			fileCount = 0,
		},
		files = {},
		symbols = {
			bios = biosArtifact.symbols,
			bootSector = bootArtifact.symbols,
			kernel = kernelArtifact.symbols,
		},
	}
end

function BootImageCatalogUtils.buildProtectedModeKernelRoutines(passText)
	return {
		"PRINT_STRING_PM:",
		"  MOV AL, [ESI]",
		"  CMP AL, 0",
		"  JE PRINT_STRING_PM_DONE",
		"  CALL PUTC",
		"  INC ESI",
		"  JMP PRINT_STRING_PM",
		"PRINT_STRING_PM_DONE:",
		"  RET",
		"PUTC:",
		"  MOV DX, DS",
		"  PUSH EAX",
		"  MOV AX, 0x0018",
		"  MOV DS, AX",
		"  POP EAX",
		"  MOV [EDI], AL",
		"  INC EDI",
		"  MOV BYTE [EDI], 0x07",
		"  INC EDI",
		"  MOV DS, DX",
		"  RET",
		"PASS_MSG:",
		string.format('  DB "%s", 13, 10, 0', passText),
		"FAIL_MSG:",
		string.format('  DB "FAIL %s", 13, 10, 0', passText),
	}
end

function BootImageCatalogUtils.buildIdtEntries(maxVector, entries)
	local lines = {}
	for vector = 0, maxVector do
		local entry = entries[vector]
		if entry then
			lines[#lines + 1] = "  DW "
				.. entry.offset
				.. ", "
				.. entry.selector
				.. ", 0x0000, "
				.. entry.typeWord
				.. ", 0x0000"
		else
			lines[#lines + 1] = "  DW 0x0000, 0x0000, 0x0000, 0x0000, 0x0000"
		end
	end
	return lines
end

function BootImageCatalogUtils.mergeSymbols(...)
	local out = {}
	for _, symbolTable in ipairs({ ... }) do
		for name, value in pairs(symbolTable or {}) do
			out[name] = value
		end
	end
	return out
end

return BootImageCatalogUtils
