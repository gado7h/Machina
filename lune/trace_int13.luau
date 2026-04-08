-- Real-time trace of INT 13h calls from FreeDOS boot sector

local Runner = require("./_runner")
local task = require("@src/task")

-- Monkey-patch at load time
package.loaded["@src/platforms/x86/BiosInterrupts"] = nil
local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")
local REG8 = BiosInterrupts.REG8

local floppyReadCount = 0

local original_floppyReadSectors = BiosInterrupts._floppyReadSectors
BiosInterrupts._floppyReadSectors = function(self, cpu, drive)
    -- Extract parameters
    local count = cpu:getReg8(REG8.AL)  -- AL
    local cl = cpu:getReg8(REG8.CL)     -- CL  
    local ch = cpu:getReg8(REG8.CH)     -- CH
    local dh = cpu:getReg8(REG8.DH)     -- DH
    
    local cylinder = bit32.bor(bit32.band(ch, 0xFF), bit32.lshift(bit32.band(cl, 0xC0), 2))
    local sector = bit32.band(cl, 0x3F)
    local head = dh
    
    floppyReadCount = floppyReadCount + 1
    
    -- Calculate LBA
    local spt = 18
    local heads = 2
    local lba = ((cylinder * heads + head) * spt) + (sector - 1)
    
    -- Print details
    print(string.format("[%d] INT 13h AH=02: cyl=%d head=%d sec=%d -> LBA=%d count=%d ES:BX=%04X:%04X",
        floppyReadCount, cylinder, head, sector, lba, count,
        cpu.seg.ES, cpu:getReg16(REG8.BX)))
    
    return original_floppyReadSectors(self, cpu, drive)
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

print("=== Real-time INT 13h Trace ===")

local startTime = os.clock()
while os.clock() - startTime < 10 do
    local stage = machine:getBootStage()
    if stage == "FAULT" then
        print("*** FAULT at " .. os.clock() - startTime .. "s ***")
        break
    end
    if stage == "RUNNING" and floppyReadCount > 5 then
        break
    end
    task.wait(0.02)
end

print("\nTotal floppy reads: " .. floppyReadCount)

machine:shutdown()
print("\nDone.")