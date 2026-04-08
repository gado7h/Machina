-- Direct trace: what's being requested vs what's returned

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Direct Disk Read Analysis ===")

-- Wait for boot to fully start
task.wait(0.8)

local cpu = machine.cpu
local fdc = machine.fdc

-- Check all relevant memory locations
print("\n=== Memory at 0x0000:0200-0x0000:02FF (root dir buffer) ===")
for row = 0, 7 do
    local bytes = {}
    for i = 0, 15 do
        local v = cpu:readPhysical8(0x200 + row * 16 + i)
        table.insert(bytes, string.format("%02X", v))
    end
    print(string.format("  %04X: %s", 0x200 + row * 16, table.concat(bytes, " ")))
end

-- Check the BPB in boot sector to understand the expected layout
print("\n=== Boot Sector BPB ===")
local bootSector = fdc:readSector(0)
if bootSector then
    local reserved = bootSector[15] + bootSector[16] * 256
    local fatCount = bootSector[17]
    local sectorsPerFat = bootSector[23] + bootSector[24] * 256
    local rootDirEntries = bootSector[18] + bootSector[19] * 256
    print(string.format("Reserved sectors: %d", reserved))
    print(string.format("FAT count: %d", fatCount))
    print(string.format("Sectors per FAT: %d", sectorsPerFat))
    print(string.format("Root dir entries: %d", rootDirEntries))
    
    local rootDirStart = reserved + fatCount * sectorsPerFat
    print(string.format("Root dir starts at sector: %d", rootDirStart))
end

-- Now check if the boot sector is reading from the right LBA
-- The boot code is at 0x1FE0. Let's find the disk read call

print("\n=== Looking for disk read parameters in boot code ===")

-- Look for instructions that set up disk read
-- At offset around 0x5E in boot sector (which is at 0x1FE0:005E)
-- Based on the hex: B8 01 00 BA 00 02 B9 01 00 BA 00 00 E8 E9 00
-- That's: MOV AX,0001; MOV BX,0200; MOV CX,0001; MOV DX,0000; CALL

-- Check the code around that area
for ip = 0x50, 0x70 do
    local b1 = cpu:readMem8(0x1FE0, ip)
    local b2 = cpu:readMem8(0x1FE0, ip + 1)
    local b3 = cpu:readMem8(0x1FE0, ip + 2)
    local b4 = cpu:readMem8(0x1FE0, ip + 3)
    local b5 = cpu:readMem8(0x1FE0, ip + 4)
    
    -- Print non-zero bytes in that range
    if b1 ~= 0 or b2 ~= 0 or b3 ~= 0 or b4 ~= 0 or b5 ~= 0 then
        print(string.format("  %04X: %02X %02X %02X %02X %02X", ip, b1, b2, b3, b4, b5))
    end
end

-- The problem might be in the disk read function itself
-- Let's see what's actually at the memory location being written to
print("\n=== What does the emulator think is at ES:BX ===")

-- We need to catch this during execution. Let me check what ES:BX is when running
-- The boot code sets ES to 0x0000 and BX to 0x0200

-- The problem might be that we're not reading the right sector
-- Let me check what sectors exist:
print("\n=== Checking all possible sector reads ===")
for lba = 0, 30 do
    local sector = fdc:readSector(lba)
    if sector then
        local first8 = {}
        for i = 1, 8 do table.insert(first8, string.format("%02X", sector[i])) end
        print(string.format("LBA %2d: %s", lba, table.concat(first8, " ")))
    end
end

machine:shutdown()
print("\nDone.")