-- Trace INT 13h calls with full register state
local Runner = require("./_runner")
local task = require("@src/task")

local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")
local REG8 = BiosInterrupts.REG8

-- Patch to trace
local orig = BiosInterrupts._floppyReadSectors
BiosInterrupts._floppyReadSectors = function(self, cpu, drive)
    local result = orig(self, cpu, drive)
    
    local al = cpu:getReg8(REG8.AL)
    local cl = cpu:getReg8(REG8.CL)
    local ch = cpu:getReg8(REG8.CH)
    local dh = cpu:getReg8(REG8.DH)
    local bx = cpu:getReg16(2)
    local es = cpu.seg.ES
    
    -- Calculate CHS
    local sectors_per_track = 18
    local heads = 2
    local cylinder = ((cl // 64) * 256 + ch) % 256
    local sector = cl % 64
    local head = dh % 2
    local lba = ((cylinder * heads + head) * sectors_per_track) + (sector - 1)
    
    print(string.format("[INT13] AL=%02X CH=%02X CL=%02X DH=%02X BX=%04X ES=%04X -> LBA=%d", 
        al, ch, cl, dh, bx, es, lba))
    
    return result
end

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(3.0)

machine:shutdown()