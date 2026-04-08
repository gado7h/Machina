-- The boot sector IS reading root directory! 4C 01 is KERNEL.SYS cluster
-- Now find where it FAILS loading the kernel data

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Trace kernel load failure ===")

task.wait(0.3)

local cpu = machine.cpu

-- The boot sector finds KERNEL.SYS and gets cluster 7
-- Then it tries to load the kernel from cluster 7 (LBA 43)
-- Let's trace what happens after that

-- We'll look at what the boot sector does AFTER finding the kernel
-- by checking CPU execution flow

-- First, let's find where the code branches after finding the kernel entry
-- Looking at the code, it should:
-- 1. Read root dir to find KERNEL.SYS (done - memory has 4C 01)
-- 2. Read FAT to get next cluster in chain (not done yet?)  
-- 3. Load kernel sectors from disk
-- 4. Jump to kernel

-- Let me check the code flow after IP 0x00D7 (where it reads root dir)
print("=== Code flow after finding kernel ===")
print("At IP 0x00D7: MOV CX, 000B - reads root dir sector")
print("After that, code should process directory entries...")

-- Check what's at IP 0x00E0 onwards
for ip = 0x00E0, 0x0100 do
    local b = cpu:readMem8(0x1FE0, ip)
    local bnext = cpu:readMem8(0x1FE0, ip + 1)
    
    -- Look for INT 13h calls
    if b == 0xCD and bnext == 0x13 then
        print(string.format("INT 13h at IP %04X", ip))
    end
    
    -- Look for far call
    if b == 0x9A then
        print(string.format("FAR CALL at IP %04X", ip))
    end
    
    -- Look for near call
    if b == 0xE8 then
        local offsetLow = cpu:readMem8(0x1FE0, ip + 1)
        local offsetHigh = cpu:readMem8(0x1FE0, ip + 2)
        local offset = offsetLow + offsetHigh * 256
        local target = (ip + 3 + offset) % 0x10000
        print(string.format("NEAR CALL at IP %04X -> target IP %04X", ip, target))
    end
end

-- The boot sector likely fails when trying to:
-- 1. Read FAT to get next cluster
-- 2. Read kernel data sector

-- Let's check if it makes more disk reads
print("\n=== Looking for more disk reads (INT 13h AH=02) ===")

-- Find all INT 13h where AH=02 (read)
for ip = 0, 0x200 do
    -- Look for B4 02 before CD 13
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xB4 then
        local bnext = cpu:readMem8(0x1FE0, ip + 1)
        if bnext == 0x02 then
            -- Found AH=02
            print(string.format("INT 13h AH=02 setup at IP %04X", ip))
            -- Look for INT 13 after this
            for offset = 1, 20 do
                local ib = cpu:readMem8(0x1FE0, ip + offset)
                local inext = cpu:readMem8(0x1FE0, ip + offset + 1)
                if ib == 0xCD and inext == 0x13 then
                    print(string.format("  -> INT 13 at IP %04X", ip + offset))
                    break
                end
            end
        end
    end
end

-- Let's run the boot and check what sector it TRIES to read
print("\n=== What sector does boot sector try to read after finding kernel? ===")
-- After reading root dir, it should read FAT
-- The FAT starts at LBA 1 (after 1 reserved sector)

-- Check if memory at 0x200 changed after boot progresses
task.wait(0.5)

local cs = cpu.seg.CS
local ip = cpu.ip
print(string.format("CPU at CS:IP = %04X:%04X", cs, ip))

-- Memory at 0x200 should have root dir data
local mem = {}
for i = 0, 31 do
    mem[i+1] = cpu:readPhysical8(0x200 + i)
end
print("Memory at 0x200:")
local function h(t)
    local r = {}
    for i = 1, #t do table.insert(r, string.format("%02X", t[i])) end
    return table.concat(r, " ")
end
print(h(mem))

machine:shutdown()
print("\nDone.")