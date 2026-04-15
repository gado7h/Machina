-- Run with redirect and check screen
local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")
local task = require("@src/task")

-- Add redirect after boot sector load
local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")
local orig = BiosInterrupts._floppyReadSectors
BiosInterrupts._floppyReadSectors = function(self, cpu, drive)
    local result = orig(self, cpu, drive)
    
    -- After boot sector loads, redirect to proper entry
    local startLba = 0
    local cl = cpu:getReg8(0x31) -- CL
    local ch = cpu:getReg8(0x32) -- CH  
    local dh = cpu:getReg8(0x42) -- DH
    local cylinder = bit32.bor(bit32.band(ch, 0xFF), bit32.lshift(bit32.band(cl, 0xC0), 2))
    local sector = bit32.band(cl, 0x3F)
    local head = dh
    local spt = 18
    local heads = 2
    startLba = ((cylinder * heads + head) * spt) + (sector - 1)
    
    local buffer = cpu:getReg16(2) -- BX
    local es = cpu.seg.ES
    local bufferAddress = es * 16 + buffer
    
    if startLba == 0 and bufferAddress == 0x7C00 then
        cpu:setRedirect(0x1FE0, 0x0040)  -- Redirect to boot entry after reloc
    end
    
    return result
end

local machine = Runner.createBootMachine({
    X86 = { IMAGE = { PROVIDER = "freeDOS" } },
})

machine:setFramePresenter(function() end)
machine:powerOn()

task.wait(2.0)

local frame = FrameCapture.capture(machine)
print("=== Screen after 2s with redirect ===")
print(frame.text and frame.text:sub(1, 80) or "empty")

machine:shutdown()