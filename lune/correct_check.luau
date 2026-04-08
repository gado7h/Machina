-- Correctly check what's in the FDC

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FDC Correct Check ===")

task.wait(0.5)

local cpu = machine.cpu
local fdc = machine.fdc

-- Use readSector properly
print("\n=== Using readSector() ===")

local lba0 = fdc:readSector(0)
print("LBA 0:")
if lba0 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", lba0[i])) end
    print("  " .. table.concat(b, " "))
end

local lba1 = fdc:readSector(1)
print("\nLBA 1:")
if lba1 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", lba1[i])) end
    print("  " .. table.concat(b, " "))
end

local lba19 = fdc:readSector(19)
print("\nLBA 19:")
if lba19 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", lba19[i])) end
    print("  " .. table.concat(b, " "))
end

-- Now check CPU memory
print("\n=== CPU Memory at 0x200 ===")
local memBytes = {}
for i = 0, 15 do
    memBytes[i+1] = cpu:readPhysical8(0x200 + i)
end
local memStr = {}
for i = 1, 16 do table.insert(memStr, string.format("%02X", memBytes[i])) end
print(table.concat(memStr, " "))

-- Compare
print("\n=== Comparison ===")
local function bytesMatch(data1, data2)
    for i = 1, math.min(#data1, #data2, 16) do
        if data1[i] ~= data2[i] then return false end
    end
    return true
end

print("Memory matches LBA 0: " .. tostring(bytesMatch(memBytes, lba0)))
print("Memory matches LBA 1: " .. tostring(bytesMatch(memBytes, lba1)))
print("Memory matches LBA 19: " .. tostring(bytesMatch(memBytes, lba19)))

-- Hmm, 0x4C 0x01 is interesting - it's the first two bytes of KERNEL.SYS entry in root dir!
-- Let me check root dir at LBA 19 more carefully

print("\n=== Looking at LBA 19 for KERNEL.SYS ===")
for entry = 0, 10 do
    local offset = entry * 32 + 1
    local name = ""
    for i = 0, 7 do
        local ch = lba19[offset + i]
        if ch and ch >= 0x20 then name = name .. string.char(ch) end
    end
    local ext = ""
    for i = 8, 10 do
        local ch = lba19[offset + i]
        if ch and ch >= 0x20 then ext = ext .. string.char(ch) end
    end
    if name ~= "" and name ~= "FREEDOS" then
        print(string.format("Entry %d: %s.%s", entry, name, ext))
    end
end

machine:shutdown()
print("\nDone.")