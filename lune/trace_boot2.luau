local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(0.5)

local cpu = machine.cpu
local steps = 0

while steps < 3000 do
    cpu:step()
    steps = steps + 1
    
    -- Show when in boot sector and near disk I/O area
    if cpu.seg.CS == 0x1FE0 and steps > 100 then
        if cpu.ip >= 0x170 and cpu.ip <= 0x200 then
            print(string.format("[%d] IP=%04X AX=%04X DX=%04X", steps, cpu.ip, cpu:getReg16(0), cpu:getReg16(3)))
        end
    end
    
    if steps > 2000 and cpu.seg.CS ~= 0x1FE0 then
        print(string.format("[%d] LEFT boot sector to %04X:%04X", steps, cpu.seg.CS, cpu.ip))
        break
    end
end

print(string.format("Final: steps=%d CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))

machine:shutdown()