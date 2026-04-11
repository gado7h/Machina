-- Ultra-detailed trace around STI

local Runner = require("./_runner")
local task = require("@src/task")

local FLAG_IF = 0x0200

local function log(...)
    print(string.format(...))
end

log("=== Ultra-detailed around STI ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu

-- Look at memory at 0x1FE0:7B7F to see what's actually there
log("Memory at 0x1FE0:7B7F = 0x%02X", cpu:readPhysical8(0x1FE0 * 16 + 0x7B7F))

-- Step and check around the STI
for i = 1, 20 do
    local cs = cpu.seg.CS
    local ip = cpu.ip
    local flags_before = cpu.flags
    local if_before = bit32.band(flags_before, FLAG_IF)
    
    -- Step the CPU
    cpu:step()
    
    local flags_after = cpu.flags
    local if_after = bit32.band(flags_after, FLAG_IF)
    
    -- Check any IP in our region
    if cs == 0x1FE0 then
        if (if_before ~= if_after) or (ip >= 0x7B7F and ip <= 0x7B85) then
            log("Step %d: %04X:%04X IF: %d->%d (FLAGS: %04X->%04X)", 
                i, cs, ip, if_before, if_after, flags_before, flags_after)
        end
    end
end

log("Final: CS:IP=%04X:%04X FLAGS=%04X", cpu.seg.CS, cpu.ip, cpu.flags)

machine:shutdown()