-- Debug: Check what's in memory where FreeDOS expects root directory

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

print("=== FreeDOS Memory Debug ===")

-- Wait for boot to start
local startTime = os.clock()
while os.clock() - startTime < 5 do
    local stage = machine:getBootStage()
    if stage == "FAULT" then
        print("Fault detected!")
        break
    end
    if stage == "RUNNING" then
        break
    end
    task.wait(0.05)
end

-- After boot is running, check what the boot sector read
local cpu = machine.cpu
if cpu then
    print("\n=== CPU State ===")
    print(string.format("CS:IP = %04X:%04X", cpu.seg.CS, cpu.ip))
    print(string.format("AX=%04X BX=%04X CX=%04X DX=%04X", 
        cpu:getReg16(0), cpu:getReg16(1), cpu:getReg16(2), cpu:getReg16(3)))
    
    -- Check memory at 0x0000:0200 where root directory should be loaded
    print("\n=== Memory at 0x0000:0200 (root dir buffer) ===")
    for row = 0, 3 do
        local bytes = {}
        for i = 0, 15 do
            local addr = 0x200 + row * 16 + i
            local val = cpu:readPhysical8(addr)
            table.insert(bytes, string.format("%02X", val))
        end
        print(string.format("  %04X: %s", 0x200 + row * 16, table.concat(bytes, " ")))
    end
    
    -- Check memory at 0x1FE0:0000 where boot sector is
    print("\n=== Memory at 0x1FE0:0000 (relocated boot sector) ===")
    for row = 0, 2 do
        local bytes = {}
        for i = 0, 15 do
            local seg = 0x1FE0
            local off = row * 16 + i
            local val = cpu:readMem8(seg, off)
            table.insert(bytes, string.format("%02X", val))
        end
        print(string.format("  %04X:%04X: %s", 0x1FE0, row * 16, table.concat(bytes, " ")))
    end
end

machine:shutdown()
print("\nDone.")