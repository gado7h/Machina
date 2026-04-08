-- Investigate what the disk read function is doing

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Tracing Disk Read Execution ===")

-- Wait for boot to run a bit
task.wait(0.3)

local cpu = machine.cpu
local fdc = machine.fdc

-- The boot sector at 0x1FE0 contains INT 13h calls
-- Let's trace what happens when they execute

-- First, let's manually call the same INT 13h that boot sector uses
-- to see what happens

print("\n=== Manually testing INT 13h with boot sector params ===")

-- Save current CPU state
local savedIP = cpu.ip
local savedCS = cpu.seg.CS
local savedAX = cpu:getReg16(0)

-- Set up the same params as boot sector
-- From the code we saw: AH=02, AL=01, CH=00, CL=01, DH=00, DL=00, ES=0000, BX=0200
cpu:setReg8(0, 0x02)  -- AH = 2 (read sectors)
cpu:setReg8(1, 0x01)  -- AL = 1 (count)
cpu:setReg8(2, 0x00)  -- CH = 0 (cylinder low)
cpu:setReg8(3, 0x01)  -- CL = 1 (sector)
cpu:setReg8(4, 0x00)  -- DH = 0 (head)
cpu:setReg8(5, 0x00)  -- DL = 0 (drive)
cpu.seg.ES = 0x0000
cpu:setReg16(1, 0x0200)  -- BX = 0x0200

print(string.format("Before INT 13h: AX=%04X BX=%04X CX=%04X DX=%04X ES=%04X", 
    cpu:getReg16(0), cpu:getReg16(1), cpu:getReg16(2), cpu:getReg16(3), cpu.seg.ES))

-- Now call INT 13h manually
local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")
local handled = BiosInterrupts.handleInterrupt(machine.bios, 0x13)

print(string.format("INT 13h handled: %s", tostring(handled)))
print(string.format("After INT 13h: AX=%04X CF=%d", cpu:getReg16(0), cpu:getFlag(0x0001)))

-- Check what was read
print("\n=== Memory after INT 13h ===")
for row = 0, 1 do
    local b = {}
    for i = 0, 15 do
        local v = cpu:readPhysical8(0x200 + row * 16 + i)
        table.insert(b, string.format("%02X", v))
    end
    print(string.format("%04X: %s", 0x200 + row * 16, table.concat(b, " ")))
end

-- Now let's see what the emulator calculates for LBA
local cylinder = 0
local sector = 1
local head = 0
local spt = 18
local heads = 2
local lba = ((cylinder * heads + head) * spt) + (sector - 1)

print(string.format("\n=== LBA calculation ==="))
print(string.format("CHS = cylinder=%d, head=%d, sector=%d", cylinder, head, sector))
print(string.format("LBA = (%d * %d + %d) * %d + (%d - 1) = %d", 
    cylinder, heads, head, spt, sector, lba))

-- Check what's at that LBA
print(string.format("\n=== What's at LBA %d ===", lba))
local sectorData = fdc:readSector(lba)
if sectorData then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", sectorData[i])) end
    print(table.concat(b, " "))
else
    print("Sector read returned nil!")
end

-- Let's check if maybe we're supposed to use the BPB values from the boot sector
-- The BPB says sectors per track = 18, heads = 2
-- But maybe we should use different values?

print("\n=== Alternative: what if we use sector 19 (root dir)? ===")
local sector19 = fdc:readSector(19)
if sector19 then
    local b = {}
    for i = 1, 16 do table.insert(b, string.format("%02X", sector19[i])) end
    print("LBA 19: " .. table.concat(b, " "))
    
    -- And compare to memory
    local mem = {}
    for i = 0, 15 do mem[i+1] = cpu:readPhysical8(0x200 + i) end
    local memStr = {}
    for i = 1, 16 do table.insert(memStr, string.format("%02X", mem[i])) end
    print("Memory: " .. table.concat(memStr, " "))
end

machine:shutdown()
print("\nDone.")