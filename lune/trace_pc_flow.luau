-- Deep FreeDOS Execution Tracer
-- Finds exactly where FreeDOS loops by tracing PC and memory accesses

local Runner = require("./_runner")
local task = require("@src/task")

local BOOT_SEG = 0x1FE0
local BOOT_LINEAR = BOOT_SEG * 16
local BOOT_END = BOOT_LINEAR + 0x200

local function log(...)
    print(string.format(...))
end

log("=== Deep FreeDOS Execution Trace ===")
log("Boot sector range: 0x%05X - 0x%05X", BOOT_LINEAR, BOOT_END)

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu
local prevIP = nil
local ipChanges = {}
local uniquePCs = {}
local memoryWrites = {}
local memoryReads = {}

log("=== Running for 5 seconds ===")
local startTime = os.clock()
local lastReport = startTime

while os.clock() - startTime < 5 do
    task.wait(0.02)
    local elapsed = os.clock() - startTime
    
    if cpu then
        local cs = cpu.seg.CS
        local ip = cpu.ip
        local linear = cs * 16 + ip
        
        -- Track unique PC positions in the boot sector area
        if linear >= 0x1FE00 and linear < 0x20000 then
            local key = string.format("%04X:%04X", cs, ip)
            if not uniquePCs[key] then
                uniquePCs[key] = { count = 1, first = elapsed }
            else
                uniquePCs[key].count = uniquePCs[key].count + 1
            end
        end
        
        -- Track IP changes for flow analysis
        if ip ~= prevIP then
            local key = string.format("%04X:%04X", cs, ip)
            if not ipChanges[key] then
                ipChanges[key] = 1
            else
                ipChanges[key] = ipChanges[key] + 1
            end
            prevIP = ip
        end
    end
    
    if elapsed > lastReport + 1 then
        log("--- t=%.2f: %d unique boot pcs, %d total changes ---", 
            elapsed, 
            pairs.uniquePCs and 0 or 0,
            ipChanges and 0 or 0)
        lastReport = elapsed
    end
end

log("=== Summary after 5s ===")

log("--- Unique PC positions in boot sector (0x1FE00-0x20000) ---")
local sortedPCs = {}
for k, v in pairs(uniquePCs) do
    table.insert(sortedPCs, {pc = k, count = v.count, first = v.first})
end
table.sort(sortedPCs, function(a, b) return a.first < b.first end)

for i, entry in ipairs(sortedPCs) do
    log("  [%d] PC=%s visits=%d first=%.2f", i, entry.pc, entry.count, entry.first)
end

log("--- IP change pattern (flow) ---")
local sortedChanges = {}
for k, v in pairs(ipChanges) do
    table.insert(sortedChanges, {pc = k, count = v})
end
table.sort(sortedChanges, function(a, b) return b.count < a.count end)

for i = 1, math.min(20, #sortedChanges) do
    local entry = sortedChanges[i]
    log("  [%d] PC=%s changes=%d", i, entry.pc, entry.count)
end

log("=== Final CPU State ===")
log("CS:IP=%04X:%04X AX=%04X SP=%04X SS=%04X FLAGS=%04X",
    cpu.seg.CS, cpu.ip, cpu:getReg16(0), cpu:getReg16(4), cpu.seg.SS, cpu.flags)

log("=== Done ===")
machine:shutdown()