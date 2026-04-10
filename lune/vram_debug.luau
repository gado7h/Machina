local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = {
            PROVIDER = "freeDOS",
        },
        TRACE = {
            ENABLED = true,
            DISK = true,
            BIOS_CALLS = true,
        },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FreeDOS Boot DEBUG ===")

task.wait(3)

local vram = FrameCapture.getVRAMAddress(machine)

-- Show more detailed VRAM analysis
print("
=== VRAM Detailed Analysis ===")
print("Row 0 (BIOS banner):")
for col = 0, 19 do
    local char = vram[col * 2] or 0
    print(string.format("  col%d: '%s' (0x%02X)", col, chr(char) if char > 32 else '?', char))
end

-- Check what's at column 20+
print("
=== Row 1 dots analysis ===")
for start in [0, 20, 40, 60] do
    local hex = []
    for col = start, start+19 do
        local char = vram[80 + col] or 0
        table.insert(hex, string.format("%02X", char))
    end
    print(string.format("  cols %d-%d: %s", start, start+19, table.concat(hex, ' ')))
end

print("
Done.")
