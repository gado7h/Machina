-- Compare what should be read vs what is being read

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

print("=== Sector Comparison ===")

-- Wait for boot to start
task.wait(1)

local fdc = machine.fdc
local cpu = machine.cpu

if fdc and cpu then
    -- What FreeDOS BOOT SECTOR thinks:
    -- Root directory should be at sector 19 (LBA = 19 according to BPB: 1 + 2*9 = 19)
    
    print("According to FreeDOS BPB:")
    print("  Reserved: 1 sector")
    print("  FATs: 2 * 9 sectors = 18")
    print("  Root dir starts at: 1 + 18 = 19")
    
    -- Check sector 19 (what FreeDOS thinks is root dir)
    local sector19 = fdc:readSector(19)
    if sector19 then
        print("\n--- What is actually at LBA 19 (root dir) ---")
        print("First 32 bytes:")
        local bytes = {}
        for i = 1, 32 do table.insert(bytes, string.format("%02X", sector19[i])) end
        print("  " .. table.concat(bytes, " "))
        
        -- Directory entry parsing
        print("\nDirectory entries:")
        for entry = 0, 5 do
            local offset = (entry * 32) + 1
            local nameBytes = {}
            for i = 0, 10 do table.insert(nameBytes, sector19[offset + i] or 0) end
            
            -- Check if entry is valid
            if nameBytes[1] ~= 0x00 and nameBytes[1] ~= 0xE5 then
                local name = ""
                for i = 1, 8 do 
                    if nameBytes[i] >= 0x20 and nameBytes[i] < 0x7F then
                        name = name .. string.char(nameBytes[i])
                    end
                end
                local ext = ""
                for i = 9, 11 do
                    if nameBytes[i] >= 0x20 and nameBytes[i] < 0x7F then
                        ext = ext .. string.char(nameBytes[i])
                    end
                end
                local size = (nameBytes[28] or 0) + (nameBytes[29] or 0) * 256 + (nameBytes[30] or 0) * 65536
                print(string.format("  [%d] %-8s.%-3s size=%d", entry, name, ext, size))
            end
        end
    end
    
    -- Now let's check what LBA the boot sector is actually reading
    -- Based on boot code analysis, it reads cylinder 0, head 0, sector 1
    -- which should be LBA 0 (first sector after boot sector)
    
    print("\n--- What is at LBA 0 (first data sector, typically FAT or root) ---")
    local sector0data = fdc:readSector(0)
    if sector0data then
        local bytes = {}
        for i = 1, 32 do table.insert(bytes, string.format("%02X", sector0data[i])) end
        print("  " .. table.concat(bytes, " "))
    end
    
    print("\n--- What is at LBA 1 ---")
    local sector1data = fdc:readSector(1)
    if sector1data then
        local bytes = {}
        for i = 1, 32 do table.insert(bytes, string.format("%02X", sector1data[i])) end
        print("  " .. table.concat(bytes, " "))
    end
    
    -- Check the CPU's view of memory at 0x200
    print("\n--- What CPU sees at 0x0000:0200 (root dir buffer) ---")
    local memBytes = {}
    for i = 0, 31 do
        local v = cpu:readPhysical8(0x200 + i)
        table.insert(memBytes, string.format("%02X", v))
    end
    print("  " .. table.concat(memBytes, " "))
end

machine:shutdown()
print("\nDone.")