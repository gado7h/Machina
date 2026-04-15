-- Detailed trace of boot with register monitoring
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(0.1)

local cpu = machine.cpu

-- Monitor execution - trace AH changes from the beginning
local last_ah = 0xFF
local steps = 0

while steps < 5000 do
    cpu:step()
    steps = steps + 1
    
    -- Track AH register changes - shows what INT service is being set up
    local ah = cpu:getReg8(0x10)
    if ah ~= last_ah then
        if ah == 0x02 or ah == 0x03 or ah == 0x00 or ah == 0x01 or ah == 0x41 then
            print(string.format("[%d] AH=%02X (service %s) CX=%04X DX=%04X ES=%04X IP=%04X", 
                steps, ah, 
                ({[0x00]="reset",[0x01]="status",[0x02]="read",[0x03]="write",[0x41]="check"})[ah] or "other",
                cpu:getReg16(2), cpu:getReg16(3), cpu.seg.ES, cpu.ip))
        end
        last_ah = ah
    end
end

print(string.format("\nFinal: steps=%d CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))

machine:shutdown()