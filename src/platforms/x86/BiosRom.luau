local Assembler8086 = require("@src/platforms/x86/Assembler8086")

local BiosRom = {}

local function buildSource(config)
	local x86 = config.X86 or {}
	local bootDrive = x86.BOOT_DRIVE or 0x80
	return table.concat({
		"ORG 0x0100",
		"START:",
		"  CLI",
		"  XOR AX, AX",
		"  MOV ES, AX",
		"  MOV SS, AX",
		"  MOV SP, 0x7C00",
		"  MOV AX, 0xF000",
		"  MOV DS, AX",
		"  MOV AX, 0x0003",
		"  INT 0x10",
		"  MOV SI, BIOS_BANNER",
		"  CALL PRINT_STRING",
		"  MOV AX, 0x0000",
		"  MOV DS, AX",
		"  MOV ES, AX",
		"  MOV BX, 0x7C00",
		"  MOV AX, 0x0201",
		"  MOV CX, 0x0001",
		"  MOV DX, " .. string.format("0x%04X", bootDrive),
		"  INT 0x13",
		"  JC BOOT_FAIL",
		"  PUSH 0x0000",
		"  PUSH 0x7C00",
		"  RETF",
		"BOOT_FAIL:",
		"  MOV AX, 0xF000",
		"  MOV DS, AX",
		"  MOV SI, BOOT_FAIL_MSG",
		"  CALL PRINT_STRING",
		"BOOT_HANG:",
		"  HLT",
		"  JMP BOOT_HANG",
		"DEFAULT_INT_HANDLER:",
		"  IRET",
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
		"BIOS_BANNER:",
		'  DB "Machina x86 BIOS", 13, 10, 0',
		"BOOT_FAIL_MSG:",
		'  DB "Boot failed", 13, 10, 0',
	}, "\n")
end

function BiosRom.buildArtifact(config)
	return Assembler8086.compile(buildSource(config))
end

function BiosRom.buildROMBytes(config, artifact)
	local x86 = config.X86 or {}
	local romSize = x86.ROM_SIZE or 0x10000
	local romBytes = {}
	for index = 1, romSize do
		romBytes[index] = 0xFF
	end

	for index, byte in ipairs((artifact and artifact.bytes) or {}) do
		local target = ((artifact.origin or 0) + index)
		if target >= 1 and target <= romSize then
			romBytes[target] = byte
		end
	end

	local resetOffset = ((x86.RESET_VECTOR_OFF or 0xFFF0) + 1)
	romBytes[resetOffset] = 0xEA
	romBytes[resetOffset + 1] = (x86.BIOS_ENTRY_OFFSET or 0x0100) % 256
	romBytes[resetOffset + 2] = math.floor((x86.BIOS_ENTRY_OFFSET or 0x0100) / 256) % 256
	romBytes[resetOffset + 3] = (x86.RESET_VECTOR_SEG or 0xF000) % 256
	romBytes[resetOffset + 4] = math.floor((x86.RESET_VECTOR_SEG or 0xF000) / 256) % 256

	return romBytes
end

return BiosRom
