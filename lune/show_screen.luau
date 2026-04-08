local task = require("@src/task")
local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")

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

local function runLiveTest(waitSeconds)
	local machine = Runner.createBootMachine({
		X86 = {
			IMAGE = {
				PROVIDER = "freeDOS",
			},
		},
	})

	machine:setFramePresenter(function() end)
	machine:powerOn()

	print(string.format("=== Live FreeDOS Screen (t=0.0) ==="))
	print("Booting...")

	local startTime = os.clock()
	local lastText = ""
	local updateInterval = 0.5
	local nextUpdate = 0

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
		else
			frame.text = ""
		end
		
		if elapsed >= nextUpdate then
			local currentText = frame.text or ""
			if currentText ~= lastText then
				print(string.format("\n--- t=%.1f | Stage: %s ---", elapsed, bootStage))
				print(formatFrameText(frame))
				lastText = currentText
			else
				print(string.format("t=%.1f | %s | (no change)", elapsed, bootStage))
			end
			nextUpdate = elapsed + updateInterval
		end

		if bootStage == "FAULT" then
			print("\n*** BOOT FAULTED ***")
			break
		end

		if elapsed >= waitSeconds then
			print(string.format("\n=== Final frame at t=%.1f ===", elapsed))
			print(formatFrameText(frame))
			break
		end

		task.wait(0.05)
	end

	machine:shutdown()
end

local waitTime = 15

print(string.format("Running live test for %d seconds...", waitTime))
runLiveTest(waitTime)
print("\nDone.")