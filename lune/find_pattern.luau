-- Find which LBA actually contains 4C 01

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Finding the mystery LBA ===")

task.wait(0.5)

local fdc = machine.fdc
local cpu = machine.cpu

-- What memory shows
local memBytes = {}
for i = 0, 7 do
    memBytes[i+1] = cpu:readPhysical8(0x200 + i)
end

print("Memory at 0x200: " .. table.concat({
    table.foreach(memBytes, function(i,v) return string.format("%02X",v) end)
}, " "))

-- Search ALL sectors for matching pattern
print("\n=== Searching all LBAs for 4C 01 pattern ===")

local foundAny = false
for lba = 0, 50 do
    local sector = fdc:readSector(lba)
    if sector then
        -- Check if this sector has 4C 01 at any position
        for pos = 1, 500 do
            if sector[pos] == 0x4C and sector[pos+1] == 0x01 and sector[pos+2] == 0x00 and sector[pos+3] == 0xF0 then
                print(string.format("FOUND at LBA %d, byte offset %d", lba, pos - 1))
                foundAny = true
                break
            end
        end
    end
end

if not foundAny then
    print("Pattern not found in any sector!")
end

-- Let me check the actual root dir entry for KERNEL.SYS
print("\n=== Root directory KERNEL.SYS entry ===")
local rootDir = fdc:readSector(19)
if rootDir then
    -- Entry 5 (offset 160)
    local entryOffset = 5 * 32 + 1
    print("Entry 5 at offset " .. (entryOffset - 1) .. ":")
    
    local bytes = {}
    for i = 0, 31 do
        table.insert(bytes, string.format("%02X", rootDir[entryOffset + i] or 0))
    end
    print("  " .. table.concat(bytes, " "))
    
    -- The cluster number should be at offset 26 (0x1A)
    local clusterLow = rootDir[entryOffset + 26]
    local clusterHigh = rootDir[entryOffset + 27]
    print(string.format("  Cluster: 0x%02X%02X = 0x%04X", clusterHigh, clusterLow, clusterHigh * 256 + clusterLow))
end

-- So the boot sector IS finding KERNEL.SYS in root directory!
-- But something is going wrong after that

-- Let me trace what happens after it finds KERNEL.SYS
-- The boot sector should then:
-- 1. Read the FAT to get the cluster chain
-- 2. Load KERNEL.SYS clusters into memory
-- 3. Jump to KERNEL.SYS

-- But we see it's looping with "FreeDOS" printed
-- Maybe it's failing to load the kernel?

-- Let's check if maybe KERNEL.SYS itself exists
print("\n=== Is KERNEL.SYS data available? ===")
print("LBA 19 is root directory, next is data area")

-- Data starts at LBA 33 (19 + 14 root dir sectors)
-- KERNEL.SYS starts at cluster 0x014C
-- Cluster 0 = LBA 33 (first data sector)
-- Cluster 1 = LBA 33 + 1 = 34
-- ...
-- Cluster 0x014C = 332
-- LBA = 33 + (332 - 2) * 2 = 33 + 660 = 693

print("KERNEL.SYS starts at cluster 0x014C")
print("KERNEL.SYS first data sector would be around LBA 693")
print("But disk only has 2880 sectors...")

-- Let me check how much of the disk image is actual data vs zero-filled
print("\n=== Non-zero sectors count ===")
local nonZero = 0
for lba = 0, 100 do
    local sector = fdc:readSector(lba)
    if sector then
        local hasData = false
        for i = 1, 512 do
            if sector[i] ~= 0 then hasData = true break end
        end
        if hasData then nonZero = nonZero + 1 end
    end
end
print("First 100 sectors with data: " .. nonZero)

machine:shutdown()
print("\nDone.")