-- Trace CPU state when reading root directory

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

print("=== Detailed CPU State Trace ===")

local startTime = os.clock()
local foundRootDirRead = false
local deadline = os.clock() + 5

while os.clock() < deadline do
    local cpu = machine.cpu
    if cpu then
        local cs = cpu.seg.CS
        local ip = cpu.ip
        
        -- Check for code around where disk read parameters are set
        -- Look for instructions that set AX for disk read
        local ax = cpu:getReg16(0)  -- AX
        local bx = cpu:getReg16(1)  -- BX  
        local cx = cpu:getReg16(2)  -- CX
        local dx = cpu:getReg16(3)  -- DX
        
        -- Sample memory at root dir
        local rootFirst8 = {}
        for i = 0, 7 do
            local v = cpu:readPhysical8(0x200 + i)
            table.insert(rootFirst8, string.format("%02X", v))
        end
        
        -- Print when AX changes significantly or at specific IPs
        if cs == 0x1FE0 and ip > 0x50 and ip < 0x100 then
            print(string.format("t=%.2f CS:IP=%04X:%04X AX=%04X BX=%04X CX=%04X DX=%04X Root=%s",
                os.clock() - startTime, cs, ip, ax, bx, cx, dx, table.concat(rootFirst8, " ")))
        end
    end
    
    local stage = machine:getBootStage()
    if stage == "FAULT" then
        print("*** FAULT ***")
        break
    end
    
    task.wait(0.02)
end

machine:shutdown()
print("\nDone.")