-- Find where the disk read function is

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

print("=== Locating Disk Read Function ===")

-- Wait for boot to start
task.wait(0.5)

local cpu = machine.cpu
local fdc = machine.fdc

-- Find the disk read subroutine in boot sector
-- Looking for: 0xE8 (call) followed by read parameters setup

print("\nSearching boot sector code at 0x1FE0...")

-- Find where BX is set to 0x0200 (root dir buffer)
for ip = 0x50, 0x150 do
    local op1 = cpu:readMem8(0x1FE0, ip)
    local op2 = cpu:readMem8(0x1FE0, ip + 1)
    local op3 = cpu:readMem8(0x1FE0, ip + 2)
    
    -- Look for "mov bx, 0x0200" = B8 00 02 or BA 00 02
    if op1 == 0xB8 and op2 == 0x00 and op3 == 0x02 then
        print(string.format("  Found SET BX=0200 at IP %04X", ip))
    end
    
    -- Look for "mov ax, 0x0001" = B8 01 00
    if op1 == 0xB8 and op2 == 0x01 and op3 == 0x00 then
        print(string.format("  Found SET AX=0001 (read 1 sector) at IP %04X", ip))
    end
    
    -- Look for "mov cx, 0x0001" = B9 01 00 (or similar)
    if op1 == 0xB9 and op2 == 0x01 then
        print(string.format("  Found SET CX (sector) at IP %04X", ip))
    end
    
    -- Look for "mov dx, 0x0000" = BA 00 00
    if op1 == 0xBA and op2 == 0x00 and op3 == 0x00 then
        print(string.format("  Found SET DX (head/drive) at IP %04X", ip))
    end
end

-- Now look at actual register values when at specific IPs
print("\n=== Register dump at various points ===")

local targetIPs = {0x005E, 0x0064, 0x0070, 0x0080, 0x0090, 0x00A0}

for i = 1, 300 do
    if cpu.seg.CS == 0x1FE0 and cpu.ip == targetIPs[1] then
        print(string.format("At IP %04X: AX=%04X BX=%04X CX=%04X DX=%04X SI=%04X DI=%04X",
            cpu.ip, cpu:getReg16(0), cpu:getReg16(1), cpu:getReg16(2), cpu:getReg16(3), cpu:getReg16(6), cpu:getReg16(7)))
        table.remove(targetIPs, 1)
        if #targetIPs == 0 then break end
    end
    task.wait(0.001)
end

-- After boot has run, show what disk reads happened
print("\n=== What should have been read ===")
print("FreeDOS boot expects to read from:")
print("  LBA = (cylinder * heads + head) * sectors_per_track + (sector - 1)")
print("  If CHS = 0/0/1 with 18 spt, 2 heads: LBA = (0*2+0)*18 + (1-1) = 0")
print("  But root dir is at LBA 19!")

-- Check LBA 0 vs LBA 19 content
print("\n=== Content comparison ===")
local lba0 = fdc:readSector(0)  -- boot sector
local lba1 = fdc:readSector(1)  -- first FAT sector  
local lba19 = fdc:readSector(19) -- root dir

if lba0 and lba1 and lba19 then
    local function hex(bytes)
        local t = {}
        for i = 1, math.min(#bytes, 16) do
            t[i] = string.format("%02X", bytes[i])
        end
        return table.concat(t, " ")
    end
    
    print("LBA 0 (boot sector): " .. hex(lba0))
    print("LBA 1 (FAT1):        " .. hex(lba1))
    print("LBA 19 (root dir):   " .. hex(lba19))
    
    -- The memory at 0x200 has "4C 01 00 F0" which matches LBA 1 first bytes!
    print("\nMemory at 0x200:     4C 01 00 F0 ...")
    print("LBA 1 starts with:   " .. hex(lba1):sub(1, 17))
    print("MATCH: " .. (lba1[1] == 0x4C and "YES - reading LBA 1 instead of LBA 19!" or "NO"))
end

machine:shutdown()
print("\nDone.")