-- Check memory contents at various locations

local Runner = require("./_runner")
local task = require("@src/task")

local function log(...)
    print(string.format(...))
end

log("=== Memory Check ===")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()
task.wait(0.3)

local cpu = machine.cpu

-- Check original boot sector location
log("Original at 0x7C00:")
for i = 0, 5 do
    log("  offset %02X: %02X", i, cpu:readPhysical8(0x7C00 + i))
end

-- Check relocated segment
log("Relocated at 0x1FE0:7C00 (0x27C00):")
for i = 0, 5 do
    log("  offset %02X: %02X", i, cpu:readPhysical8(0x27C00 + i))
end

-- Check at the code areaFreeDOS reads
log("Code at 0x7C00+0x3E (STI area):")
for i = 0x3E, 0x42 do
    log("  offset %02X: %02X", i, cpu:readPhysical8(0x7C00 + i))
end

log("=== Done ===")
machine:shutdown()