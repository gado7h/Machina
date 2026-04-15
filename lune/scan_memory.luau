-- Check if kernel actually loads somewhere
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

-- Wait longer
task.wait(5.0)

local cpu = machine.cpu
local fdc = machine.fdc

print("=== After 5 seconds ===")
print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))

-- Scan memory for loaded content
print("\n=== Scanning memory for non-zero data ===")

-- Check common kernel load locations
local locations = {0x10000, 0x20000, 0x30000, 0x40000, 0x50000, 0x60000, 0x70000}
for _, addr in ipairs(locations) do
    local first = cpu:readPhysical8(addr)
    if first ~= 0 then
        print(string.format("0x%X: first byte = %02X", addr, first))
    end
end

-- Check extended memory
print("\n=== Extended memory at 0x80000 ===")
for i = 0, 31 do
    local b = cpu:readPhysical8(0x80000 + i)
    io.write(string.format("%02X ", b))
end
print()

machine:shutdown()