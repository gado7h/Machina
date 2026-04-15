-- Run full boot without redirect
local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(2.0)

local frame = FrameCapture.capture(machine)
print("=== After 2 seconds ===")
print(frame.text and frame.text:sub(1, 80) or "empty")

task.wait(3.0)

frame = FrameCapture.capture(machine)
print("\n=== After 5 seconds ===")  
print(frame.text and frame.text:sub(1, 80) or "empty")

machine:shutdown()