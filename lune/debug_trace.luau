-- Complete boot sector analysis

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

print("=== Complete Boot Analysis ===")

-- Wait for boot to progress
local startTime = os.clock()
local deadline = os.clock() + 5

while os.clock() < deadline do
    local cpu = machine.cpu
    if cpu then
        local cs = cpu.seg.CS
        local ip = cpu.ip
        
        -- Only trace within the boot sector code (0x1FE0)
        if cs == 0x1FE0 and ip < 0x200 then
            local ax = cpu:getReg16(0)
            local bx = cpu:getReg16(1)
            local cx = cpu:getReg16(2)
            local dx = cpu:getReg16(3)
            local si = cpu:getReg16(6)
            local di = cpu:getReg16(7)
            local ds = cpu.seg.DS
            
            -- Also check what's at the disk read buffer
            local bufferSample = {}
            for i = 0, 7 do
                local v = cpu:readPhysical8(0x200 + i)
                table.insert(bufferSample, string.format("%02X", v))
            end
            
            print(string.format("t=%.2f %04X:%04X AX=%04X BX=%04X CX=%04X DX=%04X SI=%04X DI=%04X DS=%04X Buf=%s",
                os.clock() - startTime, cs, ip, ax, bx, cx, dx, si, di, ds, table.concat(bufferSample, " ")))
        end
    end
    
    local stage = machine:getBootStage()
    if stage == "FAULT" then
        print("*** FAULT ***")
        break
    end
    
    task.wait(0.03)
end

machine:shutdown()
print("\nDone.")