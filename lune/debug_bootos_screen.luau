-- Debug: hook INT 13h to see if bootOS shell calls it when typing commands.
local Runner = require("./_runner")
local DiagnosticsState = require("@src/platforms/x86/HardwareDiagnosticsState")

local machine, config = Runner.createDiagnosticMachine({
	X86 = { DIAGNOSTICS = { PRINT_SUMMARY = false } },
})

machine:powerOn()

-- Boot to shell
local deadline = os.clock() + 30
while os.clock() < deadline do
	machine.bus:processDMA(1/60)
	for _ = 1, 1024 do pcall(function() machine.cpu:step() end) end
	machine.runtime:tick(1/60)
	if machine:getBootStage() == "RUNNING" then
		local screen = DiagnosticsState.readTextScreen(machine, config)
		if screen:find("$") then break end
	end
end

print("Shell ready")

-- Hook INT 13h by wrapping the BIOS interrupt handler
local bios = machine.cpu._bios
if bios then
	local origDispatch = bios._dispatch or bios.dispatch
	-- Wrap the dispatch to count INT 13h calls
	local origBios = machine.cpu._bios
	local callCount = 0
	local origCallInterrupt = machine.cpu.callInterrupt
	machine.cpu.callInterrupt = function(cpu, vec)
		if vec == 0x13 then
			callCount = callCount + 1
			local ax = cpu.getReg16 and cpu:getReg16(0) or 0
			local dx = cpu.getReg16 and cpu:getReg16(3) or 0
			local cx = cpu.getReg16 and cpu:getReg16(2) or 0
			print(string.format("INT 13h call #%d: ax=%04X cx=%04X dx=%04X",
				callCount, ax % 0x10000, cx % 0x10000, dx % 0x10000))
		end
		return origCallInterrupt(cpu, vec)
	end
end

-- Type "counter" + Enter
local kbd = machine.keyboard
for _, ch in ipairs({"C","O","U","N","T","E","R"}) do
	kbd:keyDown(ch)
	kbd:keyUp(ch)
	for _ = 1, 64 do pcall(function() machine.cpu:step() end) end
end
kbd:keyDown("Return")
kbd:keyUp("Return")
for _ = 1, 200 do pcall(function() machine.cpu:step() end) end

-- Run more ticks
for i = 1, 50 do
	machine.bus:processDMA(1/60)
	for _ = 1, 1024 do pcall(function() machine.cpu:step() end) end
	machine.runtime:tick(1/60)
	
	local screen = DiagnosticsState.readTextScreen(machine, config)
	local nonSpace = 0
	for j = 1, #screen do
		if screen:sub(j,j) ~= " " and screen:sub(j,j) ~= "\0" then
			nonSpace = nonSpace + 1
		end
	end
	if nonSpace > 32 or i % 10 == 0 then
		print(string.format("tick=%d nonSpace=%d: %s", i, nonSpace, screen:sub(1, 120):gsub("[^\x20-\x7E]", ".")))
	end
end

print("\nFinal INT 13h calls: " .. tostring(callCount))

if machine and machine:isPowered() then
	machine:shutdown()
end
