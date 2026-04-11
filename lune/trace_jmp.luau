-- Check the JMP instruction and target

local Runner = require("./_runner")
local task = require("@src/task")

local function log(...)
    print(string.format(...))
end

log("=== JMP Check ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu

-- First check memory at jump location
-- The far jump is at original boot sector: 0x7C00 + offset after jump
-- From our earlier analysis: jump instruction at 0x7C03-0x7C07
-- EA 5E 7C E0 1F = JMP 0x1FE0:0x7C5E

log("Check original boot sector jump:")
for i = 0x7C03, 0x7C07 do
    log("  [0x%04X] = 0x%02X", i, cpu:readPhysical8(i))
end

-- After loading, check where the jump points to
log("\nWhere does the jump go?")
local jump_offset_lo = cpu:readPhysical8(0x7C04)
local jump_offset_hi = cpu:readPhysical8(0x7C05)
local jump_seg_lo = cpu:readPhysical8(0x7C06)
local jump_seg_hi = cpu:readPhysical8(0x7C07)
log("JMP opcode: 0x%02X", cpu:readPhysical8(0x7C03))
log("Offset: %02X%02X = 0x%04X", jump_offset_hi, jump_offset_lo, jump_offset_lo * 256 + jump_offset_hi)
log("Segment: %02X%02X = 0x%04X", jump_seg_hi, jump_seg_lo, jump_seg_lo * 256 + jump_seg_hi)

-- Now check if there's valid code at jump target
local target_seg = jump_seg_lo * 256 + jump_seg_hi
local target_off = jump_offset_lo * 256 + jump_offset_hi
local target_linear = target_seg * 16 + target_off

log("\nCode at target (0x%04X:0x%04X = 0x%05X):", target_seg, target_off, target_linear)
for i = 0, 5 do
    local byte = cpu:readPhysical8(target_linear + i)
    log("  [%02X] = 0x%02X", i, byte)
end

log("=== Done ===")
machine:shutdown()