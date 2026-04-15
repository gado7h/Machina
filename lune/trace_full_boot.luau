-- Full trace of boot execution to find where it fails
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

local cpu = machine.cpu

-- Step 1: Let BIOS load boot sector (INT 13h)
task.wait(0.1)

print("=== Phase 1: Boot sector loaded ===")
print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))

-- Check what's at 0x7C00 (original load location)
local at7c00 = {}
for i = 0, 15 do
    at7c00[i+1] = string.format("%02X", cpu:readPhysical8(0x7C00 + i))
end
print("0x7C00: " .. table.concat(at7c00, " "))

-- Step 2: Run a bit to let boot sector execute
local steps = 0
while steps < 200 do
    cpu:step()
    steps = steps + 1
end

print(string.format("\n=== Phase 2: After 200 steps ==="))
print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))

-- Step 3: Continue to see where boot goes
steps = 0
while steps < 3000 do
    cpu:step()
    steps = steps + 1
    
    -- Show any disk activity
    if cpu.seg.CS == 0x1FE0 and cpu.ip > 0x7C90 and cpu.ip < 0x7D00 then
        print(string.format("[step %d] IP = %04X (disk read area?)", steps, cpu.ip))
    end
end

print(string.format("\n=== Final: %d steps ===", steps))
print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))

machine:shutdown()