-- Analyze each disk read location in detail

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Detailed disk read analysis ===")

task.wait(0.3)

local cpu = machine.cpu
local fdc = machine.fdc

-- We found two disk reads:
-- 1. At IP 0050: CX = 0100 -> cylinder=1, sector=0
-- 2. At IP 00D7: CX = 000B -> cylinder=0, sector=11

-- Let's look at each in context

print("\n=== Disk read #1 at IP 0050 ===")
print("Code around IP 0050:")
for offset = 0x48, 0x58 do
    local b1 = cpu:readMem8(0x1FE0, offset)
    local b2 = cpu:readMem8(0x1FE0, offset + 1)
    local b3 = cpu:readMem8(0x1FE0, offset + 2)
    local disasm = ""
    
    if b1 == 0xB8 then disasm = "MOV AX, imm16"
    elseif b1 == 0xBA then disasm = "MOV DX, imm16" 
    elseif b1 == 0xB9 then disasm = "MOV CX, imm16"
    elseif b1 == 0xBB then disasm = "MOV BX, imm16"
    elseif b1 == 0xCD then disasm = "INT"
    elseif b1 == 0xE8 then disasm = "CALL rel16"
    else disasm = "" end
    
    print(string.format("  %04X: %02X %02X %02X - %s", offset, b1, b2 or 0, b3 or 0, disasm))
end

-- CX=0100 means cylinder=1, sector=0 - that's invalid (sector 0 doesn't exist!)
-- This might be a different operation, not a normal read

print("\n=== Disk read #2 at IP 00D7 ===")
print("Code around IP 00D7:")
for offset = 0xD0, 0xE0 do
    local b1 = cpu:readMem8(0x1FE0, offset)
    local b2 = cpu:readMem8(0x1FE0, offset + 1)
    local b3 = cpu:readMem8(0x1FE0, offset + 2)
    local disasm = ""
    
    if b1 == 0xB8 then disasm = "MOV AX, imm16"
    elseif b1 == 0xBA then disasm = "MOV DX, imm16" 
    elseif b1 == 0xB9 then disasm = "MOV CX, imm16"
    elseif b1 == 0xBB then disasm = "MOV BX, imm16"
    elseif b1 == 0xCD then disasm = "INT"
    else disasm = "" end
    
    print(string.format("  %04X: %02X %02X %02X - %s", offset, b1, b2 or 0, b3 or 0, disasm))
end

-- CX=000B means cylinder=0, sector=11
-- In CHS: cylinder=0, head=?, sector=11
-- With 18 spt, 2 heads, LBA = (0*2+head)*18 + (11-1)
-- If head=0: LBA = 0 + 10 = 10
-- If head=1: LBA = 18 + 10 = 28

-- Let's calculate what each of these would give
print("\n=== CHS -> LBA calculations ===")
print("Read #1: CH=1, CL=0 (cylinder=1, sector=0)")
print("  Sector 0 is INVALID (must be 1-18)")
print("")
print("Read #2: CH=0, CL=11 (cylinder=0, sector=11)")
print("  If head=0: LBA = (0*2+0)*18 + (11-1) = 10")
print("  If head=1: LBA = (0*2+1)*18 + (11-1) = 28")

-- Check what's at those LBAs
print("\n=== What's at LBA 10 and 28? ===")
local lba10 = fdc:readSector(10)
if lba10 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", lba10[i])) end
    print("LBA 10: " .. table.concat(b, " "))
end

local lba28 = fdc:readSector(28)
if lba28 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", lba28[i])) end
    print("LBA 28: " .. table.concat(b, " "))
end

-- Neither of these is the root directory (LBA 19)!
-- The boot sector is reading WRONG sectors!

print("\n=== CONCLUSION ===")
print("The FreeDOS boot sector reads from:")
print("  - LBA 10 (or 28 depending on head)")
print("  - Not LBA 19 (root directory)!")
print("")
print("This is why the boot fails - it's not reading the root directory!")
print("The boot sector might be expecting different geometry or has a bug.")

machine:shutdown()
print("\nDone.")