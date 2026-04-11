-- Wide region trace - see where CPU actually goes

local Runner = require("./_runner")
local task = require("@src/task")

local function log(...)
    print(string.format(...))
end

log("=== Wide Region Trace ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu

-- First few instructions manually
for i = 1, 20 do
    local cs = cpu.seg.CS
    local ip = cpu.ip
    local linear = cs * 16 + ip
    log("Step %d: CS:IP=%04X:%04X (0x%05X) AX=%04X", 
        i, cs, ip, linear, cpu:getReg16(0))
    cpu:step()
end

log("=== Now running automatically ===")

local startTime = os.clock()
local iterations = 0
local maxIter = 10000

while iterations < maxIter and os.clock() - startTime < 3 do
    iterations = iterations + 1
    cpu:step()
end

log("Ran %d instructions total", iterations)
log("Final: CS:IP=%04X:%04X (0x%05X)", 
    cpu.seg.CS, cpu.ip, cpu.seg.CS * 16 + cpu.ip)
log("AX=%04X BX=%04X CX=%04X DX=%04X", 
    cpu:getReg16(0), cpu:getReg16(1), cpu:getReg16(2), cpu:getReg16(3))
log("SP=%04X SS=%04X FLAGS=%04X", 
    cpu:getReg16(4), cpu.seg.SS, cpu.flags)

machine:shutdown()