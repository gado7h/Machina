-- Check the FAT and see what's happening

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FAT Analysis ===")

task.wait(0.5)

local fdc = machine.fdc
local cpu = machine.cpu

-- The boot sector reads root directory at some point
-- Let's check what sectors are being accessed

-- First, check the FAT (LBA 1-9, 9 sectors = 2 FATs * 9 sectors = 18 sectors but first is at 1)
print("\n=== FAT1 (LBA 1) ===")
local fat1 = fdc:readSector(1)
if fat1 then
    -- FAT12 entry for cluster 0x014C (KERNEL.SYS start cluster)
    -- Each entry is 12 bits (1.5 bytes)
    -- Cluster 0x014C = 332
    -- Byte offset = floor(332 * 1.5) = 498
    -- Two bytes at offset 498 and 499 contain the 12-bit entry
    
    local entryOffset = math.floor(332 * 1.5) + 1  -- 1-indexed
    local b1 = fat1[entryOffset] or 0
    local b2 = fat1[entryOffset + 1] or 0
    
    print(string.format("FAT entry for cluster 0x014C (offset %d): %02X %02X", entryOffset, b1, b2))
    
    -- Parse 12-bit FAT entry
    -- If cluster number is even: low 4 bits of first byte + high 8 bits of second byte
    -- If cluster number is odd: full first byte + high 4 bits of second byte
    local nextCluster
    if (332 % 2) == 0 then
        nextCluster = bit32.band(b1, 0x0F) * 256 + b2
    else
        nextCluster = b1 * 16 + bit32.rshift(b2, 4)
    end
    print(string.format("Next cluster in chain: %d (0x%04X)", nextCluster, nextCluster))
    
    -- If next cluster is 0xFF8-0xFFF, it's end of chain
    print(string.format("Is end of chain (>= 0xFF8): %s", tostring(nextCluster >= 0xFF8)))
end

-- Check what memory looks like
print("\n=== Memory at 0x200 (where root dir is read) ===")
local mem = {}
for i = 0, 31 do
    mem[i+1] = cpu:readPhysical8(0x200 + i)
end
local memStr = {}
for i = 1, 32 do table.insert(memStr, string.format("%02X", mem[i])) end
print(table.concat(memStr, " "))

-- The memory has 4C 01 00 F0 which is NOT root directory data
-- This looks like FAT data! The first two FAT entries for clusters 0 and 1

print("\n=== FAT Table First Entries ===")
if fat1 then
    print("First 16 bytes of FAT1:")
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", fat1[i])) end
    print("  " .. table.concat(b, " "))
end

-- So it seems like the boot sector is reading the FAT, not the root directory!
-- This explains why memory at 0x200 contains FAT data

-- Let's verify: if it reads LBA 1 (FAT), memory at 0x200 should have FAT data
print("\n=== Comparison ===")
print("Memory[0x200]:    " .. table.concat(memStr:sub(1, 32):split(" "), " "))
if fat1 then
    local fatStr = {}
    for i = 1, 16 do table.insert(fatStr, string.format("%02X", fat1[i])) end
    print("FAT1 (LBA 1):   " .. table.concat(fatStr, " "))
end

-- The memory shows F0 FF at position 2-3 which in FAT12 means:
-- Cluster 0 = 0xFF0 (end of chain - reserved)
-- Cluster 1 = 0x0FF (maybe free?)

-- Actually 0x4C 0x01 in little endian as a 16-bit value is 0x014C
-- But in FAT12 at position 0 (cluster 0), we'd expect 0xFF0 or similar

-- Let me check what the actual root directory looks like
print("\n=== Root Directory at LBA 19 ===")
local rootDir = fdc:readSector(19)
if rootDir then
    local b = {}
    for i = 1, 32 do table.insert(b, string.format("%02X", rootDir[i])) end
    print("  " .. table.concat(b, " "))
    
    -- Parse as directory entry
    local name = ""
    for i = 1, 8 do
        if rootDir[i] >= 0x20 and rootDir[i] < 0x7F then
            name = name .. string.char(rootDir[i])
        end
    end
    print("  First entry: " .. name)
end

print("\n=== THE BUG ===")
print("FreeDOS boot reads from WRONG LBA!")
print("  Expected: LBA 19 (root dir)")
print("  Actually reading: LBA ? (checking...)")

-- Let me find which LBA gives us the memory content
for lba = 0, 30 do
    local sector = fdc:readSector(lba)
    if sector then
        local match = true
        for i = 1, 8 do
            if sector[i] ~= mem[i] then match = false break end
        end
        if match then
            print("  Found match at LBA " .. lba)
        end
    end
end

machine:shutdown()
print("\nDone.")