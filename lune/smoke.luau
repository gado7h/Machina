--> Fast smoke gate that boots FreeDOS and checks the boot-time diagnostics.

local Runner = require("./_runner")

local machine = nil

local ok, failure = pcall(function()
	machine = Runner.createBootMachine({
		X86 = {
			DIAGNOSTICS = {
				PRINT_SUMMARY = false,
			},
		},
	})

	local passed, detail, context = Runner.waitForBoot(machine)
	if not passed then
		Runner.fail("smoke failed: " .. detail, context)
	end

	print("smoke passed: " .. detail)
	Runner.printSuiteSummary("boot diagnostics", context.bootRecord.diagnostics)
end)

if machine and machine:isPowered() then
	machine:shutdown()
end

if not ok then
	error(failure)
end
