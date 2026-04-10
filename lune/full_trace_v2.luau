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
			BIOS_CALLS = true,
			CPU_STATE = false,
		},
	},
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FreeDOS Boot with ALL Tracing ===")
print("Watching for INT 13h (disk) and INT 10h (video) calls")
print("")

local startTime = os.clock()
local elapsed = 0
local bootRecord = nil
local lastStage = ""

while elapsed < 30 do
	elapsed = os.clock() - startTime
	local bootStage = machine:getBootStage()
	
	-- Get boot record once
	if not bootRecord and (bootStage == "RUNNING" or bootStage == "BOOT") then
		bootRecord = machine:getBootRecord()
	end
	
	-- Show stage changes
	if bootStage ~= lastStage then
		print(string.format("[t=%.1f] Stage: %s", elapsed, bootStage))
		lastStage = bootStage
		if bootStage == "RUNNING" and bootRecord then
			print(string.format("  kernelSectorCount: %d", bootRecord.kernelSectorCount or 0))
			print("  fileCount: " .. tostring(bootRecord.fileCount or 0))
		end
	end
	
	-- Capture screen periodically
	if math.floor(elapsed * 2) ~= math.floor((elapsed - 0.05) * 2) then
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
			
			local hasText = false
			local textPreview = ""
			for _, line in ipairs(frame.text:split("\n")) do
				if line:match("%S") then
					hasText = true
					textPreview = textPreview .. line:sub(1,40) .. " "
				end
			end
			
			if hasText and bootStage == "RUNNING" then
				print(string.format("[t=%.1f] %s", elapsed, textPreview))
			end
		end
	end
	
	if bootStage == "FAULT" then
		print("*** FAULT ***")
		break
	end
	
	if bootStage == "RUNNING" and elapsed > 5 then
		-- Give it a few seconds at RUNNING then show summary
		break
	end
	
	task.wait(0.05)
end

print("\n=== FINAL STATUS ===")
print("Final stage: " .. machine:getBootStage())

if bootRecord then
	print("\nBoot Record:")
	print("  kernelSectorCount: " .. tostring(bootRecord.kernelSectorCount))
	print("  fileCount: " .. tostring(bootRecord.fileCount))
end

-- Final screen
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
	
	print("\n=== FINAL SCREEN ===")
	for _, line in ipairs(frame.text:split("\n")) do
		if line:match("%S") then
			print("  " .. line:sub(1, 80))
		end
	end
end

print("\nDone.")