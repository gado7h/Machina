-- Debug: Check memory at specific times after boot starts

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = {
            PROVIDER = "freeDOS",
        },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Boot Sector Debug ===")

local cpu = machine.cpu

-- Wait 1 second for boot sector to run
task.wait(1)

print("\nAfter 1 second:")
print("  CS:IP = " .. string.format("%04X:%04X", cpu.seg.CS, cpu.ip))
print("  AX=" .. string.format("%04X", cpu:getReg16(0)))

-- Check memory at 0x0000:0200
print("\n  Memory at 0x0000:0200 (root dir buffer):")
for row = 0, 3 do
    local bytes = {}
    for i = 0, 15 do
        local v = cpu:readPhysical8(0x200 + row * 16 + i)
        table.insert(bytes, string.format("%02X", v))
    end
    print("    " .. string.format("%04X:", 0x200 + row * 16) .. table.concat(bytes, " "))
end

-- Wait another second
task.wait(1)

print("\nAfter 2 seconds:")
print("  CS:IP = " .. string.format("%04X:%04X", cpu.seg.CS, cpu.ip))

-- Check memory again
print("\n  Memory at 0x0000:0200:")
for row = 0, 3 do
    local bytes = {}
    for i = 0, 15 do
        local v = cpu:readPhysical8(0x200 + row * 16 + i)
        table.insert(bytes, string.format("%02X", v))
    end
    print("    " .. string.format("%04X:", 0x200 + row * 16) .. table.concat(bytes, " "))
end

-- Check what's at LBA 19 (actual root dir) via FDC
local fdc = machine.fdc
if fdc then
    print("\n  Actual root dir at LBA 19:")
    local sector = fdc:readSector(19)
    if sector then
        local bytes = {}
        for i = 1, 16 do table.insert(bytes, string.format("%02X", sector[i])) end
        print("    " .. table.concat(bytes, " "))
    end
end

machine:shutdown()
print("\nDone.")