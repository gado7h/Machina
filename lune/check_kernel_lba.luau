-- Check what's at high LBAs where kernel should be

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Check higher LBA for kernel data ===")

task.wait(0.3)

local fdc = machine.fdc

-- KERNEL.SYS is at cluster 0x014C = 332
-- In FAT12 with 2 sectors/cluster, data starts at LBA 33
-- LBA for cluster N = 33 + (N-2)*2

local kernelStartCluster = 0x014C
local kernelStartLba = 33 + (kernelStartCluster - 2) * 2

print(string.format("KERNEL.SYS starts at cluster %d (0x%04X)", kernelStartCluster, kernelStartCluster))
print(string.format("LBA = 33 + (%d-2)*2 = %d", kernelStartCluster, kernelStartLba))

-- Check LBAs from 650 to 750
print("\n=== Checking LBA range 650-750 ===")
for lba = 650, 700, 10 do
    local sector = fdc:readSector(lba)
    if sector then
        local hasData = false
        for i = 1, 64 do
            if sector[i] ~= 0 then hasData = true break end
        end
        if hasData then
            local b = {}
            for i = 1, 16 do table.insert(b, string.format("%02X", sector[i])) end
            print(string.format("LBA %d: %s", lba, table.concat(b, " ")))
        end
    end
end

-- Let's also check from where KERNEL.SYS ends up being loaded
-- KERNEL.SYS is 11MB (11635200 bytes) which is way bigger than available space

print("\n=== Available disk space ===")
local totalSectors = fdc:getTotalSectors()
print("Total sectors: " .. totalSectors)

-- What's actually in the disk image
print("\n=== Non-zero sectors in full disk ===")
local lastNonZero = 0
for lba = 0, totalSectors - 1 do
    local sector = fdc:readSector(lba)
    if sector then
        local hasData = false
        for i = 1, 512 do
            if sector[i] ~= 0 then hasData = true break end
        end
        if hasData then
            lastNonZero = lba
        end
    end
end
print("Last non-zero sector: LBA " .. lastNonZero)

-- KERNEL.SYS needs about 22750 sectors (11635200/512)
-- We only have ~2880 sectors!

print("\n=== THE REAL ISSUE ===")
print("FreeDOS boot disk image is incomplete!")
print("KERNEL.SYS needs " .. math.ceil(11635200/512) .. " sectors")
print("But floppy only has 2880 sectors!")
print("")
print("The disk image is only a BOOT SECTOR, not a complete FreeDOS installation")
print("The boot sector expects KERNEL.SYS to exist, but it's not in the image")

machine:shutdown()
print("\nDone.")