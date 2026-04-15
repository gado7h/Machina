-- Instrument CPU step to detect INT execution
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(0.1)

local cpu = machine.cpu

-- Patch step to detect INT instructions
local oldStep = cpu.step
cpu.step = function(self)
    -- Check if about to execute INT
    local opcode = self:_currentOpcode and self:_currentOpcode() or 0
    
    if opcode == 0xCD then  -- INT instruction
        local vector = self:readPhysical8(self:getLinearPC() + 1)
        print(string.format("[INT DETECTED] vector=%02X AH=%02X", vector, self:getReg8(0x10)))
    end
    
    return oldStep(self)
end

local steps = 0
while steps < 5000 do
    cpu:step()
    steps = steps + 1
    
    if steps > 200 and steps % 1000 == 0 then
        print(string.format("[%d] CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))
    end
end

print(string.format("\nFinal: steps=%d CS:IP=%04X:%04X", steps, cpu.seg.CS, cpu.ip))

machine:shutdown()