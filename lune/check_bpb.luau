-- Check if boot sector calculates LBA from BPB or uses hardcoded values

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Checking boot sector BPB-relative reads ===")

task.wait(0.3)

local cpu = machine.cpu

-- The boot sector BPB is at offset 0x0B in the boot sector
-- Let's read the BPB values from the boot sector code itself

local bootSectorPhys = 0x7C00  -- Where boot sector is loaded first

print("=== Boot Sector BPB (at 0x7C00) ===")

-- Bytes per sector (offset 0x0B = 11)
local bpsLow = cpu:readPhysical8(bootSectorPhys + 11)
local bpsHigh = cpu:readPhysical8(bootSectorPhys + 12)
local bytesPerSector = bpsLow + bpsHigh * 256
print("Bytes per sector: " .. bytesPerSector)

-- Sectors per cluster (offset 0x0D = 13)
local spc = cpu:readPhysical8(bootSectorPhys + 13)
print("Sectors per cluster: " .. spc)

-- Reserved sectors (offset 0x0E = 14)
local reservedLow = cpu:readPhysical8(bootSectorPhys + 14)
local reservedHigh = cpu:readPhysical8(bootSectorPhys + 15)
local reserved = reservedLow + reservedHigh * 256
print("Reserved sectors: " .. reserved)

-- FAT count (offset 0x10 = 16)
local fatCount = cpu:readPhysical8(bootSectorPhys + 16)
print("FAT count: " .. fatCount)

-- Root entries (offset 0x11 = 17)
local rootEntriesLow = cpu:readPhysical8(bootSectorPhys + 17)
local rootEntriesHigh = cpu:readPhysical8(bootSectorPhys + 18)
local rootEntries = rootEntriesLow + rootEntriesHigh * 256
print("Root directory entries: " .. rootEntries)

-- Sectors per FAT (offset 0x16 = 22)
local spfLow = cpu:readPhysical8(bootSectorPhys + 22)
local spfHigh = cpu:readPhysical8(bootSectorPhys + 23)
local sectorsPerFat = spfLow + spfHigh * 256
print("Sectors per FAT: " .. sectorsPerFat)

-- Calculate root directory LBA
local rootDirStart = reserved + fatCount * sectorsPerFat
print("\n=== Calculated Layout ===")
print("Root directory starts at sector: " .. rootDirStart)

-- Now check if boot sector code CALCULATES this or hardcodes
-- Look at the boot sector code to see if it adds offset to sector number

-- The boot sector makes a disk read call - let's see what sector it passes
-- We need to catch this at runtime

-- Let's look at the code after the relocation to see how it calculates
-- The code at 0x1FE0 should have some calculation

-- Check the code around where disk read parameters are set
print("\n=== Boot sector code that sets up disk read ===")
for ip = 0x50, 0x70 do
    local b1 = cpu:readMem8(0x1FE0, ip)
    local b2 = cpu:readMem8(0x1FE0, ip + 1)
    
    -- Look for "mov cx, xx" - CX often contains cylinder:sector
    if b1 == 0xB9 then  -- MOV CX, imm16
        local valLo = cpu:readMem8(0x1FE0, ip + 1)
        local valHi = cpu:readMem8(0x1FE0, ip + 2)
        print(string.format("IP %04X: MOV CX, 0x%02X%02X", ip, valHi, valLo))
    end
    
    -- Look for "mov al, xx" - AL is sector count
    if b1 == 0xB0 then
        local val = cpu:readMem8(0x1FE0, ip + 1)
        print(string.format("IP %04X: MOV AL, 0x%02X (sector count)", ip, val))
    end
end

print("\n=== Checking if BPB is used for calculation ===")
-- There should be code that reads from BPB and calculates LBA
-- Let's search for instructions that read from offset 0x1C (hidden sectors)

-- Actually, let's just trace all disk reads to see what parameters are used

machine:shutdown()
print("\nDone.")