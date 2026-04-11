-- Enable BIOS tracing for disk operations

local Runner = require("./_runner")
local task = require("@src/task")

local machine = Runner.createBootMachine({
    X86 = {
        IMAGE = {
            PROVIDER = "freeDOS",
        },
        TRACE = {
            ENABLED = true,
            DISK = true,
            CPU_STATE = false,
        },
    },
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FreeDOS Boot with Disk Trace ===")
print("Waiting for boot process...")

local startTime = os.clock()

-- Capture framebuffer periodically
local vram = nil
local function getScreenText()
    if not machine.gpu.getTextModeBuffer then return "" end
    local buf = machine.gpu:getTextModeBuffer()
    if not buf then return "" end
    local lines = {}
    for row = 0, 24 do
        local line = ""
        for col = 0, 79 do
            local idx = row * 80 + col
            local char = buf[idx * 2 + 1]
            if char and char > 0 and char < 256 then
                line = line .. string.char(char)
            else
                line = line .. " "
            end
        end
        if line:match("%S") then
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

while os.clock() - startTime < 15 do
    task.wait(0.1)
    local stage = machine:getBootStage()
    local elapsed = os.clock() - startTime
    
    -- Show screen every 2 seconds
    if math.floor(elapsed) % 2 == 0 and elapsed > 0.5 then
        local screen = getScreenText()
        if screen ~= "" then
            print(string.format("\n--- t=%.1f [%s] ---", elapsed, stage))
            for _, line in ipairs(screen:split("\n")) do
                if line:match("%S") then
                    print(line:sub(1, 80))
                end
            end
        end
    end
    
    if stage == "FAULT" then
        print("*** FAULT ***")
        break
    end
    
    task.wait(0.1)
end

machine:shutdown()
print("\nDone.")