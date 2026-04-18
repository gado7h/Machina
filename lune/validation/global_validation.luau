local Runner = require("../_runner")

local function summarizeAndFail(label, suite)
	Runner.printSuiteSummary(label, suite)
	if suite.passed ~= true then
		error(string.format("%s failed (%d/%d passed)", label, suite.passedCount, suite.totalCount))
	end
end

local function runBootSuite()
	local machine = Runner.createBootMachine()
	local ok, detail, context = Runner.waitForBoot(machine, {
		timeoutSeconds = 45,
		pollInterval = 0.05,
	})

	machine:shutdown()

	return {
		passed = ok,
		passedCount = if ok then 1 else 0,
		totalCount = 1,
		results = {
			{
				name = "freedos_boot",
				suite = "booting",
				passed = ok,
				detail = detail,
				evidence = context,
			},
		},
	}
end

local function runTraceSuite()
	local machine = Runner.createBootMachine({
		MACHINE_PROFILE = {
			TRACE = {
				ENABLED = true,
				CPU_STATE = true,
			},
		},
	})

	local ok, detail, context = Runner.waitForBoot(machine, {
		timeoutSeconds = 45,
		pollInterval = 0.05,
	})

	local stats = machine:getStats()
	machine:shutdown()

	local cpuStats = stats and stats.cpuStats or nil
	local instructionCount = cpuStats and tonumber(cpuStats.instructions) or 0
	local traceOkay = instructionCount > 0
	local passed = ok and traceOkay
	local traceDetail = detail
	if not traceOkay then
		traceDetail ..= string.format(" | trace check failed (instructions=%s)", tostring(instructionCount))
	end

	return {
		passed = passed,
		passedCount = if passed then 1 else 0,
		totalCount = 1,
		results = {
			{
				name = "trace_enabled_boot",
				suite = "tracing",
				passed = passed,
				detail = traceDetail,
				evidence = {
					bootStage = context and context.bootStage,
					bootRecord = context and context.bootRecord,
					cpu = {
						instructions = instructionCount,
					},
				},
			},
		},
	}
end

local function runValidationSuite()
	local machine = Runner.createBootMachine()
	local ok, detail, context = Runner.waitForBoot(machine, {
		timeoutSeconds = 45,
		pollInterval = 0.05,
	})
	machine:shutdown()

	if not ok then
		return {
			passed = false,
			passedCount = 0,
			totalCount = 1,
			results = {
				{
					name = "hardware_diagnostics",
					suite = "validation",
					passed = false,
					detail = detail,
					evidence = context,
				},
			},
		}
	end

	local diagnostics = context
		and context.bootRecord
		and context.bootRecord.diagnostics
		or {
			passed = false,
			passedCount = 0,
			totalCount = 0,
			results = {},
		}

	local suite = {
		passed = diagnostics.passed == true,
		passedCount = diagnostics.passedCount or 0,
		totalCount = diagnostics.totalCount or 0,
		results = diagnostics.results or {},
	}

	return suite
end

local bootSuite = runBootSuite()
local traceSuite = runTraceSuite()
local validationSuite = runValidationSuite()

summarizeAndFail("boot suite", bootSuite)
summarizeAndFail("trace suite", traceSuite)
summarizeAndFail("validation suite", validationSuite)

local combined = Runner.combineSuites({ bootSuite, traceSuite, validationSuite })
Runner.printSuiteSummary("global validation", combined)
print(string.format("Global validation passed (%d/%d)", combined.passedCount, combined.totalCount))
