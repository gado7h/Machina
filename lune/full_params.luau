-- Check MOV DH (head) setup before each disk read

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== Complete disk read parameter analysis ===")

task.wait(0.3)

local cpu = machine.cpu
local fdc = machine.fdc

-- We have two disk reads. Let's trace the full parameter setup for each.

-- DISK READ #1: Near IP 0x50
print("\n=== Disk Read #1 (around IP 0x50) ===")
print("Looking for parameter setup before MOV CX at 0x50:")
for ip = 0x40, 0x52 do
    local b = cpu:readMem8(0x1FE0, ip)
    local bnext = cpu:readMem8(0x1FE0, ip + 1)
    
    local disasm = ""
    if b == 0xB4 then disasm = string.format("MOV AH, %02X", bnext)
    elseif b == 0xB0 then disasm = string.format("MOV AL, %02X", bnext)
    elseif b == 0xB8 then disasm = string.format("MOV AX, %04X", bnext + bnext*256)
    elseif b == 0xB5 then disasm = string.format("MOV CH, %02X", bnext)
    elseif b == 0xB1 then disasm = string.format("MOV CL, %02X", bnext)
    elseif b == 0xB6 then disasm = string.format("MOV DH, %02X", bnext)
    elseif b == 0xB2 then disasm = string.format("MOV DL, %02X", bnext)
    elseif b == 0xBA then disasm = string.format("MOV DX, %04X", bnext + cpu:readMem8(0x1FE0, ip+2)*256)
    elseif b == 0xBB then disasm = string.format("MOV BX, %04X", bnext + cpu:readMem8(0x1FE0, ip+2)*256)
    end
    
    if disasm ~= "" then
        print(string.format("  IP %04X: %s", ip, disasm))
    end
end

-- DISK READ #2: Near IP 0xD7
print("\n=== Disk Read #2 (around IP 0xD7) ===")
print("Looking for parameter setup before MOV CX at 0xD7:")
for ip = 0xC5, 0xD9 do
    local b = cpu:readMem8(0x1FE0, ip)
    local bnext = cpu:readMem8(0x1FE0, ip + 1)
    
    local disasm = ""
    if b == 0xB4 then disasm = string.format("MOV AH, %02X", bnext)
    elseif b == 0xB0 then disasm = string.format("MOV AL, %02X", bnext)
    elseif b == 0xB8 then disasm = string.format("MOV AX, %04X", bnext + bnext*256)
    elseif b == 0xB5 then disasm = string.format("MOV CH, %02X", bnext)
    elseif b == 0xB1 then disasm = string.format("MOV CL, %02X", bnext)
    elseif b == 0xB6 then disasm = string.format("MOV DH, %02X", bnext)
    elseif b == 0xB2 then disasm = string.format("MOV DL, %02X", bnext)
    elseif b == 0xBA then disasm = string.format("MOV DX, %04X", bnext + cpu:readMem8(0x1FE0, ip+2)*256)
    elseif b == 0xBB then disasm = string.format("MOV BX, %04X", bnext + cpu:readMem8(0x1FE0, ip+2)*256)
    end
    
    if disasm ~= "" then
        print(string.format("  IP %04X: %s", ip, disasm))
    end
end

-- Find INT 13h calls to see where they are
print("\n=== Finding INT 13h calls ===")
for ip = 0, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xCD then
        local bnext = cpu:readMem8(0x1FE0, ip + 1)
        if bnext == 0x13 then
            print(string.format("INT 13h at IP %04X", ip))
        end
    end
end

-- Check what AH is set to before each INT 13h
print("\n=== AH value before each INT 13h ===")
for ip = 0, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xCD then
        local bnext = cpu:readMem8(0x1FE0, ip + 1)
        if bnext == 0x13 then
            -- Look for preceding MOV AH
            for offset = -5, -1 do
                local prev = cpu:readMem8(0x1FE0, ip + offset)
                if prev == 0xB4 then
                    local ah = cpu:readMem8(0x1FE0, ip + offset + 1)
                    print(string.format("INT 13h at IP %04X: AH=%02X (%s)", ip, ah,
                        ah == 0x02 and "READ" or 
                        ah == 0x03 and "WRITE" or 
                        ah == 0x08 and "GET PARAMS" or
                        "other"))
                end
            end
        end
    end
end

machine:shutdown()
print("\nDone.")