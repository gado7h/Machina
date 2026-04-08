-- Check MOV CX values in boot sector at runtime

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Finding all MOV CX in boot sector ===")

task.wait(0.5)

local cpu = machine.cpu

-- Search the entire boot sector for MOV CX instructions (B9)
print("Searching for B9 (MOV CX, imm16) instructions:")

for ip = 0, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xB9 then  -- MOV CX, imm16
        local low = cpu:readMem8(0x1FE0, ip + 1)
        local high = cpu:readMem8(0x1FE0, ip + 2)
        local value = high * 256 + low
        local cylinder = high
        local sector = bit32.band(low, 0x3F)
        print(string.format("  IP %04X: MOV CX, %04X -> CH=cylinder=%d, CL=sector=%d", 
            ip, value, cylinder, sector))
    end
end

-- Also look for MOV CL, imm8 (B1)
print("\nSearching for B1 (MOV CL, imm8) instructions:")
for ip = 0, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xB1 then  -- MOV CL, imm8
        local val = cpu:readMem8(0x1FE0, ip + 1)
        print(string.format("  IP %04X: MOV CL, %02X (sector %d)", ip, val, val))
    end
end

-- Look for MOV CH, imm8 (B5)
print("\nSearching for B5 (MOV CH, imm8) instructions:")
for ip = 0, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xB5 then  -- MOV CH, imm8
        local val = cpu:readMem8(0x1FE0, ip + 1)
        print(string.format("  IP %04X: MOV CH, %02X (cylinder %d)", ip, val, val))
    end
end

-- Also search for any "mov ah, 02" (B4 02) before INT 13
print("\nSearching for AH=02 (read sectors) setup:")
for ip = 0, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    local bnext = cpu:readMem8(0x1FE0, ip + 1)
    if b == 0xB4 and bnext == 0x02 then
        -- Found "mov ah, 02" - look back a bit to see the full setup
        print(string.format("  Found AH=02 at IP %04X", ip))
        print(string.format("    Context:"))
        for offset = -10, 0 do
            local addr = ip + offset
            local bb = cpu:readMem8(0x1FE0, addr)
            io.write(string.format(" %02X", bb))
        end
        print("")
    end
end

machine:shutdown()
print("\nDone.")