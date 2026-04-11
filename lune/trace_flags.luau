-- CPU State Tracer with Flag tracking

local Runner = require("./_runner")
local task = require("@src/task")

local FLAG_CF = 0x0001
local FLAG_PF = 0x0004
local FLAG_AF = 0x0010
local FLAG_ZF = 0x0040
local FLAG_SF = 0x0080
local FLAG_TF = 0x0100
local FLAG_IF = 0x0200
local FLAG_DF = 0x0400
local FLAG_OF = 0x0800

local function log(...)
    print(string.format(...))
end

log("=== CPU State with Flags ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu
local jumps = {}

for i = 1, 30 do
    local cs = cpu.seg.CS
    local ip = cpu.ip
    local linear = cs * 16 + ip
    local flags = cpu.flags
    
    local cf = bit32.band(flags, FLAG_CF) ~= 0
    local zf = bit32.band(flags, FLAG_ZF) ~= 0
    local sf = bit32.band(flags, FLAG_SF) ~= 0
    local pf = bit32.band(flags, FLAG_PF) ~= 0
    local af = bit32.band(flags, FLAG_AF) ~= 0
    local of = bit32.band(flags, FLAG_OF) ~= 0
    local iff = bit32.band(flags, FLAG_IF) ~= 0
    local df = bit32.band(flags, FLAG_DF) ~= 0
    
    log("Step %d: CS:IP=%04X:%04X FLAGS=%04X CF=%d ZF=%d SF=%d PF=%d AF=%d OF=%d IF=%d DF=%d",
        i, cs, ip, flags,
        cf and 1 or 0, zf and 1 or 0, sf and 1 or 0, pf and 1 or 0, af and 1 or 0, of and 1 or 0, iff and 1 or 0, df and 1 or 0)
    
    cpu:step()
end

log("=== Done ===")
machine:shutdown()