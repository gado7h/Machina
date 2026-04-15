-- The issue: need to set DL BEFORE any boot sector execution
-- Let's set DL immediately when boot stage is entered
local Runner = require("./_runner")

local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")

local intCalls = {}
local origHandle = BiosInterrupts.handleInterrupt
BiosInterrupts.handleInterrupt = function(self, cpu, vector)
    if vector == 0x13 then
        local ah = cpu:getReg8(0x10)
        local dl = cpu:getReg8(2)
        local cs = cpu.seg.CS
        local ip = cpu.ip
        
        table.insert(intCalls, {ah = ah, dl = dl, cs = cs, ip = ip})
        
        if ah == 0x02 or ah == 0x42 then
            print(string.format("*** INT13h READ: AH=%02X DL=%02X CS:IP=%04X:%04X ***",
                ah, dl, cs, ip))
        end
    end
    return origHandle(self, cpu, vector)
end

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)

-- Set DL before powering on - this should apply as initial state
-- But we can't easily modify before boot loads...

-- Instead, let's hook into when the boot sector starts executing
-- We need to intercept just after boot sector loads and runs

machine:powerOn()

local cpu = machine.cpu

-- Wait a tiny bit then check boot stage
local task = require("@src/task")
task.wait(0.05)

-- At this point the boot sector has loaded but might not have started executing much
-- Set DL to 80 right now
cpu:setReg8(2, 0x80)
print(string.format("DL set to %02X at start", cpu:getReg8(2)))

-- Now run and see what happens
for cycle = 1, 10000 do
    cpu:step()
    
    if cycle % 2000 == 0 then
        print(string.format("[%d] CS:IP=%04X:%04X DL=%02X AX=%04X", 
            cycle, cpu.seg.CS, cpu.ip, cpu:getReg8(2), cpu:getReg16(0)))
    end
end

print(string.format("\n=== INT13 calls: %d ===", #intCalls))
for i, c in ipairs(intCalls) do
    print(string.format("#%d: AH=%02X DL=%02X CS:IP=%04X:%04X",
        i, c.ah, c.dl, c.cs, c.ip))
end

print(string.format("\nFinal: CS:IP=%04X:%04X DL=%02X", cpu.seg.CS, cpu.ip, cpu:getReg8(2)))
print(string.format("Boot stage: %s", machine:getBootStage()))

machine:shutdown()
