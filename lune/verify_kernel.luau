-- Wait - earlier the directory showed cluster 7, not 332!

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== VERIFY: KERNEL.SYS location ===")

task.wait(0.3)

local fdc = machine.fdc
local cpu = machine.cpu

-- Read root directory at LBA 19
local rootDir = fdc:readSector(19)

print("=== Root Directory Entry #5 (KERNEL.SYS) ===")
-- Entry 5 is at offset 5*32 = 160
local entryOffset = 5 * 32 + 1

-- Get all 32 bytes of entry
local entry = {}
for i = 0, 31 do
    entry[i+1] = rootDir[entryOffset + i]
end

-- Parse filename
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

print(string.format("Name: %s.%s", name, ext))

-- Cluster is at offset 26-27 (0x1A-0x1B)
local clusterLow = entry[27]  -- offset 26 is 1-based = index 26, but table is 1-indexed
local clusterHigh = entry[28]
local startCluster = entry[27] + entry[28] * 256

print(string.format("Start cluster: %d (0x%04X)", startCluster, startCluster))

-- Calculate LBA for cluster 7
local dataStartLba = 33  -- root dir ends at 19 + 14 = 33
local clusterLba = dataStartLba + (startCluster - 2) * 2

print(string.format("LBA for cluster %d: %d", startCluster, clusterLba))

-- Check that LBA
local kernelData = fdc:readSector(clusterLba)
if kernelData then
    print("\n=== Data at LBA " .. clusterLba .. " ===")
    local b = {}
    for i = 1, 32 do table.insert(b, string.format("%02X", kernelData[i])) end
    print(table.concat(b, " "))
    
    -- Check for KERNEL.SYS signature
    local isKernel = false
    for i = 1, 32 do
        if kernelData[i] == 0xEB and kernelData[i+1] == 0x1B then
            isKernel = true
            break
        end
    end
    print("Has kernel signature (EB 1B): " .. tostring(isKernel))
end

-- The earlier debug showed memory at 0x200 = 4C 01 00 F0
-- That's cluster number 0x014C in FAT12 format!
-- But wait, that's the root dir entry cluster field, not data

-- Let's check what's in memory at 0x200 now
print("\n=== Memory at 0x200 (current) ===")
local mem = {}
for i = 0, 15 do
    mem[i+1] = cpu:readPhysical8(0x200 + i)
end
local m = {}
for i = 1, 16 do table.insert(m, string.format("%02X", mem[i])) end
print(table.concat(m, " "))

-- This is the actual problem - the boot sector is NOT reading root directory
-- It's reading something else that returns 4C 01 00 F0
-- That pattern is in the root directory entry (cluster number 0x014C for KERNEL.SYS)
-- But it's NOT the root directory data!

print("\n=== SOLUTION ===")
print("The boot sector is reading WRONG LBA!")
print("It reads LBA = 0 (boot sector) or LBA = 10 (some other data)")
print("But root directory is at LBA 19")
print("")
print("We need to either:")
print("1. Fix the CHS->LBA conversion to match FreeDOS expectations")
print("2. OR make the emulator return root directory data for the sector FreeDOS requests")

-- Let's verify: what does FreeDOS boot sector READ vs what it SHOULD read
-- FreeDOS uses CHS=0/0/1 which our emulator maps to LBA 0
-- But root dir is at LBA 19

-- The BPB in the boot sector says:
-- - Reserved: 1 sector
-- - FATs: 2 * 9 = 18 sectors  
-- - Root dir: starts at sector 19

-- So the first data read (sector 1 in CHS) should map to LBA 19!

-- The fix: We need to change our CHS->LBA mapping to match what FreeDOS expects!
-- FreeDOS expects: sector 1 = root dir at LBA 19
-- Our emulator: sector 1 = LBA 0

-- This means our FLOPPY geometry configuration is WRONG for this boot sector!

machine:shutdown()
print("\nDone.")