-- Deep debug: trace exactly what CHS values FreeDOS uses for disk reads

local Runner = require("./_runner")
local task = require("@src/task")

-- Save original function and patch
local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")

local original_floppyReadSectors = BiosInterrupts._floppyReadSectors

local trace = {}

BiosInterrupts._floppyReadSectors = function(self, cpu, drive)
    -- Extract parameters before the call
    local count = cpu:getReg8(REG8.AL)
    local cl = cpu:getReg8(REG8.CL)
    local ch = cpu:getReg8(REG8.CH)
    local dh = cpu:getReg8(REG8.DH)
    local dl = cpu:getReg8(REG8.DL)
    
    local cylinder = bit32.bor(bit32.band(ch, 0xFF), bit32.lshift(bit32.band(cl, 0xC0), 2))
    local sector = bit32.band(cl, 0x3F)
    local head = dh
    
    -- Calculate LBA the emulator will use
    local spt = self.x86.FLOPPY_SECTORS or 18
    local heads = self.x86.FLOPPY_HEADS or 2
    local startLba = ((cylinder * heads + head) * spt) + (sector - 1)
    
    local entry = {
        count = count,
        cylinder = cylinder,
        head = head,
        sector = sector,
        ch = ch,
        cl = cl,
        dh = dh,
        dl = dl,
        lba = startLba,
    }
    trace[#trace + 1] = entry
    
    print(string.format("INT 13h AH=02: cyl=%d head=%d sec=%d (CH=%02X CL=%02X DH=%02X) -> LBA=%d count=%d",
        cylinder, head, sector, ch, cl, dh, startLba, count))
    
    -- Call original
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

print("=== FreeDOS CHS Disk Read Trace ===")

local deadline = os.clock() + 10
while os.clock() < deadline do
    local stage = machine:getBootStage()
    if stage == "FAULT" then
        print("*** FAULT ***")
        break
    end
    if stage == "RUNNING" then
        break
    end
    task.wait(0.05)
end

print("\n=== Summary of Disk Reads ===")
for i, e in ipairs(trace) do
    print(string.format("  [%d] cyl=%d head=%d sec=%d -> LBA=%d count=%d", 
        i, e.cylinder, e.head, e.sector, e.lba, e.count))
end

machine:shutdown()
print("\nDone.")