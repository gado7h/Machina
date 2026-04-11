-- Ultra-deep FreeDOS tracer - tracks EVERY instruction

local Runner = require("./_runner")
local task = require("@src/task")

local function log(...)
    print(string.format(...))
end

log("=== Ultra-Deep FreeDOS Trace ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu
local startTime = os.clock()
local iterations = 0
local lastReport = 0

-- Manually step and track
while os.clock() - startTime < 3 and iterations < 50000 do
    iterations = iterations + 1
    
    local cs = cpu.seg.CS
    local ip = cpu.ip
    
    -- Check if stuck
    if iterations == 1 then
        log("First: CS:IP=%04X:%04X", cs, ip)
    elseif iterations == 2 then
        log("Second: CS:IP=%04X:%04X", cs, ip)
    elseif iterations == 3 then
        log("Third: CS:IP=%04X:%04X", cs, ip)
    elseif iterations == 10 then
        log("10th: CS:IP=%04X:%04X", cs, ip)
    elseif iterations == 100 then
        log("100th: CS:IP=%04X:%04X AX=%04X", cs, ip, cpu:getReg16(0))
    elseif iterations == 1000 then
        log("1000th: CS:IP=%04X:%04X", cs, ip)
    end
    
    -- Try stepping
    local ok, result = pcall(function() return cpu:step() end)
    if not ok then
        log("FAULT at %d: %s", iterations, result)
        break
    end
    
    local elapsed = os.clock() - startTime
    if elapsed > lastReport + 0.5 and iterations > 10 then
        log("Progress: iter=%d CS:IP=%04X:%04X", iterations, cs, ip)
        lastReport = elapsed
    end
    
    -- Check for halt
    if result == "HLT" then
        log("*** HALTED at iteration %d ***", iterations)
        break
    end
end

log("=== Summary ===")
log("Iterations: %d", iterations)
log("Final: CS:IP=%04X:%04X AX=%04X BX=%04X SP=%04X SS=%04X",
    cpu.seg.CS, cpu.ip, 
    cpu:getReg16(0), cpu:getReg16(1),
    cpu:getReg16(4), cpu.seg.SS)
log("Flags: %04X", cpu.flags)

machine:shutdown()
log("=== Done ===")