local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")
local task = require("@src/task")

local function formatFrameText(frame)
	if not frame.cells then
		return "No cells"
	end
	
	local lines = {}
	for row = 0, frame.height - 1 do
		local line = {}
		for col = 0, frame.width - 1 do
			local idx = row * frame.width + col + 1
			local cell = frame.cells[idx]
			if cell and cell.char then
				local char = cell.char
				if char == 0 or char == 255 then
					char = 32
				end
				table.insert(line, string.char(char))
			else
				table.insert(line, " ")
			end
		end
		local lineStr = table.concat(line)
		table.insert(lines, lineStr)
	end
	
	return table.concat(lines, "\n")
end

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

local startTime = os.clock()
local elapsed = 0

while elapsed < 30 do
	elapsed = os.clock() - startTime
	local bootStage = machine:getBootStage()
	
	-- Capture screen at intervals
	if math.floor(elapsed) ~= math.floor(elapsed - 0.1) then
		local vram = FrameCapture.getVRAMAddress(machine)
		if vram then
			local cells = {}
			for i = 0, 80 * 25 - 1 do
				local charAddr = i * 2
				local char = vram[charAddr] or 32
				cells[i + 1] = { char = char }
			end
			local frame = { cells = cells, width = 80, height = 25 }
			frame.text = formatFrameText(frame)
			
			-- Show only non-empty lines
			local hasText = false
			for _, line in ipairs(frame.text:split("\n")) do
				if line:match("%S") then
					hasText = true
					break
				end
			end
			
			if hasText then
				print(string.format("t=%.1f [%s]", elapsed, bootStage))
				for _, line in ipairs(frame.text:split("\n")) do
					if line:match("%S") then
						print("  " .. line:sub(1, 80))
					end
				end
			end
		end
	end
	
	if bootStage == "FAULT" then
		print("*** FAULT ***")
		break
	end
	
	task.wait(0.1)
end

print("\nDone.")