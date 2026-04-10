local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")
local task = require("@src/task")

local machine = Runner.createBootMachine({
	X86 = {
		IMAGE = {
			PROVIDER = "freeDOS",
		},
		TRACE = {
			ENABLED = false,
		},
	},
})

machine:setFramePresenter(function() end)
machine:powerOn()

print("=== FreeDOS Boot Analysis ===")

-- Wait longer to let kernel load
task.wait(5)

local vram = FrameCapture.getVRAMAddress(machine)

-- Find all non-space characters
print("\n=== Non-space characters in VRAM ===")
local found = {}
for addr = 0, 80*25*2 - 1, 2 do
	local char = vram and vram[addr] or 0
	if char > 32 and char < 255 then
		local row = math.floor(addr / 160)
		local col = math.floor((addr % 160) / 2)
		table.insert(found, string.format("row%d col%d: '%s' (0x%02X)", row, col, string.char(char), char))
	end
end

for i = 1, math.min(30, #found) do
	print(found[i])
end

if #found > 30 then
	print(string.format("... and %d more", #found - 30))
end

-- Check boot record
local record = machine:getBootRecord()
print("\n=== BOOT RECORD ===")
if record then
	print("kernelSectorCount: " .. tostring(record.kernelSectorCount))
	print("fileCount: " .. tostring(record.fileCount))
	
	-- Show layout
	if record.layout then
		print("\nLayout:")
		for k, v in pairs(record.layout) do
			print("  " .. k .. ": " .. tostring(v))
		end
	end
end

-- CPU stats
local cpu = machine.cpu
if cpu and cpu.stats then
	print("\n=== CPU STATS ===")
	print("instructions: " .. tostring(cpu.stats.instructions))
end

print("\nDone.")