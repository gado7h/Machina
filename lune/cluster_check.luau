-- Found it! KERNEL.SYS is at cluster 0x0007!

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Found the issue! ===")

task.wait(0.5)

local fdc = machine.fdc

-- KERNEL.SYS starts at cluster 7
-- Data starts at LBA 33 (19 + 14)
-- Cluster 7 = LBA 33 + (7-2)*2 = LBA 43

print("KERNEL.SYS starts at cluster 7")
print("Data area starts at LBA 33")
print("Cluster 7 is at LBA 33 + (7-2)*2 = LBA 43")

print("\n=== LBA 43 content ===")
local lba43 = fdc:readSector(43)
if lba43 then
    local b = {}
    for i = 1, 32 do table.insert(b, string.format("%02X", lba43[i])) end
    print(table.concat(b, " "))
    
    -- Does it look like KERNEL.SYS?
    -- Usually starts with assembly header
    print("First bytes as ASCII:")
    local ascii = {}
    for i = 1, 16 do
        local ch = lba43[i]
        if ch >= 0x20 and ch < 0x7F then
            table.insert(ascii, string.char(ch))
        else
            table.insert(ascii, ".")
        end
    end
    print("  " .. table.concat(ascii))
end

-- So the issue is clear: FreeDOS boot DOES read root directory successfully
-- But it's failing to find/load KERNEL.SYS properly
-- The "4C 01 00 F0" in memory could be a combination of factors

-- The root cause of the "FreeDOS spam" is likely that:
-- 1. Boot sector loads, reads root directory successfully 
-- 2. Finds KERNEL.SYS, reads its cluster chain from FAT
-- 3. Something fails when loading KERNEL.SYS content
-- 4. Falls back to error loop printing "FreeDOS"

print("\n=== The real problem ===")
print("The boot process appears to succeed in finding KERNEL.SYS entry")
print("But something fails when trying to load the kernel from data sectors")
print("")
print("Possible issues:")
print("1. FAT chain reading is broken")
print("2. Cluster-to-LBA conversion is wrong")
print("3. Data sectors beyond sector 100 are not populated")

-- Check if there's actually kernel data at higher LBAs
print("\n=== Checking higher LBAs ===")
for lba = 30, 50 do
    local sector = fdc:readSector(lba)
    if sector then
        local hasData = false
        for i = 1, 32 do
            if sector[i] ~= 0 then hasData = true break end
        end
        if hasData then
            local b = {}
            for i = 1, 8 do table.insert(b, string.format("%02X", sector[i])) end
            print(string.format("LBA %2d: %s", lba, table.concat(b, " ")))
        end
    end
end

machine:shutdown()
print("\nDone.")