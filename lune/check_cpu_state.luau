-- Check CPU state during boot
local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(0.1)

local cpu = machine.cpu

print("=== Initial state (after boot sector load) ===")
print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))
print(string.format("AX=%04X BX=%04X CX=%04X DX=%04X", cpu:getReg16(0), cpu:getReg16(1), cpu:getReg16(2), cpu:getReg16(3)))
print(string.format("FLAGS=%04X", cpu.flags))

-- Run some steps
for i = 1, 1000 do cpu:step() end

print("\n=== After 1000 steps ===")
print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))
print(string.format("AX=%04X BX=%04X CX=%04X DX=%04X", cpu:getReg16(0), cpu:getReg16(1), cpu:getReg16(2), cpu:getReg16(3)))
print(string.format("FLAGS=%04X", cpu.flags))

-- Run more steps
for i = 1, 2000 do cpu:step() end

print("\n=== After 3000 steps ===")
print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))
print(string.format("AX=%04X BX=%04X CX=%04X DX=%04X", cpu:getReg16(0), cpu:getReg16(1), cpu:getReg16(2), cpu:getReg16(3)))
print(string.format("FLAGS=%04X", cpu.flags))

machine:shutdown()