-- Manually invoke boot process and trace 
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

-- Wait for boot sector to load
task.wait(0.2)

local cpu = machine.cpu
print(string.format("Initial: CS:IP=%04X:%04X", cpu.seg.CS, cpu.ip))

-- Run for a while
for i = 1, 5000 do
    cpu:step()
end

print(string.format("After 5000 steps: CS:IP=%04X:%04X", cpu.seg.CS, cpu.ip))

-- Check if any data read
print("\n=== Memory ===")

-- Check boot sector copy
local copy = {}
for i = 0, 15 do
    copy[i+1] = string.format("%02X", cpu:readPhysical8(0x1FE00 + i))
end
print("Copy at 1FE0: " .. table.concat(copy, " "))

-- Check root directory area at typical location
local rd = {}
for i = 0, 15 do
    rd[i+1] = string.format("%02X", cpu:readPhysical8(0x20000 + i))
end
print("At 20000: " .. table.concat(rd, " "))

machine:shutdown()