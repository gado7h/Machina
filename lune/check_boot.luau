local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(3.0)

local cpu = machine.cpu

print("=== Final State ===")
print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))
print(string.format("AX=%04X BX=%04X CX=%04X DX=%04X", 
    cpu:getReg16(0), cpu:getReg16(1), cpu:getReg16(2), cpu:getReg16(3)))

-- Check boot sector at original location
print("\n=== Boot Sector (0x7C00) ===")
local bs = {}
for i = 0, 15 do
    bs[i+1] = string.format("%02X", cpu:readPhysical8(0x7C00 + i))
end
print(table.concat(bs, " "))

-- Check our copy
print("\n=== Boot Sector Copy (0x1FE00) ===")
local bs2 = {}
for i = 0, 15 do
    bs2[i+1] = string.format("%02X", cpu:readPhysical8(0x1FE00 + i))
end
print(table.concat(bs2, " "))

-- Check kernel load area (0x1000:0000)
print("\n=== Kernel Area (0x10000) ===")
local kr = {}
for i = 0, 15 do
    kr[i+1] = string.format("%02X", cpu:readPhysical8(0x10000 + i))
end
print(table.concat(kr, " "))

-- Check buffer at 0x200 (root dir)
print("\n=== Root Dir Buffer (0x200) ===")
local rd = {}
for i = 0, 15 do
    rd[i+1] = string.format("%02X", cpu:readPhysical8(0x200 + i))
end
print(table.concat(rd, " "))

machine:shutdown()