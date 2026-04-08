-- Direct check of what's being read

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Direct Read Check ===")

task.wait(0.5)

local cpu = machine.cpu
local fdc = machine.fdc

-- After boot has run, check memory at 0x200
print("\n=== Memory at 0x200 after boot ===")
local b = {}
for i = 0, 15 do
    table.insert(b, string.format("%02X", cpu:readPhysical8(0x200 + i)))
end
print(table.concat(b, " "))

-- What is actually at the first few LBA addresses in the FDC?
print("\n=== LBA 0 (sector 1 in FDC array) ===")
local lba0 = fdc._sectors[1]  -- 1-indexed
if lba0 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", lba0[i] or 0)) end
    print(table.concat(b, " "))
end

print("\n=== LBA 1 (sector 2 in FDC array) ===")
local lba1 = fdc._sectors[2]
if lba1 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", lba1[i] or 0)) end
    print(table.concat(b, " "))
end

print("\n=== LBA 19 (sector 20 in FDC array) ===")
local lba19 = fdc._sectors[20]
if lba19 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", lba19[i] or 0)) end
    print(table.concat(b, " "))
end

-- Check if memory matches any of these
print("\n=== Memory comparison ===")
local memBytes = {}
for i = 0, 15 do
    memBytes[i+1] = cpu:readPhysical8(0x200 + i)
end

print("Memory at 0x200:")
local memStr = {}
for i = 1, 16 do table.insert(memStr, string.format("%02X", memBytes[i])) end
print("  " .. table.concat(memStr, " "))

print("\nCompare to LBA 0:")
local lba0str = {}
for i = 1, 16 do table.insert(lba0str, string.format("%02X", lba0[i])) end
print("  " .. table.concat(lba0str, " "))

print("\nCompare to LBA 1:")
local lba1str = {}
for i = 1, 16 do table.insert(lba1str, string.format("%02X", lba1[i])) end
print("  " .. table.concat(lba1str, " "))

print("\nCompare to LBA 19:")
local lba19str = {}
for i = 1, 16 do table.insert(lba19str, string.format("%02X", lba19[i])) end
print("  " .. table.concat(lba19str, " "))

-- Check if maybe it's reading at a different offset
-- Let's see if memory matches any 512-byte chunk starting at any position
print("\n=== Searching for memory pattern in FDC ===")
local found = false
for i = 1, math.min(100, #fdc._sectors - 16) do
    local match = true
    for j = 1, 8 do
        if fdc._sectors[i + j - 1] ~= memBytes[j] then
            match = false
            break
        end
    end
    if match then
        print(string.format("Found match at offset %d (LBA %d)", i - 1, math.floor((i - 1) / 512)))
        found = true
        break
    end
end
if not found then
    print("No match found in first 100 bytes!")
end

machine:shutdown()
print("\nDone.")