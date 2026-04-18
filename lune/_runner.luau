local task = require("@src/task")

local Runner = {}

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = deepCopy(child)
	end
	return copy
end

local function mergeInto(target, overrides)
	for key, value in pairs(overrides or {}) do
		if type(value) == "table" then
			local child = target[key]
			if type(child) ~= "table" then
				child = {}
				target[key] = child
			end
			mergeInto(child, value)
		else
			target[key] = value
		end
	end
end

local function formatResultLine(result)
	local status = result.passed and "PASS" or "FAIL"
	local suite = result.suite or "unknown"
	local detail = result.detail and (" - " .. tostring(result.detail)) or ""
	return string.format("%s [%s] %s%s", tostring(result.name), suite, status, detail)
end

local function formatEvidenceLines(result)
	local evidence = result and result.evidence or nil
	if type(evidence) ~= "table" then
		return {}
	end

	local lines = {}
	local cpu = evidence.cpu
	if type(cpu) == "table" then
		local lastOpcode = cpu.lastOpcode
		local opcodeWidth = (tonumber(lastOpcode) or 0) > 0xFF and 4 or 2
		lines[#lines + 1] = string.format(
			"cpu: mode=%s pc=%s cs=%s ip=%s last=%s halted=%s",
			tostring(cpu.mode or "?"),
			string.format("0x%05X", (tonumber(cpu.pc) or 0) % 0x100000),
			string.format("0x%04X", (tonumber(cpu.cs) or 0) % 0x10000),
			string.format("0x%04X", (tonumber(cpu.ip) or 0) % 0x10000),
			string.format("0x%0" .. tostring(opcodeWidth) .. "X", (tonumber(lastOpcode) or 0) % (2 ^ (opcodeWidth * 4))),
			tostring(cpu.halted == true)
		)
	end
	if evidence.screen then
		lines[#lines + 1] = "screen: " .. tostring(evidence.screen)
	end
	if evidence.error then
		lines[#lines + 1] = "error: " .. tostring(evidence.error)
	end
	if type(evidence.fault) == "table" then
		lines[#lines + 1] = string.format(
			"fault: kind=%s addr=%s op=%s detail=%s",
			tostring(evidence.fault.kind),
			string.format("0x%05X", (tonumber(evidence.fault.addr) or 0) % 0x100000),
			tostring(evidence.fault.op),
			tostring(evidence.fault.detail)
		)
	end
	return lines
end

function Runner.newConfig(overrides)
	local DefaultConfiguration = require("@src/DefaultConfiguration")
	local config = deepCopy(DefaultConfiguration)
	mergeInto(config, overrides)
	return config
end

function Runner.createBootMachine(overrides)
	local Machina = require("@src/Machina")
	local config = Runner.newConfig(overrides)
	local emulator = Machina.createEmulator({
		target = "x86-i486-pc",
		config = config,
	})
	emulator:setFramePresenter(function() end)
	return emulator.machine, config, emulator
end

function Runner.createDiagnosticMachine(overrides)
	local machine, config, emulator = Runner.createBootMachine(overrides)
	machine:_buildHardware()
	return machine, config, emulator
end

function Runner.waitForBoot(machine, options)
	options = options or {}

	local timeoutSeconds = options.timeoutSeconds or 15
	local pollInterval = options.pollInterval or 0.05

	machine:powerOn()

	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		local bootStage = machine:getBootStage()
		local bootRecord = machine:getBootRecord()

		if bootStage == "FAULT" then
			return false,
				"machine entered FAULT before boot completed",
				{
					bootStage = bootStage,
					bootRecord = bootRecord,
				}
		end

		if bootStage == "RUNNING" then
			local diagnostics = bootRecord and bootRecord.diagnostics or nil
			if diagnostics == nil then
				return false,
					"boot completed without boot diagnostics in the boot record",
					{
						bootStage = bootStage,
						bootRecord = bootRecord,
					}
			end
			if diagnostics.passed ~= true then
				return false,
					string.format(
						"boot diagnostics failed (%s/%s)",
						tostring(diagnostics.passedCount),
						tostring(diagnostics.totalCount)
					),
					{
						bootStage = bootStage,
						bootRecord = bootRecord,
					}
			end

			return true,
				string.format(
					"FreeDOS reached RUNNING with diagnostics %d/%d",
					diagnostics.passedCount,
					diagnostics.totalCount
				),
				{
					bootStage = bootStage,
					bootRecord = bootRecord,
				}
		end

		task.wait(pollInterval)
	end

	return false,
		string.format("timed out after %.2fs waiting for RUNNING", timeoutSeconds),
		{
			bootStage = machine:getBootStage(),
			bootRecord = machine:getBootRecord(),
		}
end

function Runner.printSuiteSummary(label, suite)
	print(string.format("%s: %d/%d passed", label, suite.passedCount or 0, suite.totalCount or 0))
	for _, result in ipairs(suite.results or {}) do
		print("  " .. formatResultLine(result))
		if not result.passed then
			for _, line in ipairs(formatEvidenceLines(result)) do
				print("    " .. line)
			end
		end
	end
end

function Runner.combineSuites(suites)
	local results = {}
	local passedCount = 0

	for _, suite in ipairs(suites) do
		for _, result in ipairs(suite.results or {}) do
			results[#results + 1] = result
			if result.passed then
				passedCount += 1
			end
		end
	end

	return {
		passed = passedCount == #results,
		passedCount = passedCount,
		totalCount = #results,
		results = results,
	}
end

function Runner.fail(message, context)
	if context and context.bootStage then
		print("boot stage: " .. tostring(context.bootStage))
	end

	local bootRecord = context and context.bootRecord or nil
	if bootRecord then
		if bootRecord.imageName ~= nil then
			print("image: " .. tostring(bootRecord.imageName))
		end
		if bootRecord.bootDevice ~= nil then
			print("boot device: " .. tostring(bootRecord.bootDevice))
		end
		local diagnostics = bootRecord.diagnostics
		if diagnostics then
			Runner.printSuiteSummary("boot diagnostics", diagnostics)
		end
	end

	error(message)
end

return Runner
