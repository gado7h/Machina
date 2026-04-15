-- Check VRAM before and after boot
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(0.1)

local bus = machine.bus
local vga = bus._vga

print("=== VRAM Initial ===")
for row = 0, 2 do
    local chars = {}
    for col = 0, 39 do
        local ch = vga._textBuffer and vga._textBuffer[row * 80 + col] or 0
        if ch >= 32 then chars[col+1] = string.char(ch) else chars[col+1] = "." end
    end
    print(string.format("Row %d: %s", row, table.concat(chars)))
end

-- Wait for boot to run
task.wait(3.0)

print("\n=== VRAM After 3 seconds ===")
for row = 0, 2 do
    local chars = {}
    for col = 0, 39 do
        local ch = vga._textBuffer and vga._textBuffer[row * 80 + col] or 0
        if ch >= 32 then chars[col+1] = string.char(ch) else chars[col+1] = "." end
    end
    print(string.format("Row %d: %s", row, table.concat(chars)))
end

machine:shutdown()