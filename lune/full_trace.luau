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
			CPU_STATE = true,      -- Show boot sector execution
			BIOS_CALLS = true,     -- Show INT 10h, 13h, 16h calls
			DISK = true,           -- Show disk reads/writes
			IRQ_ROUTING = true,    -- Show interrupt routing
			DISK = true,           -- Disk operations
		},
	},
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FreeDOS Boot FULL TRACING ===")
print("This will show all BIOS calls and disk operations")
print("")

local startTime = os.clock()
local elapsed = 0

while elapsed < 15 do
	elapsed = os.clock() - startTime
	local bootStage = machine:getBootStage()
	
	-- Capture screen at 1 second intervals
	if math.floor(elapsed) ~= math.floor(elapsed - 0.05) then
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
			for _, line in ipairs(frame.text:split("\n")) do
				if line:match("%S") then
					hasText = true
					break
				end
			end
			
			if hasText then
				print(string.format("\n=== t=%.1f [%s] ===", elapsed, bootStage))
				for _, line in ipairs(frame.text:split("\n")) do
					if line:match("%S") then
						print("  " .. line:sub(1, 80))
					end
				end
			end
		end
	end
	
	-- Show boot record at end
	if bootStage == "RUNNING" then
		local record = machine:getBootRecord()
		print(string.format("\n=== BOOT RECORD at t=%.1f ===", elapsed))
		if record then
			print("  profile: " .. tostring(record.profile))
			print("  bootDevice: " .. tostring(record.bootDevice))
			print("  kernelSectorStart: " .. tostring(record.kernelSectorStart))
			print("  kernelSectorCount: " .. tostring(record.kernelSectorCount))
			print("  fileCount: " .. tostring(record.fileCount))
			print("  fsSuperSector: " .. tostring(record.fsSuperSector))
			print("  rootDirSector: " .. tostring(record.rootDirSector))
			print("  dataStartSector: " .. tostring(record.dataStartSector))
		end
		break
	end
	
	if bootStage == "FAULT" then
		local record = machine:getBootRecord()
		print("*** FAULT ***")
		if record and record.faultReason then
			print("Fault reason: " .. tostring(record.faultReason))
		end
		break
	end
	
	task.wait(0.05)
end

if elapsed >= 15 then
	local record = machine:getBootRecord()
	print(string.format("\n=== TIMEOUT at t=%.1f ===", elapsed))
	print("Boot stage: " .. machine:getBootStage())
	
	if record then
		print("\n=== FINAL BOOT RECORD ===")
		print("  profile: " .. tostring(record.profile))
		print("  bootDevice: " .. tostring(record.bootDevice))
		print("  kernelSectorStart: " .. tostring(record.kernelSectorStart))
		print("  kernelSectorCount: " .. tostring(record.kernelSectorCount))
		print("  fileCount: " .. tostring(record.fileCount))
		print("  fsSuperSector: " .. tostring(record.fsSuperSector))
		print("  rootDirSector: " .. tostring(record.rootDirSector))
		print("  rootDirSectorCount: " .. tostring(record.rootDirSectorCount))
		print("  dataStartSector: " .. tostring(record.dataStartSector))
	end
	
	-- Show final screen
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
end

print("\nDone.")