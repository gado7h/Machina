-- Trace exactly what's being passed to INT 13h

local Runner = require("./_runner")
local task = require("@src/task")

-- We need to patch the _floppyReadSectors function
package.loaded["@src/platforms/x86/BiosInterrupts"] = nil
local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")
local REG8 = BiosInterrupts.REG8

local readCount = 0

local original = BiosInterrupts._floppyReadSectors
BiosInterrupts._floppyReadSectors = function(self, cpu, drive)
    local count = cpu:getReg8(REG8.AL)
    local cl = cpu:getReg8(REG8.CL)
    local ch = cpu:getReg8(REG8.CH)
    local dh = cpu:getReg8(REG8.DH)
    local dl = cpu:getReg8(REG8.DL)
    local es = cpu.seg.ES
    local bx = cpu:getReg16(REG8.BX)
    
    local cylinder = bit32.bor(bit32.band(ch, 0xFF), bit32.lshift(bit32.band(cl, 0xC0), 2))
    local sector = bit32.band(cl, 0x3F)
    local head = dh
    
    local spt = 18
    local heads = 2
    local lba = ((cylinder * heads + head) * spt) + (sector - 1)
    
    readCount = readCount + 1
    print(string.format("[%d] INT13h AH=02: CHS=%d/%d/%d LBA=%d count=%d ES:BX=%04X:%04X",
        readCount, cylinder, head, sector, lba, count, es, bx))
    
    local result = original(self, cpu, drive)
    
    -- After the read, check what was written
    if result then
        local first8 = {}
        for i = 0, 7 do
            local v = cpu:readPhysical8(bx + i)
            table.insert(first8, string.format("%02X", v))
        end
        print(string.format("    -> Memory at %04X:%04X = %s", es, bx, table.concat(first8, " ")))
    end
    
    return result
end

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = { PROVIDER = "freeDOS" },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== INT 13h Trace ===")

local startTime = os.clock()
while os.clock() - startTime < 8 do
    local stage = machine:getBootStage()
    if stage == "FAULT" or stage == "RUNNING" then
        break
    end
    task.wait(0.05)
end

print("\nTotal reads: " .. readCount)

machine:shutdown()
print("Done.")