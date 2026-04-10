local Runner = require("../_runner")
local FrameCapture = require("../frame_capture")

local function formatFrameText(frame)
	if not frame.cells or #frame.cells == 0 then
		return ""
	end
	local lines = {}
	for row = 0, 24 do
		local line = {}
		for col = 0, 79 do
			local idx = row * 80 + col + 1
			local cell = frame.cells[idx]
			if cell then
				local char = cell.char
				if type(char) == "number" then
					char = string.char(char)
				end
				line[col + 1] = char or " "
			else
				line[col + 1] = " "
			end
		end
		table.insert(lines, table.concat(line))
	end
	return table.concat(lines, "\n")
end

local function runDiagnosticTest()
	print("=== FreeDOS Boot Diagnostic Test ===")
	print("Testing boot with CPU trace enabled...")
	
	local machine = Runner.createBootMachine({
		X86 = {
			IMAGE = {
				PROVIDER = "freeDOS",
			},
			TRACE = {
				ENABLED = true,
				CPU_STATE = true,
			},
		},
	})

	machine:setFramePresenter(function() end)
	machine:powerOn()
	
	task.wait(0.3)
	
	print("\n=== Checking boot stage and CPU state ===")
	local bootStage = machine:getBootStage()
	print("Boot stage: " .. bootStage)
	
	if machine.cpu and machine.cpu.stats then
		print("CPU cycles: " .. tostring(machine.cpu.stats.cycles))
		print("CPU instructions: " .. tostring(machine.cpu.stats.instructions))
	end
	
	local vram = FrameCapture.getVRAMAddress(machine)
	if vram then
		local frameText = formatFrameText({
			cells = {},
			width = 80,
			height = 25,
		})
		for i = 0, 80 * 25 - 1 do
			local charAddr = i * 2
			local char = vram[charAddr] or 32
			if type(char) == "number" then
				char = string.char(char)
			end
			frameText = frameText .. (char or " ")
		end
		print("\n=== Screen content (first 200 chars) ===")
		local screenText = ""
		for i = 0, math.min(199, 80 * 25 - 1) do
			local charAddr = i * 2
			local char = vram[charAddr] or 32
			if type(char) == "number" then
				char = string.char(char)
			end
			screenText = screenText .. (char or " ")
		end
		print(screenText)
	end
	
	task.wait(0.5)
	
	print("\n=== After 0.8 seconds total ===")
	if machine.cpu and machine.cpu.stats then
		print("CPU cycles: " .. tostring(machine.cpu.stats.cycles))
		print("CPU interrupts: " .. tostring(machine.cpu.stats.interrupts))
	end
	
	bootStage = machine:getBootStage()
	print("Boot stage: " .. bootStage)
	
	print("\n=== Final screen ===")
	if vram then
		local lines = {}
		for row = 0, 4 do
			local line = {}
			for col = 0, 79 do
				local idx = row * 80 + col + 1
				local cellChar = vram[idx * 2] or 32
				if type(cellChar) == "number" then
					cellChar = string.char(cellChar)
				end
				line[col + 1] = cellChar or " "
			end
			table.insert(lines, table.concat(line))
		end
		print(table.concat(lines, "\n"))
	end
	
	print("\n=== Done ===")
end

runDiagnosticTest()
