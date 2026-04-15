local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

local steps = 0
local cpu = machine.cpu
local last_ip = 0

-- Track only the boot sector runs
task.wait(0.1)  -- Let it start

while steps < 5000 do
    cpu:step()
    steps = steps + 1
    
    -- Only show when in boot sector (CS = 1FE0)
    if cpu.seg.CS == 0x1FE0 and cpu.ip ~= last_ip then
        if cpu.ip == 0x0000 or cpu.ip == 0x0040 then
            print(string.format("[%d] -> ENTRY points", steps))
        end
        last_ip = cpu.ip
    end
    
    if steps > 3000 and cpu.seg.CS ~= 0x1FE0 then
        print(string.format("[%d] LEFT boot sector to CS=%04X", steps, cpu.seg.CS))
        break
    end
end

print(string.format("Final: steps=%d CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))

machine:shutdown()