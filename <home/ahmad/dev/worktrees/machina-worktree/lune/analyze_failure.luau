-- Check if disk read is failing silently

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Checking for silent failure ===")

-- The key insight: memory at 0x200 shows 4C 01 00 F0
-- This is CLUSTER NUMBER for KERNEL.SYS in FAT12!
-- The boot sector reads root dir, finds KERNEL.SYS at cluster 0x014C

-- But wait - that's WRONG. The boot should first read root dir from LBA 19
-- Let me trace what actually happens

task.wait(0.5)

local cpu = machine.cpu
local fdc = machine.fdc

-- Check the KERNEL.SYS entry in root dir
local lba19 = fdc:readSector(19)
if lba19 then
    print("\n=== KERNEL.SYS directory entry ===")
    -- Entry 5 (offset 5*32 = 160)
    local entryOffset = 5 * 32 + 1
    local entry = {}
    for i = 0, 31 do
        entry[i+1] = lba19[entryOffset + i] or 0
    end
    
    local name = ""
    for i = 1, 8 do
        if entry[i] >= 0x20 and entry[i] < 0x7F then
            name = name .. string.char(entry[i])
        end
    end
    local ext = ""
    for i = 9, 11 do
        if entry[i] >= 0x20 and entry[i] < 0x7F then
            ext = ext .. string.char(entry[i])
        end
    end
    
    local size = entry[28] + entry[29] * 256 + entry[30] * 65536
    local startCluster = entry[26] + entry[27] * 256
    
    print(string.format("Name: %s.%s", name, ext))
    print(string.format("Size: %d bytes", size))
    print(string.format("Start cluster: %d (0x%04X)", startCluster, startCluster))
end

-- The issue might be that the boot sector is reading the wrong LBA
-- Let me see what CHS values the boot code uses

print("\n=== CHS Calculation Issue ===")
print("Boot sector BPB says:")
print("  Sectors per track: 18")
print("  Heads: 2")  
print("  Reserved: 1")
print("  FATs: 2")
print("  Sectors per FAT: 9")
print("  Root dir starts at: 1 + 2*9 = 19")
print("")
print("But boot code reads CHS = 0/0/1")
print("LBA = (0*2+0)*18 + (1-1) = 0")
print("")
print("So it reads LBA 0 (boot sector) instead of LBA 19 (root dir)!")
print("")
print("But memory shows 4C 01 00 F0, not boot sector data...")
print("Maybe it's reading from somewhere else!")

-- Let me check if maybe the boot sector code is different from what we think
-- Looking at offset 0x5E in the RELOCATED boot sector (0x1FE0:005E)

print("\n=== Boot sector code at 0x1FE0:005E ===")
local codeAt = {}
for i = 0x5E, 0x6F do
    local b = cpu:readMem8(0x1FE0, i)
    table.insert(codeAt, string.format("%02X", b))
end
print(table.concat(codeAt, " "))

-- This is: B8 01 00 (mov ax, 1) BA 00 02 (mov bx, 0200) 
-- Wait that says BX = 0x0200, but the memory shows it's being written to 0x0000:0200
-- Let me see what ES is set to

print("\n=== What is ES set to? ===")
print("ES = " .. string.format("%04X", cpu.seg.ES))

-- If ES is 0x0000 and BX is 0x0200, then it writes to linear address 0x0000*16 + 0x0200 = 0x200
-- That's what we're seeing!

-- So the disk read IS happening, but to the wrong LBA
-- Let me verify by checking if LBA 0 contains the boot sector
print("\n=== Is LBA 0 the boot sector? ===")
local lba0 = fdc:readSector(0)
if lba0 then
    local b = {}
    for i = 1, 8 do table.insert(b, string.format("%02X", lba0[i])) end
    print("LBA 0: " .. table.concat(b, " "))
end

-- So the boot sector code expects to read ROOT DIR but is reading LBA 0 (boot sector itself)
-- This is clearly wrong - the disk read parameters must be wrong

-- The root cause is that FreeDOS boot expects:
--   sector = 19 (root dir starts at sector 19)
-- But the boot code says:
--   sector = 1

-- Let me check what sector number the boot code ACTUALLY uses

-- Looking at the boot code at offset 0x1FE0:005E:
-- B8 01 00 - MOV AX, 0001  (AL = 1 sector)
-- BA 00 02 - MOV BX, 0200  (ES:BX = segment:offset, but here it's just offset? No...)
-- Wait, BA is MOV DX, imm16. So BX is being set via a different instruction.

-- Let me look more carefully at the code before that
print("\n=== More boot code ===")
for i = 0x55, 0x65 do
    local b = cpu:readMem8(0x1FE0, i)
    local bnext = cpu:readMem8(0x1FE0, i+1)
    print(string.format("%04X: %02X %02X", i, b, bnext))
end

-- I need to understand the actual disk read better. Let me check what sector the boot sector
-- is SUPPOSED to read vs what it DOES read

print("\n=== Summary ===")
print("The boot sector code reads CHS=0/0/1 which maps to LBA=0")
print("But root directory is at LBA=19")
print("This is the BUG - boot sector should read LBA 19 but reads LBA 0")
print("")
print("But memory at 0x200 doesn't match LBA 0 either...")
print("This suggests the disk read is failing and returning garbage")

machine:shutdown()
print("\nDone.")