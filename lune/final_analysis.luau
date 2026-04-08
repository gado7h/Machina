-- Final verification: trace what happens during boot

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Final Analysis ===")

-- Wait a bit then check state
task.wait(1)

local cpu = machine.cpu
local fdc = machine.fdc
local stage = machine:getBootStage()

print("Boot stage: " .. stage)
print("CS:IP = " .. string.format("%04X:%04X", cpu.seg.CS, cpu.ip))

-- The kernel (KERNEL.SYS) IS being found and IS at the right place on disk
-- So why isn't it booting?

-- The issue could be:
-- 1. CPU is executing wrong code after boot sector
-- 2. Something in the boot sector is failing silently
-- 3. There's an issue with how FreeDOS calculates where to load the kernel

-- Let me check if the CPU is actually jumping to KERNEL.SYS
-- KERNEL.SYS is at cluster 7, which maps to LBA 43
-- In memory, KERNEL.SYS would typically be loaded at 0x1000:0000 or similar

-- Let's check what's in memory where kernel should be
print("\n=== Memory at 0x1000:0000 (typical kernel load address) ===")
for row = 0, 2 do
    local bytes = {}
    for i = 0, 15 do
        local seg = 0x1000
        local off = row * 16 + i
        local v = cpu:readMem8(seg, off)
        table.insert(bytes, string.format("%02X", v))
    end
    print(string.format("%04X:%04X: %s", 0x1000, row * 16, table.concat(bytes, " ")))
end

-- Check if maybe kernel was loaded somewhere else
-- Let's check 0x0000:0100 (another common spot)
print("\n=== Memory at 0x0000:0100 ===")
local bytes = {}
for i = 0, 15 do
    local v = cpu:readPhysical8(0x100 + i)
    table.insert(bytes, string.format("%02X", v))
end
print(table.concat(bytes, " "))

-- Check 0x0000:0000
print("\n=== Memory at 0x0000:0000 ===")
bytes = {}
for i = 0, 15 do
    local v = cpu:readPhysical8(i)
    table.insert(bytes, string.format("%02X", v))
end
print(table.concat(bytes, " "))

-- The CPU is still at 0x1FE0 (in boot sector code), which means
-- it never successfully loaded and executed KERNEL.SYS

print("\n=== THE ROOT CAUSE ===")
print("FreeDOS boot sector successfully:")
print("  - Loads boot sector to 0x7C00")
print("  - Relocates to 0x1FE0")
print("  - Reads root directory")
print("  - Finds KERNEL.SYS entry")
print("  - Finds KERNEL.SYS at cluster 7 -> LBA 43")
print("")
print("But the boot process never successfully:")
print("  - Load KERNEL.SYS into memory")
print("  - Jump to KERNEL.SYS execution")
print("")
print("The boot sector loops because it can't successfully load the kernel.")
print("This could be due to:")
print("  1. INT 13h read returning wrong data for kernel sectors")
print("  2. Memory allocation issues")
print("  3. FAT chain traversal failing")

-- Check if maybe the issue is that the boot sector read function itself has a bug
-- Looking at what happens when it tries to read kernel

print("\n=== Potential Fix ===")
print("The FreeDOS boot code expects to read from the disk successfully.")
print("We need to verify that INT 13h reads return correct data for all sectors.")
print("Try loading kernel data into the FDC correctly...")

machine:shutdown()
print("\nDone.")