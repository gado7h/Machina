local Runner = require("./_runner")
local task = require("@src/task")

local machine, config = Runner.createDiagnosticMachine({
	X86 = {
		IMAGE = {
			PROVIDER = "freeDOS",
		},
		TRACE = {
			ENABLED = true,
			BIOS_CALLS = true,
			DISK = true,
		},
	},
})

machine:setFramePresenter(function() end)
machine:powerOn()

local deadline = os.clock() + 15
while os.clock() < deadline do
	local bootStage = machine:getBootStage()
	if bootStage == "FAULT" then
		print("FAULT during boot")
		break
	end
	if bootStage == "RUNNING" then
		local vram = machine.cpu and machine.cpu.readPhysical8 and machine.bus and machine.bus.getVideoRam and machine.bus:getVideoRam()
		if vram then
			local screen = ""
			for i = 0, 79 do
				local char = vram[i * 2]
				if char == 0 then break end
				screen = screen .. string.char(char)
			end
			print("Screen: " .. screen)
		end
		task.wait(1)
	end
	task.wait(0.1)
end

print("Done")