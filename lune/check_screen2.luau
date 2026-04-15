-- Check VRAM using FrameCapture
local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(0.5)

local frame = FrameCapture.capture(machine)
print("=== Initial Screen ===")
print(frame.text and frame.text:sub(1, 80) or "empty")

task.wait(3.0)

frame = FrameCapture.capture(machine)
print("\n=== After 3 seconds ===")
print(frame.text and frame.text:sub(1, 80) or "empty")

machine:shutdown()