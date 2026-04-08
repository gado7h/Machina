-- Check the other INT 13h calls that read kernel data

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Check all disk reads ===")

task.wait(0.3)

local cpu = machine.cpu

-- Find ALL INT 13h calls in boot sector
print("=== All INT 13h in boot sector ===")
local int13s = {}
for ip = 0, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xCD then
        local bnext = cpu:readMem8(0x1FE0, ip + 1)
        if bnext == 0x13 then
            table.insert(int13s, ip)
        end
    end
end

for _, ip in ipairs(int13s) do
    -- Look back for MOV AH to find service number
    local ah = nil
    for offset = -10, -1 do
        local b = cpu:readMem8(0x1FE0, ip + offset)
        if b == 0xB4 then
            ah = cpu:readMem8(0x1FE0, ip + offset + 1)
            break
        end
    end
    
    -- Look for register setups before this
    print(string.format("\n=== INT 13h at IP %04X (AH=%s) ===", ip, ah and string.format("%02X", ah) or "?"))
    
    -- Look for AL, CH, CL, DH, DL setups
    for offset = -30, -1 do
        local b = cpu:readMem8(0x1FE0, ip + offset)
        local bnext = cpu:readMem8(0x1FE0, ip + offset + 1)
        
        if b == 0xB4 then print(string.format("  IP %04X: MOV AH, %02X", ip + offset, bnext))
        elseif b == 0xB0 then print(string.format("  IP %04X: MOV AL, %02X", ip + offset, bnext))
        elseif b == 0xB8 then local v = bnext + cpu:readMem8(0x1FE0, ip + offset + 2) * 256 print(string.format("  IP %04X: MOV AX, %04X", ip + offset, v))
        elseif b == 0xB5 then print(string.format("  IP %04X: MOV CH, %02X", ip + offset, bnext))
        elseif b == 0xB1 then print(string.format("  IP %04X: MOV CL, %02X", ip + offset, bnext))
        elseif b == 0xB6 then print(string.format("  IP %04X: MOV DH, %02X", ip + offset, bnext))
        elseif b == 0xB2 then print(string.format("  IP %04X: MOV DL, %02X", ip + offset, bnext))
        elseif b == 0xBA then local v = bnext + cpu:readMem8(0x1FE0, ip + offset + 2) * 256 print(string.format("  IP %04X: MOV DX, %04X", ip + offset, v))
        elseif b == 0xBB then local v = bnext + cpu:readMem8(0x1FE0, ip + offset + 2) * 256 print(string.format("  IP %04X: MOV BX, %04X", ip + offset, v))
        end
    end
end

machine:shutdown()
print("\nDone.")