-- Runtime INT 13h trace - capture all disk reads during boot

local Runner = require("./_runner")
local task = require("@src/task")

-- We need to instrument the machine at a lower level
-- Let's create a custom test that patches the BIOS interrupts

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Runtime INT 13h Trace ===")

-- Wait for machine to initialize
task.wait(0.2)

-- Now manually trigger some disk reads to see what happens
-- The boot sector does these in sequence:
-- 1. Read root directory (first)
-- 2. Read FAT 
-- 3. Read kernel sectors

-- Let's check what happens step by step
local cpu = machine.cpu
local fdc = machine.fdc

print("\n=== Checking boot progress ===")

-- Check memory before boot sector runs much
task.wait(0.3)

local cs = cpu.seg.CS
local ip = cpu.ip
print(string.format("Boot at CS:IP = %04X:%04X", cs, ip))

-- After boot sector should have tried reading, let's check various buffers
-- Check 0x0000:0200 (root dir buffer)
local mem0200 = {}
for i = 0, 15 do
    mem0200[i+1] = cpu:readPhysical8(0x200 + i)
end
print("\n=== Memory at 0x0000:0200 (root dir buffer) ===")
local function hex(t)
    local r = {}
    for i = 1, #t do table.insert(r, string.format("%02X", t[i])) end
    return table.concat(r, " ")
end
print(hex(mem0200))

-- Now let's manually replicate what boot sector does
-- First, it tries to read sector 1 (which according to BPB should be root dir)
-- But actually root dir is at sector 19!

-- Let's see what LBA is calculated vs what's available
print("\n=== Simulating boot sector disk read ===")

-- Boot sector sets these for reading root dir:
-- AH = 02 (read sectors)
-- AL = 01 (1 sector)
-- CH = 00 (cylinder 0)
-- CL = 01 (sector 1)  
-- DH = 00 (head 0)
-- DL = 00 (drive 0)
-- ES:BX = 0x0000:0200

-- Calculate LBA from CHS:
local cylinder = 0
local head = 0
local sector = 1
local spt = 18
local heads = 2
local lba = ((cylinder * heads + head) * spt) + (sector - 1)

print(string.format("Boot sector requests: CHS=%d/%d/%d -> LBA=%d", cylinder, head, sector, lba))

-- What's actually at that LBA?
local sectorAtLba = fdc:readSector(lba)
if sectorAtLba then
    print("Data at LBA " .. lba .. ": " .. hex(sectorAtLba))
end

-- What's the correct LBA for root directory?
local correctRootLba = 19  -- From BPB: 1 + 2*9 = 19
local sectorAtCorrectLba = fdc:readSector(correctRootLba)
print("\n=== Correct root dir at LBA 19 ===")
if sectorAtCorrectLba then
    print("Data at LBA 19: " .. hex(sectorAtCorrectLba))
    
    -- Compare to what boot sector is reading
    local match = true
    for i = 1, 16 do
        if mem0200[i] ~= sectorAtCorrectLba[i] then match = false break end
    end
    print("Memory matches LBA 19: " .. tostring(match))
end

-- So the boot sector is reading from LBA 0 (boot sector!) instead of LBA 19 (root dir)!
print("\n=== THE BUG ===")
print("Boot sector reads LBA 0 (boot sector) instead of LBA 19 (root directory)")
print("This is because it uses CHS=0/0/1 which maps to LBA 0 in our CHS->LBA conversion")
print("But root dir is at LBA 19 according to BPB!")

-- The fix would be: boot sector should calculate the CORRECT LBA
-- But since it's running real FreeDOS code, we can't change that
-- The issue is either:
-- 1. Our CHS->LBA conversion doesn't match what FreeDOS expects
-- 2. FreeDOS is using wrong sector number

-- Actually, looking at the code, FreeDOS BOOT SECTOR expects sector number from BPB
-- The BPB says sectors per track = 18, so CHS=0/0/1 should be LBA 0
-- But root directory is at LBA 19, not LBA 0!

-- Wait, this might be a bug in FreeDOS boot sector itself? 
-- Let me check if there's another call that reads from correct LBA

print("\n=== Looking for more INT 13h calls ===")
-- The boot sector should make multiple calls - let's see what parameters each uses

-- We need to catch these at runtime. Let me create a proper hook

machine:shutdown()
print("\nDone.")