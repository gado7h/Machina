local function convertImageToHex(imagePath, outputPath)
    local file = io.open(imagePath, "rb")
    if not file then
        error("Cannot open image: " .. imagePath)
    end
    
    local bytes = {}
    local count = 0
    
    while true do
        local byte = file:read(1)
        if not byte then
            break
        end
        count = count + 1
        table.insert(bytes, string.byte(byte))
    end
    file:close()
    
    print(string.format("Read %d bytes from %s", count, imagePath))
    
    -- Format as hex table
    local lines = {}
    table.insert(lines, "-- Auto-generated from " .. imagePath)
    table.insert(lines, "-- FreeDOS 1.4 Floppy Edition (1.44MB)")
    table.insert(lines, "-- Size: " .. count .. " bytes (" .. math.floor(count/1024) .. " KB)")
    table.insert(lines, "-- Do not edit manually. Re-run this script to regenerate.")
    table.insert(lines, "")
    table.insert(lines, "return {")
    
    local bytesPerLine = 16
    for i = 1, #bytes, bytesPerLine do
        local lineParts = {}
        for j = 0, bytesPerLine - 1 do
            local idx = i + j
            if idx <= #bytes then
                table.insert(lineParts, string.format("0x%02X", bytes[idx]))
            end
        end
        table.insert(lines, "\t" .. table.concat(lineParts, ", "))
    end
    
    table.insert(lines, "}")
    
    local output = io.open(outputPath, "w")
    output:write(table.concat(lines, ",\n"))
    output:close()
    
    print(string.format("Wrote hex to %s", outputPath))
    return count
end

local imagePath = arg[1] or "144m/x86BOOT.img"
local outputPath = arg[2] or "FreeDOSBootHex.luau"

local count = convertImageToHex(imagePath, outputPath)
print("Done! Generated " .. count .. " bytes")