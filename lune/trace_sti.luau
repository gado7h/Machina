-- Trace flag values around STI instruction

local Runner = require("./_runner")
local task = require("@src/task")

local FLAG_IF = 0x0200

local function log(...)
    print(string.format(...))
end

log("=== STI Flag Trace ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu

-- First execute until we get to STI
for i = 1, 50 do
    local cs = cpu.seg.CS
    local ip = cpu.ip
    local flags = cpu.flags
    
    -- Print when at or near 0x7B7F where STI is
    if cs == 0x1FE0 and ip >= 0x7B7F and ip <= 0x7B82 then
        local if_set = bit32.band(flags, FLAG_IF) ~= 0
        log("i=%d IP=%04X FLAGS=%04X IF=%d", i, ip, flags, if_set and 1 or 0)
    end
    
    cpu:step()
end

log("=== After 50 steps ===")
log("Final: CS:IP=%04X:%04X FLAGS=%04X", 
    cpu.seg.CS, cpu.ip, cpu.flags)
log("IF bit value: %d", bit32.band(cpu.flags, FLAG_IF))

machine:shutdown()