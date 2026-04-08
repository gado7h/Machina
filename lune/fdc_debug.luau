-- Check FDC initialization and image loading

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FDC Debug ===")

task.wait(0.5)

-- Check FDC state
local fdc = machine.fdc
print("FDC: " .. tostring(fdc))
print("FDC _sectors: " .. tostring(fdc and fdc._sectors))
print("FDC _sectors count: " .. (fdc and fdc._sectors and #fdc._sectors or 0))
print("FDC _mediaType: " .. tostring(fdc and fdc._mediaType))

-- Get media info
if fdc and fdc.getMediaType then
    local media = fdc:getMediaType()
    print("Media: tracks=" .. (media and media.tracks or "nil") .. 
          " heads=" .. (media and media.heads or "nil") ..
          " sectors=" .. (media and media.sectors or "nil"))
end

if fdc and fdc.getTotalSectors then
    print("Total sectors: " .. fdc:getTotalSectors())
end

-- Check sectors directly
if fdc and fdc._sectors then
    print("\n=== First few bytes of FDC _sectors ===")
    local bytes = {}
    for i = 1, 32 do
        table.insert(bytes, string.format("%02X", fdc._sectors[i] or 0))
    end
    print("Sectors[1-32]: " .. table.concat(bytes, " "))
    
    -- Check sector 1 (LBA 0) - should be boot sector
    print("\nSector 0 (boot sector):")
    local sector0 = fdc._sectors[1] or fdc._sectors[0]
    if sector0 then
        local b = {}
        for i = 1, 16 do
            table.insert(b, string.format("%02X", sector0[i] or 0))
        end
        print("  " .. table.concat(b, " "))
    else
        print("  nil!")
    end
    
    -- Check what happens at offset for sector 1 (bytes 512-1023)
    print("\nBytes at offset 512 (sector 1):")
    local b = {}
    for i = 513, 528 do
        table.insert(b, string.format("%02X", fdc._sectors[i] or 0))
    end
    print("  " .. table.concat(b, " "))
    
    -- Check offset for LBA 19 (root dir)
    -- LBA 19 * 512 = 9728
    print("\nBytes at offset 9728 (LBA 19):")
    local b = {}
    for i = 9729, 9744 do
        table.insert(b, string.format("%02X", fdc._sectors[i] or 0))
    end
    print("  " .. table.concat(b, " "))
end

-- Check memory at 0x200
local cpu = machine.cpu
print("\n=== CPU memory at 0x200 ===")
local b = {}
for i = 0, 15 do
    table.insert(b, string.format("%02X", cpu:readPhysical8(0x200 + i)))
end
print(table.concat(b, " "))

-- Maybe there's a problem with how sectors are being read?
-- Let me check if readSector returns correct data
if fdc then
    print("\n=== Testing readSector directly ===")
    local s0 = fdc:readSector(0)
    if s0 then
        local b = {}
        for i = 1, 8 do table.insert(b, string.format("%02X", s0[i])) end
        print("readSector(0): " .. table.concat(b, " "))
    else
        print("readSector(0): nil")
    end
    
    local s1 = fdc:readSector(1)
    if s1 then
        local b = {}
        for i = 1, 8 do table.insert(b, string.format("%02X", s1[i])) end
        print("readSector(1): " .. table.concat(b, " "))
    else
        print("readSector(1): nil")
    end
    
    local s19 = fdc:readSector(19)
    if s19 then
        local b = {}
        for i = 1, 8 do table.insert(b, string.format("%02X", s19[i])) end
        print("readSector(19): " .. table.concat(b, " "))
    else
        print("readSector(19): nil")
    end
end

machine:shutdown()
print("\nDone.")