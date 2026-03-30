--> Review gate that runs the broader guest-visible validation suite.

local Runner = require("./_runner")
local HardwareDiagnostics = require("@src/platforms/x86/HardwareDiagnostics")

local machine = nil

local function runPhase(label, callback)
	print("starting " .. label .. "...")
	local startedAt = os.clock()
	local suite = callback()
	local elapsed = os.clock() - startedAt
	Runner.printSuiteSummary(string.format("%s (%.2fs)", label, elapsed), suite)
	return suite
end

local ok, failure = pcall(function()
	machine = Runner.createDiagnosticMachine({
		X86 = {
			DIAGNOSTICS = {
				PRINT_SUMMARY = false,
			},
		},
	})

	local base = runPhase("base smoke diagnostics", function()
		return HardwareDiagnostics.run(machine, machine.config)
	end)
	if not base.passed then
		Runner.fail("review suite failed during base smoke diagnostics", {})
	end

	local runtime = runPhase("guest runtime validations", function()
		return HardwareDiagnostics.runGuestRuntimeValidations(machine, machine.config)
	end)
	if not runtime.passed then
		Runner.fail("review suite failed during guest runtime validations", {})
	end

	local cpu = runPhase("guest cpu validations", function()
		return HardwareDiagnostics.runGuestCPUValidations(machine, machine.config)
	end)
	if not cpu.passed then
		Runner.fail("review suite failed during guest cpu validations", {})
	end

	local suite = Runner.combineSuites({ base, runtime, cpu })
	Runner.printSuiteSummary("review suite", suite)
end)

if machine and machine:isPowered() then
	machine:shutdown()
end

if not ok then
	error(failure)
end
