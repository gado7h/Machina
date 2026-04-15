-- Trace exact boot flow
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

-- Wait for boot to start (INT 13h to load boot sector)
task.wait(0.05)

local cpu = machine.cpu
local steps = 0

print("=== Starting trace ===")
print(string.format("Initial: CS:IP=%04X:%04X", cpu.seg.CS, cpu.ip))

-- Step one at a time to see exact flow
while steps < 200 do
    local old_cs = cpu.seg.CS
    local old_ip = cpu.ip
    cpu:step()
    steps = steps + 1
    
    if cpu.seg.CS ~= old_cs or cpu.ip ~= old_ip then
        print(string.format("[%d] %04X:%04X -> %04X:%04X", 
            steps, old_cs, old_ip, cpu.seg.CS, cpu.ip))
    end
end

print(string.format("\n=== After 200 steps ==="))
print(string.format("Final: CS:IP=%04X:%04X", cpu.seg.CS, cpu.ip))

machine:shutdown()