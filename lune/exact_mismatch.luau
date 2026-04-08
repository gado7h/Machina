-- Deep analysis: what's the exact mismatch

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Exact Mismatch Analysis ===")

-- Wait for boot to run
task.wait(1)

local cpu = machine.cpu
local fdc = machine.fdc

-- Check if boot sector code uses INT 13h
print("\n=== Checking boot sector for INT 13 ===")
local foundInt13 = false
for ip = 0, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xCD then
        local nextB = cpu:readMem8(0x1FE0, ip + 1)
        if nextB == 0x13 then
            print(string.format("Found INT 13 at 0x1FE0:%04X", ip))
            foundInt13 = true
        end
    end
end

-- Check memory at 0x0000:0200
print("\n=== Memory at 0x0000:0200 ===")
local bytes1 = {}
for i = 0, 15 do
    local v = cpu:readPhysical8(0x200 + i)
    table.insert(bytes1, string.format("%02X", v))
end
print(table.concat(bytes1, " "))

-- Check what sectors have data
print("\n=== Non-zero sectors ===")
for lba = 0, 35 do
    local sector = fdc:readSector(lba)
    if sector then
        local nonZero = false
        for i = 1, 32 do
            if sector[i] ~= 0 then nonZero = true break end
        end
        if nonZero then
            local b = {}
            for i = 1, 8 do table.insert(b, string.format("%02X", sector[i])) end
            print(string.format("LBA %2d: %s", lba, table.concat(b, " ")))
        end
    end
end

-- Compare memory with sectors
print("\n=== Matching memory to sectors ===")
local memAt200 = {}
for i = 1, 8 do
    memAt200[i] = cpu:readPhysical8(0x200 + i - 1)
end

for lba = 0, 35 do
    local sector = fdc:readSector(lba)
    if sector then
        local match = true
        for i = 1, 8 do
            if sector[i] ~= memAt200[i] then match = false break end
        end
        if match then
            print("MATCH FOUND AT LBA " .. lba .. "!")
        end
    end
end

-- Let's check sector 11 (as per earlier analysis)
print("\n=== What is at sector 11? ===")
local sector11 = fdc:readSector(11)
if sector11 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", sector11[i])) end
    print(table.concat(b, " "))
end

machine:shutdown()
print("\nDone.")