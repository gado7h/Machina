-- Analyze what each read actually reads

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Analyze each disk read's LBA ===")

task.wait(0.3)

local cpu = machine.cpu
local fdc = machine.fdc

-- We have:
-- 1. AH=41 at 0x186 - Check extensions
-- 2. AH=02 at 0x1CE - Read sectors  
-- 3. AH=02 at 0x1D4 - Read sectors

-- Let's find the parameters for each read call

-- For IP 0x1CE, look at the code around it
print("=== Read #1 at IP 0x1CE ===")
print("Looking for parameters:")
for offset = -20, 0 do
    local addr = 0x1CE + offset
    local b = cpu:readMem8(0x1FE0, addr)
    local bn = cpu:readMem8(0x1FE0, addr + 1)
    
    -- MOV instructions
    if b == 0xB8 then local v = bn + cpu:readMem8(0x1FE0, addr + 2) * 256 print(string.format("  %04X: MOV AX=%04X", addr, v))
    elseif b == 0xB4 then print(string.format("  %04X: MOV AH=%02X", addr, bn))
    elseif b == 0xB0 then print(string.format("  %04X: MOV AL=%02X", addr, bn))
    elseif b == 0xB9 then local v = bn + cpu:readMem8(0x1FE0, addr + 2) * 256 print(string.format("  %04X: MOV CX=%04X", addr, v))
    elseif b == 0xBA then local v = bn + cpu:readMem8(0x1FE0, addr + 2) * 256 print(string.format("  %04X: MOV DX=%04X", addr, v))
    elseif b == 0xBB then local v = bn + cpu:readMem8(0x1FE0, addr + 2) * 256 print(string.format("  %04X: MOV BX=%04X", addr, v))
    end
end

print("\n=== Read #2 at IP 0x1D4 ===")
print("Looking for parameters:")
for offset = -20, 0 do
    local addr = 0x1D4 + offset
    local b = cpu:readMem8(0x1FE0, addr)
    local bn = cpu:readMem8(0x1FE0, addr + 1)
    
    if b == 0xB8 then local v = bn + cpu:readMem8(0x1FE0, addr + 2) * 256 print(string.format("  %04X: MOV AX=%04X", addr, v))
    elseif b == 0xB4 then print(string.format("  %04X: MOV AH=%02X", addr, bn))
    elseif b == 0xB0 then print(string.format("  %04X: MOV AL=%02X", addr, bn))
    elseif b == 0xB9 then local v = bn + cpu:readMem8(0x1FE0, addr + 2) * 256 print(string.format("  %04X: MOV CX=%04X", addr, v))
    elseif b == 0xBA then local v = bn + cpu:readMem8(0x1FE0, addr + 2) * 256 print(string.format("  %04X: MOV DX=%04X", addr, v))
    elseif b == 0xBB then local v = bn + cpu:readMem8(0x1FE0, addr + 2) * 256 print(string.format("  %04X: MOV BX=%04X", addr, v))
    end
end

-- The disk reads use:
-- AX = 0x0201 (AH=02 read sectors, AL=01 count)
-- CX (cylinder/sector): 0x0201 for read1, unknown for read2
-- DX (head/drive): 0x0100 for read1, unknown for read2
-- BX (buffer): 0x0100

-- Let's calculate the LBA for each
-- Read1: CH=02, CL=01 -> cylinder=0 (bits 0-7), sector=1 (bits 0-5 of high byte) = sector 1
-- But CX=0x0201 = CH=02, CL=01 (cylinder 2, sector 1)? No...
-- 0x0201 = 513 decimal
-- CH = low byte = 0x01 = 1
-- CL = high byte = 0x02 = sector bits + cylinder high bits
-- sector = CL & 0x3F = 0x02 = 2
-- cylinder = ((CL >> 6) << 8) + CH = (0 >> 6 << 8) + 1 = 1

-- So read #1: cylinder=1, sector=2

print("\n=== Calculate LBA for each read ===")
local spt = 18
local heads = 2

-- Read #1: cylinder=1, sector=2, assume head=0
local cyl1 = 1
local head1 = 0
local sec1 = 2
local lba1 = ((cyl1 * heads + head1) * spt) + (sec1 - 1)
print(string.format("Read #1: cylinder=%d, head=%d, sector=%d -> LBA %d", cyl1, head1, sec1, lba1))

-- Read #2: need to find parameters
-- Let's look more carefully at the code for read #2
print("\n=== Looking for read #2 parameters specifically ===")
for offset = -30, -1 do
    local addr = 0x1D4 + offset
    local b = cpu:readMem8(0x1FE0, addr)
    if b == 0xB9 or b == 0xBA or b == 0xBB then
        local bn = cpu:readMem8(0x1FE0, addr + 1)
        local bn2 = cpu:readMem8(0x1FE0, addr + 2)
        if b == 0xB9 then
            local v = bn + bn2 * 256
            local cyl = v % 256
            local sec = bit32.band(v / 256, 0x3F) + bit32.rshift(v, 14) * 64
            print(string.format("  %04X: CX=%04X -> cyl=%d sec=%d", addr, v, cyl, sec))
        elseif b == 0xBA then
            local v = bn + bn2 * 256
            print(string.format("  %04X: DX=%04X -> head=%d drive=%d", addr, v, bn, bn2))
        elseif b == 0xBB then
            local v = bn + bn2 * 256
            print(string.format("  %04X: BX=%04X", addr, v))
        end
    end
end

machine:shutdown()
print("\nDone.")