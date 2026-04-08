-- Trace what's being read into memory

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

print("=== FreeDOS Boot Sector Execution Trace ===")

-- Wait a bit for boot to start
local startTime = os.clock()
local checkPoints = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0}
local nextCheck = 1

while os.clock() - startTime < 5 do
    local elapsed = os.clock() - startTime
    
    -- Check at specific intervals
    if nextCheck <= #checkPoints and elapsed >= checkPoints[nextCheck] then
        nextCheck = nextCheck + 1
        
        local cpu = machine.cpu
        if cpu then
            local cs = cpu.seg.CS
            local ip = cpu.ip
            
            -- Sample memory at the root dir buffer (0x0000:0200)
            local memSample = {}
            for i = 0, 15 do
                local val = cpu:readPhysical8(0x200 + i)
                table.insert(memSample, string.format("%02X", val))
            end
            
            print(string.format("t=%.1f CS:IP=%04X:%04X RootDir[0-15]: %s", 
                elapsed, cs, ip, table.concat(memSample, " ")))
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