local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")
local Keyboard = require("./keyboard")
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
	},
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FreeDOS with Keyboard Input Test ===")

local kbd = machine.keyboard
if kbd then
	Keyboard.typeAll(machine, "1")
	print("Injected key '1' at startup")
end

local startTime = os.clock()

while true do
	local elapsed = os.clock() - startTime
	local bootStage = machine:getBootStage()
	
	local vram = FrameCapture.getVRAMAddress(machine)
	local frame
	if vram then
		local cells = {}
		for i = 0, 80 * 25 - 1 do
			local charAddr = i * 2
			local attrAddr = charAddr + 1
			local char = vram[charAddr] or 32
			local attr = vram[attrAddr] or 7
			cells[i + 1] = { char = char, attr = attr }
		end
		frame = { cells = cells, width = 80, height = 25, text = "" }
	else
		frame = { cells = {}, width = 80, height = 25 }
	end
	
	if frame.cells and #frame.cells > 0 then
		frame.text = formatFrameText(frame)
	end
	
	-- Print updates every 3 seconds
	if math.floor(elapsed) % 3 == 0 and elapsed > 1 then
		local lines = {}
		for _, line in ipairs(frame.text:split("\n")) do
			if line:match("%S") then
				table.insert(lines, line)
			end
		end
		local display = #lines > 0 and table.concat(lines, " | ") or "(empty)"
		print(string.format("t=%.1f | Stage: %s | %s", elapsed, bootStage, display:sub(1, 120)))
	end
	
	if bootStage == "FAULT" then
		print("*** BOOT FAULTED ***")
		break
	end
	
	if elapsed >= 30 then
		print(string.format("\n=== Final frame at t=%.1f ===", elapsed))
		print(formatFrameText(frame))
		break
	end

	task.wait(0.1)
end

machine:shutdown()
print("\nDone.")