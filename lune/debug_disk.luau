-- Debug FreeDOS boot sector disk reads
-- This script traces what sectors FreeDOS is reading

local Runner = require("./_runner")
local task = require("@src/task")

-- Patch the BIOS interrupt handler to trace disk reads
local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")

local original_floppyReadSectors = nil

local function patchDiskReads()
    -- We'll create a custom machine and intercept disk operations
end

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = {
            PROVIDER = "freeDOS",
        },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FreeDOS Boot Disk Read Trace ===")

-- Wait for boot to start
local startTime = os.clock()
while os.clock() - startTime < 3 do
    local stage = machine:getBootStage()
    if stage == "BOOT" or stage == "RUNNING" then
        break
    end
    task.wait(0.05)
end

-- Now read what's at specific LBAs
local fdc = machine.fdc
if fdc then
    print("\n=== Examining Disk Contents ===")
    
    -- Read sector 0 (boot sector)
    local sector0 = fdc:readSector(0)
    if sector0 then
        print("\nSector 0 (boot sector):")
        print("  Signature: " .. string.format("0x%02X 0x%02X", sector0[1], sector0[2]))
        print("  Bytes 2-3: " .. string.format("0x%02X 0x%02X", sector0[3], sector0[4]))
    end
    
    -- Read sector 1
    local sector1 = fdc:readSector(1)
    if sector1 then
        print("\nSector 1:")
        print("  First 16 bytes: " .. table.concat(
            {[1]="...",[2]="...",[3]="...",[4]="...",[5]="...",[6]="...",[7]="...",[8]="...",[9]="...",[10]="...",[11]="...",[12]="...",[13]="...",[14]="...",[15]="...",[16]="..."},
            ", "))
        local bytes = {}
        for i = 1, 16 do
            table.insert(bytes, string.format("%02X", sector1[i]))
        end
        print("  First 16 bytes: " .. table.concat(bytes, " "))
    end
    
    -- Read sector 2 (should be FAT)
    local sector2 = fdc:readSector(2)
    if sector2 then
        print("\nSector 2 (first FAT sector):")
        local bytes = {}
        for i = 1, 16 do
            table.insert(bytes, string.format("%02X", sector2[i]))
        end
        print("  First 16 bytes: " .. table.concat(bytes, " "))
    end
    
    -- Read sector 19 (root directory)
    local sector19 = fdc:readSector(19)
    if sector19 then
        print("\nSector 19 (root directory):")
        local bytes = {}
        for i = 1, 32 do
            table.insert(bytes, string.format("%02X", sector19[i]))
        end
        print("  First 32 bytes: " .. table.concat(bytes, " "))
        
        -- Try to parse as directory entries
        print("  Directory entries (first 4):")
        for entry = 0, 3 do
            local offset = entry * 32 + 1
            local name = ""
            for i = 0, 7 do
                local ch = sector19[offset + i]
                if ch and ch ~= 0x00 and ch ~= 0xFF then
                    name = name .. string.char(ch)
                end
            end
            local ext = ""
            for i = 8, 10 do
                local ch = sector19[offset + i]
                if ch and ch ~= 0x00 and ch ~= 0xFF then
                    ext = ext .. string.char(ch)
                end
            end
            if name ~= "" then
                print(string.format("    [%d] %s.%s", entry, name, ext))
            end
        end
    end
    
    -- Get media info
    local media = fdc.getMediaType and fdc:getMediaType()
    if media then
        print("\n=== Media Info ===")
        print("  Tracks: " .. tostring(media.tracks))
        print("  Heads: " .. tostring(media.heads))
        print("  Sectors: " .. tostring(media.sectors))
        print("  Total sectors: " .. tostring(fdc.getTotalSectors and fdc:getTotalSectors() or "N/A"))
    end
end

machine:shutdown()
print("\nDone.")