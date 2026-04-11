-- Unified BIOS Boot Tracer
-- Traces ALL BIOS interrupts during FreeDOS boot for 30 seconds

local Runner = require("./_runner")
local task = require("@src/task")

local function getTimestamp()
    local t = os.date("*t")
    return string.format("%02d:%02d.%06d", t.min, t.sec, math.floor((os.clock() % 1) * 1000000))
end

local function getScreenText(machine)
    if not machine.gpu.getTextModeBuffer then return "" end
    local buf = machine.gpu:getTextModeBuffer()
    if not buf then return "" end
    local lines = {}
    for row = 0, 4 do
        local line = ""
        for col = 0, 79 do
            local idx = row * 80 + col
            local char = buf[idx * 2 + 1]
            if char and char > 0 and char < 256 then
                line = line .. string.char(char)
            else
                line = line .. " "
            end
        end
        if line:match("%S") then
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

local function log(...)
    local ts = getTimestamp()
    print(string.format("[%s] %s", ts, string.format(...)))
end

log("=== FreeDOS Comprehensive Boot Trace ===")
log("Runtime: 30 seconds")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
        TRACE = {
            ENABLED = true,
            DISK = true,
            CPU_STATE = true,
            BIOS_CALLS = true,
            IRQ_ROUTING = true,
            PORT_IO = true,
        },
    },
})

machine:setFramePresenter(function() end)

log("=== Powering on ===")
machine:powerOn()

task.wait(0.5)

log("=== Waiting for boot (30s runtime) ===")

local startTime = os.clock()
local lastStage = "OFF"
local lastScreen = ""

while os.clock() - startTime < 30 do
    task.wait(0.05)
    
    local stage = machine:getBootRecord().bootStage or "?"
    local elapsed = os.clock() - startTime
    
    if stage ~= lastStage then
        log("BOOT-STAGE: %s -> %s (t=%.2f)", lastStage, stage, elapsed)
        lastStage = stage
    end
    
    local screen = getScreenText(machine)
    if screen ~= lastScreen then
        if screen:match("%S") and screen ~= lastScreen then
            log("SCREEN-CHANGE: t=%.2f [%s]", elapsed, stage)
            for line in screen:gmatch("[^\n]+") do
                if line:match("%S") then
                    log("  > %s", line:sub(1, 80))
                end
            end
        end
        lastScreen = screen
    end
    
    if stage == "FAULT" then
        log("!!! FAULT !!!")
        break
    end
    
    if stage == "RUNNING" then
        local cpu = machine.cpu
        if cpu then
            local pc = cpu:getLinearPC()
            log("RUNNING: PC=0x%05X CS:IP=%04X:%04X", pc, cpu.seg.CS, cpu.ip)
        end
    end
    
    if elapsed > 5 and elapsed < 25 and math.floor(elapsed * 10) % 50 == 0 then
        log("STILL-RUNNING: t=%.2f stage=%s", elapsed, stage)
    end
end

local elapsed = os.clock() - startTime
log("=== Trace complete after %.2f seconds ===", elapsed)

if machine.bus and machine.bus._logs then
    log("=== Bus logs (%d entries) ===", #machine.bus._logs)
    for i, entry in ipairs(machine.bus._logs) do
        if i <= 100 then
            log("  [%d] %s", i, entry)
        end
    end
    if #machine.bus._logs > 100 then
        log("  ... and %d more", #machine.bus._logs - 100)
    end
end

log("=== Final state ===")
log("Boot stage: %s", machine:getBootRecord().bootStage or "?")
if machine.cpu then
    local cpu = machine.cpu
    log("CPU: CS:IP=%04X:%04X AX=%04X BX=%04X SP=%04X SS=%04X", 
        cpu.seg.CS, cpu.ip, 
        cpu:getReg16(0), cpu:getReg16(1),
        cpu:getReg16(4), cpu.seg.SS)
    log("CPU stats: cycles=%d instructions=%d",
        cpu.stats.cycles, cpu.stats.instructions)
end

log("=== Done ===")

machine:shutdown()