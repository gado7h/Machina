-- Detailed code flow tracer - maps every address FreeDOS accesses

local Runner = require("./_runner")
local task = require("@src/task")

local function log(...)
    print(string.format(...))
end

-- Map boot sector address to code
local function decodeBootSector(byteOffset)
    -- Boot sector structure (from offset 0x3E after jump):
    -- 0x00-0x7C: BPB area
    -- 0x7C: JMP to 0x7E3E 
    -- At 0x3E:
    -- 0x3E: STI (enable interrupts)  
    -- 0x3F: 0xFC = CLI (wait - that was supposed to be STI!!)
    -- 0x40: XOR AX,AX
    
    local patterns = {
        [0x3E] = "STI",      -- FA
        [0x3F] = "(Operand)", -- FC  
        [0x40] = "XOR AX,AX instruction",
        [0x41] = "XOR low byte",
    }
    
    if byteOffset >= 0x3E and byteOffset <= 0x42 then
        return string.format("Offset 0x%02X: 0x%02X - %s", 
            byteOffset, 
            byteOffset,
            patterns[byteOffset] or "code")
    end
    return nil
end

log("=== Boot Sector Code Flow Map ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu
local startTime = os.clock()
local pcStats = {}

-- Run for a bit to collect stats
for i = 1, 2000 do
    local cs = cpu.seg.CS
    local ip = cpu.ip
    local linear = cs * 16 + ip
    
    -- Only track boot sector region
    if linear >= 0x1FE00 and linear < 0x20100 then
        local key = string.format("%04X:%04X", cs, ip)
        pcStats[key] = (pcStats[key] or 0) + 1
    end
    
    pcall(function() cpu:step() end)
end

log("After 2000 instructions:")
log("PC visit counts:")

local sorted = {}
for k, v in pairs(pcStats) do
    table.insert(sorted, {pc = k, count = v})
end
table.sort(sorted, function(a, b) return b.count < a.count end)

for i = 1, math.min(30, #sorted) do
    local entry = sorted[i]
    log("  %s: %d times", entry.pc, entry.count)
end

log("Final: CS:IP=%04X:%04X", cpu.seg.CS, cpu.ip)

machine:shutdown()
log("=== Done ===")