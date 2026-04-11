-- Where is FreeDOS actually running from?

local Runner = require("./_runner")
local task = require("@src/task")

local function log(...)
    print(string.format(...))
end

log("=== Execution Source Check ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu

-- Step a few times
for i = 1, 15 do
    local cs = cpu.seg.CS
    local ip = cpu.ip
    local linear = cs * 16 + ip
    
    log("Step %d: CS:IP=%04X:%04X -> linear=0x%05X", i, cs, ip, linear)
    
    -- Check what's at this memory location
    local opcode = cpu:readPhysical8(linear)
    log("  Memory at %04X:%04X = 0x%02X", cs, ip, opcode)
    
    cpu:step()
end

log("=== Done ===")
machine:shutdown()