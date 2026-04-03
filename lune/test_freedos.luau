-- Debug: check BIOS ROM boot drive setting
local BiosRom = require("@src/platforms/x86/BiosRom")

local config = {
	X86 = {
		MACHINE_PROFILE = "ibm-pc-386-bios-v2",
		BOOT_DRIVE = 0x00,
		BOOT_ORDER = { "floppy", "ata" },
		BIOS_ENTRY_OFFSET = 0x0100,
		RESET_VECTOR_SEG = 0xF000,
		RESET_VECTOR_OFF = 0xFFF0,
		KERNEL_LOAD_SEG = 0x07C0,
		SECTORS_PER_TRACK = 18,
		HEADS = 2,
		FLOPPY_A_PRESENT = true,
		FLOPPY_A_TYPE = "35_1440k",
		FLOPPY_TRACKS = 80,
		FLOPPY_HEADS = 2,
		FLOPPY_SECTORS = 18,
	},
}

local artifact = BiosRom.buildArtifact(config)
local romBytes = BiosRom.buildROMBytes(config, artifact)

print("BIOS artifact:")
print("  origin: 0x" .. string.format("%04X", artifact.origin or 0))
print("  bytes: " .. #artifact.bytes)

-- Look for the boot drive setting in the assembled code
-- The BIOS ROM source has: "  MOV DL, 0x00" after the INT 13h call
-- Let's find it in the bytes
print("\nSearching for boot drive setting in ROM...")
for i = 1, #romBytes - 3 do
	-- Look for MOV DL, imm8 (B2 xx)
	if romBytes[i] == 0xB2 then
		print(string.format("  Found MOV DL, 0x%02X at offset 0x%04X", romBytes[i+1], i-1))
	end
	-- Look for MOV DX, imm16 (BA xx xx)
	if romBytes[i] == 0xBA then
		local val = romBytes[i+1] + romBytes[i+2] * 256
		print(string.format("  Found MOV DX, 0x%04X at offset 0x%04X", val, i-1))
	end
end

-- Also check the first 256 bytes of the ROM
print("\nFirst 256 bytes of ROM:")
for i = 1, 256 do
	if (i-1) % 16 == 0 then
		if i > 1 then print() end
		io.write(string.format("  %04X: ", i-1))
	end
	io.write(string.format("%02X ", romBytes[i] or 0xFF))
end
print()
