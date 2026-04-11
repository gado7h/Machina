-- Deep FreeDOS Debug Trace
-- Traces each INT call and memory access

local Runner = require("./_runner")
local task = require("@src/task")

local function log(...)
    print(string.format(...))
end

log("=== Deep FreeDOS Debug Trace ===")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
        TRACE = {
            ENABLED = true,
            DISK = true,
            CPU_STATE = true,
            BIOS_CALLS = true,
        },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.5)

log("=== Running for 5 seconds ===")

local startTime = os.clock()
local lastPC = nil
local int13Count = 0
local lastLogTime = startTime

while os.clock() - startTime < 5 do
    task.wait(0.05)
    local elapsed = os.clock() - startTime
    local cpu = machine.cpu
    
    if cpu then
        local pc = cpu:getLinearPC()
        local cs = cpu.seg.CS
        local ip = cpu.ip
        
        -- Track unique PC positions
        if pc ~= lastPC then
            lastPC = pc
            
            -- Log every PC change to see the execution flow
            if math.floor(elapsed * 10) % 5 == 0 then
                log("[t=%.2f] PC=%04X:%04X (0x%05X) AX=%04X", 
                    elapsed, cs, ip, pc, cpu:getReg16(0))
            end
        end
        
        -- Check for specific trigger points
        if ip >= 0x7B90 and ip <= 0x7BB0 then
            log("*** Near stuck point: CS:IP=%04X:%04X", cs, ip)
        end
    end
    
    -- Check bus logs for INT 13h
    if machine.bus and machine.bus._logs then
        for _, entry in ipairs(machine.bus._logs) do
            if entry:match("INT") and not entry:match("INT%d") then
                int13Count = int13Count + 1
                if int13Count <= 5 then
                    log("INT LOG: %s", entry)
                end
            end
        end
    end
    
    if elapsed > 3 and math.floor(elapsed) > math.floor(lastLogTime) then
        log("--- t=%.2f: cycles=%d ---", elapsed, cpu and cpu.stats.cycles or 0)
        lastLogTime = elapsed
    end
end

log("=== Final State ===")
log("CPU: CS:IP=%04X:%04X AX=%04X", 
    machine.cpu.seg.CS, machine.cpu.ip, machine.cpu:getReg16(0))

if machine.bus and machine.bus._logs then
    log("=== All bus logs (%d) ===", #machine.bus._logs)
    local diskLogs = {}
    for i, entry in ipairs(machine.bus._logs) do
        if entry:match("DISK") or entry:match("INT 13") or entry:match("INT1") then
            table.insert(diskLogs, entry)
        end
    end
    log("Disk/INT logs: %d", #diskLogs)
    for _, entry in ipairs(diskLogs) do
        log("  %s", entry)
    end
end

machine:shutdown()
log("=== Done ===")