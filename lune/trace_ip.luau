local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

local steps = 0
local cpu = machine.cpu
local last_cs = 0
local last_ip = 0

-- Step but track CS:IP changes
while steps < 10000 do
    local result = cpu:step()
    steps = steps + 1
    
    if cpu.seg.CS ~= last_cs or cpu.ip ~= last_ip then
        if steps > 100 then
            print(string.format("[%d] CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))
        end
        last_cs = cpu.seg.CS
        last_ip = cpu.ip
    end
    
    if cpu.halted then
        print("HALTED!")
        break
    end
end

print(string.format("\nFinal: steps=%d CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))

machine:shutdown()