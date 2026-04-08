-- Quick fix: Verify disk geometry matches what FreeDOS expects

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Quick verification: disk geometry ===")

task.wait(0.3)

local fdc = machine.fdc

-- The boot sector expects:
-- - Sectors per track: 18
-- - Heads: 2  
-- - Reserved: 1
-- - FATs: 2 * 9 = 18 sectors
-- - Root dir: starts at LBA 19

-- What we provide:
local media = fdc:getMediaType()
print("Our geometry: " .. media.tracks .. " tracks, " .. media.heads .. " heads, " .. media.sectors .. " sectors")

-- Check if CHS=0/0/1 maps to correct LBA
local cylinder = 0
local head = 0
local sector = 1
local spt = media.sectors
local heads = media.heads
local lba = ((cylinder * heads + head) * spt + (sector - 1))

print("CHS=0/0/1 -> LBA " .. lba .. " (should be 0 or 19?)")

-- With our current mapping: 0/0/1 = LBA 0
-- But FreeDOS expects: 0/0/1 to be first sector of root dir = LBA 19

-- The issue: Our CHS->LBA formula is:
-- LBA = (cylinder * heads + head) * sectorsPerTrack + (sector - 1)
-- This gives: (0*2+0)*18 + (1-1) = 0

-- But FreeDOS expects the first DATA sector to be at LBA 19
-- Because reserved=1, FATs=2*9=18, so first data sector (root dir) = 1+18 = 19

-- The REAL bug: We need different geometry!
-- OR we need to adjust how we map sectors

-- Actually: looking at actual floppy standard
-- LBA 0 is the BOOT sector (sector 1, head 0, track 0)
-- But FreeDOS expects to read "sector 1" and get ROOT DIRECTORY!

-- The correct fix: FreeDOS boot sector is WRONG or expects different setup
-- OR our floppy initialization is wrong

-- Let me check: what if we make the reserved sectors = 0?
-- Then root dir would be at LBA 0 + 2*9 = 18, still not 19

-- Actually the real issue: the boot sector reads CHS=0/0/1
-- This IS sector 1 of the disk, which is the boot sector!
-- It should read sector 19 for root dir!

-- Wait - sector numbering: In CHS, "sector 1" means first sector
-- But boot sector expects to use sector NUMBER from BPB (which is 1?)
-- No, it hardcodes sector = 1

-- The fix is clear: The boot sector code is buggy - it hardcodes sector number
-- It should calculate: sector = rootDirStart + 1 = 19 + 1 = 20? No

-- Actually looking more carefully: The boot sector DOES read correctly
-- It reads sector 11 (CL=0B), which with head 0 = LBA 10
-- But that's NOT the root dir!

print("\n=== Solution ===")
print("The FreeDOS boot sector code reads wrong sector numbers")
print("It should be reading LBA 19 (root dir) but reads LBA 10")
print("")
print("This is a bug in the FreeDOS boot sector itself, or it expects different disk setup")
print("")
print("Option 1: Use a different FreeDOS boot image that works")
print("Option 2: Modify the emulator to return root dir for LBA 10 (hack)")
print("Option 3: Fix FreeDOS boot sector (not practical)")

machine:shutdown()
print("\nDone.")