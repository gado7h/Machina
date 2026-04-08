-- Debug: More detailed disk layout analysis

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

print("=== FreeDOS Disk Layout Analysis ===")

-- Wait for boot to start
local startTime = os.clock()
while os.clock() - startTime < 3 do
    local stage = machine:getBootStage()
    if stage == "BOOT" or stage == "RUNNING" then
        break
    end
    task.wait(0.05)
end

local fdc = machine.fdc
if fdc then
    -- Read the boot sector (sector 0) to get BPB
    local sector0 = fdc:readSector(0)
    print("=== Boot Sector BPB ===")
    print(string.format("Bytes per sector: %d (0x%04X)", 
        sector0[12] + sector0[13] * 256, sector0[12] + sector0[13] * 256))
    print(string.format("Sectors per cluster: %d", sector0[14]))
    print(string.format("Reserved sectors: %d", sector0[15] + sector0[16] * 256))
    print(string.format("FAT count: %d", sector0[17]))
    print(string.format("Root dir entries: %d", sector0[18] + sector0[19] * 256))
    print(string.format("Total sectors: %d", sector0[20] + sector0[21] * 256))
    print(string.format("Sectors per FAT: %d", sector0[23] + sector0[24] * 256))
    print(string.format("Sectors per track: %d", sector0[25] + sector0[26] * 256))
    print(string.format("Heads: %d", sector0[27] + sector0[28] * 256))
    
    -- Calculate where things should be:
    local bytesPerSector = sector0[12] + sector0[13] * 256
    local reservedSectors = sector0[15] + sector0[16] * 256
    local fatCount = sector0[17]
    local sectorsPerFat = sector0[23] + sector0[24] * 256
    local rootDirEntries = sector0[18] + sector0[19] * 256
    local rootDirSectors = math.ceil(rootDirEntries * 32 / bytesPerSector)
    
    local fat1Start = reservedSectors
    local rootDirStart = fat1Start + fatCount * sectorsPerFat
    local dataStart = rootDirStart + rootDirSectors
    
    print("\n=== Calculated Disk Layout ===")
    print(string.format("Reserved sectors: %d", reservedSectors))
    print(string.format("FAT 1 starts at: sector %d", fat1Start))
    print(string.format("Root dir starts at: sector %d", rootDirStart))
    print(string.format("Root dir size: %d sectors", rootDirSectors))
    print(string.format("Data area starts at: sector %d", dataStart))
    
    -- Check what's actually at those sectors
    print("\n=== What's Actually At Those Sectors ===")
    
    -- Sector 1 = should be first FAT
    local sector1 = fdc:readSector(1)
    if sector1 then
        local bytes = {}
        for i = 1, 16 do table.insert(bytes, string.format("%02X", sector1[i])) end
        print("Sector 1 (FAT1): " .. table.concat(bytes, " "))
    end
    
    -- Sector 2 = should be second FAT
    local sector2 = fdc:readSector(2)
    if sector2 then
        local bytes = {}
        for i = 1, 16 do table.insert(bytes, string.format("%02X", sector2[i])) end
        print("Sector 2 (FAT2): " .. table.concat(bytes, " "))
    end
    
    -- Sector 11 = should be root directory (2 reserved + 9 FAT = 11)
    local sector11 = fdc:readSector(11)
    if sector11 then
        print("Sector 11 (root dir):")
        local bytes = {}
        for i = 1, 32 do table.insert(bytes, string.format("%02X", sector11[i])) end
        print("  First 32: " .. table.concat(bytes, " "))
        
        -- Parse directory entry
        local name = ""
        for i = 0, 7 do local ch = sector11[i+1] if ch and ch > 0x1F and ch < 0x7F then name = name .. string.char(ch) end end
        local ext = ""
        for i = 8, 10 do local ch = sector11[i+1] if ch and ch > 0x1F and ch < 0x7F then ext = ext .. string.char(ch) end end
        print("  Entry 0: " .. name .. "." .. ext)
    end
    
    -- Now let's understand what FreeDOS BOOT SECTOR expects
    -- The boot sector at offset 0x1FE0 calculates:
    --   Reserved = 1 (at offset 0x0E)
    --   FATs = 2
    --   Sectors per FAT = 9
    --   Root dir entries = 224
    --   Root dir starts at: 1 + 2*9 = 19
    --   Root dir sectors = 224 * 32 / 512 = 14
    
    print("\n=== FreeDOS Boot Sector's Expected Layout ===")
    print("According to BPB in boot sector:")
    print("  Reserved: 1 sector")
    print("  FATs: 2, each 9 sectors")
    print("  Root dir starts at: 1 + 2*9 = 19")
    print("  Root dir size: 14 sectors")
    print("  Data area starts at: 19 + 14 = 33")
    
    -- Check sector 19
    local sector19 = fdc:readSector(19)
    if sector19 then
        print("\nSector 19 (what FreeDOS thinks is root dir):")
        local bytes = {}
        for i = 1, 32 do table.insert(bytes, string.format("%02X", sector19[i])) end
        print("  First 32: " .. table.concat(bytes, " "))
        
        -- Parse entries
        for entry = 0, 3 do
            local offset = entry * 32 + 1
            local name = ""
            for i = 0, 7 do 
                local ch = sector19[offset + i] 
                if ch and ch ~= 0x00 and ch ~= 0x20 then name = name .. string.char(ch) end 
            end
            local ext = ""
            for i = 8, 10 do 
                local ch = sector19[offset + i] 
                if ch and ch ~= 0x00 and ch ~= 0x20 then ext = ext .. string.char(ch) end 
            end
            if name ~= "" then
                print(string.format("  Entry %d: %s.%s", entry, name, ext))
            end
        end
    end
end

machine:shutdown()
print("\nDone.")