-- Let boot sector run from original location without redirect
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

-- Don't redirect - let boot sector work naturally
local cpu = machine.cpu
cpu._pendingRedirect = nil

local steps = 0
while steps < 2000 do
    cpu:step()
    steps = steps + 1
    if steps > 100 and cpu.seg.CS == 0x1FE0 and cpu.ip ~= last_ip then
        last_ip = cpu.ip
    end
end

print(string.format("After 2000 steps: CS:IP=%04X:%04X", cpu.seg.CS, cpu.ip))

machine:shutdown()