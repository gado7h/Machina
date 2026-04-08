local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== BOOT SECTOR DISASM ANALYSIS ===")

task.wait(0.5)

local cpu = machine.cpu
local fdc = machine.fdc

-- Find the INT 13h call in the boot sector
-- The boot sector makes several INT 13h calls for different purposes

print("\n=== Finding all INT 13h calls in boot sector ===")

local int13Locations = {}
for ip = 0x00, 0x200 do
    local b = cpu:readMem8(0x1FE0, ip)
    if b == 0xCD then
        local nextB = cpu:readMem8(0x1FE0, ip + 1)
        if nextB == 0x13 then
            -- Before this INT, there's usually a setup for the call
            -- Let's look at the 6 bytes before to see what AH is set to
            local prevBytes = {}
            for i = -6, -1 do
                local pb = cpu:readMem8(0x1FE0, ip + i)
                table.insert(prevBytes, pb)
            end
            
            -- Look for MOV AH, xx instruction before the INT
            -- Usually either B4 xx (mov ah, imm8) or 80 xx yy or similar
            local ahSet = nil
            if prevBytes[#prevBytes] == 0xB4 then
                ahSet = prevBytes[#prevBytes + 1]
            end
            
            print(string.format("INT 13h at 0x1FE0:%04X (AH=%s)", ip, ahSet and string.format("%02X", ahSet) or "?"))
            table.insert(int13Locations, ip)
        end
    end
end

-- Now let's understand each INT 13h call's purpose by examining code around it
print("\n=== Analyzing each INT 13h call ===")

for _, ip in ipairs(int13Locations) do
    print(string.format("\n--- INT 13h at 0x%04X ---", ip))
    
    -- Look at the instructions leading up to this
    print("Code before:")
    for offset = -15, -1 do
        local addr = ip + offset
        local b = cpu:readMem8(0x1FE0, addr)
        local bnext = cpu:readMem8(0x1FE0, addr + 1)
        print(string.format("  %04X: %02X %02X", addr, b, bnext))
    end
    
    -- The code after sets up registers for the call
    -- Let's see what parameters are set
    -- MOV AH, 02 (read) - B4 02
    -- MOV AL, count - B0 xx
    -- MOV CH, cylinder - B5 xx or similar
    -- MOV CL, sector - B1 xx  
    -- MOV DH, head - B6 xx
    -- MOV DL, drive - B2 xx
    -- MOV ES:BX, buffer - segment registers
    
    -- Let's find where parameters are set
    for offset = -30, -2 do
        local addr = ip + offset
        local b = cpu:readMem8(0x1FE0, addr)
        
        -- Check for MOV instructions that set parameters
        if b == 0xB4 then  -- MOV AH, imm8
            local imm = cpu:readMem8(0x1FE0, addr + 1)
            print(string.format("  Set AH = 0x%02X", imm))
        end
        if b == 0xB0 then  -- MOV AL, imm8
            local imm = cpu:readMem8(0x1FE0, addr + 1)
            print(string.format("  Set AL = 0x%02X", imm))
        end
        if b == 0xB8 then  -- MOV AX, imm16
            local immLow = cpu:readMem8(0x1FE0, addr + 1)
            local immHigh = cpu:readMem8(0x1FE0, addr + 2)
            print(string.format("  Set AX = 0x%02X%02X", immHigh, immLow))
        end
    end
end

machine:shutdown()
print("\nDone.")