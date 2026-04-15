-- Trace boot without redirect
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

local cpu = machine.cpu

-- Step and track where we go
local last_ip = 0
local steps = 0

while steps < 6000 and not cpu.halted do
    cpu:step()
    steps = steps + 1
    
    -- Show transition points
    if cpu.seg.CS ~= 0xF000 or last_ip == 0 then
        if cpu.seg.CS == 0x1FE0 or (cpu.seg.CS ~= last_ip and steps < 300) then
            print(string.format("[%d] CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))
        end
    end
    last_ip = cpu.seg.CS
end

print(string.format("\nFinal: steps=%d CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))

machine:shutdown()