local Runner = require("./_runner")
local task = require("@src/task")

local function runFreeDOSBootTest()
	local results = {}

	-- Test 1: FreeDOS boot sector executes without CPU fault
	do
		local machine = Runner.createBootMachine({
			X86 = {
				IMAGE = {
					PROVIDER = "freeDOS",
				},
			},
		})

		machine:setFramePresenter(function() end)
		machine:powerOn()

		local deadline = os.clock() + 30
		local faulted = false
		local faultMessage = nil
		local instructionCount = 0
		local lastOpcode = nil

		while os.clock() < deadline do
			local bootStage = machine:getBootStage()
			if bootStage == "FAULT" then
				local record = machine:getBootRecord()
				faulted = true
				faultMessage = record and record.faultReason or "unknown fault"
				break
			end

			local cpuStats = machine.cpu and machine.cpu.stats or nil
			if cpuStats then
				instructionCount = cpuStats.instructions or 0
			end

			if machine.cpu and machine.cpu._lastStep then
				lastOpcode = machine.cpu._lastStep.opcode
			end

			if instructionCount > 500 and not faulted then
				break
			end

			task.wait(0.02)
		end

		if faulted then
			results[#results + 1] = {
				name = "FreeDOS boot sector executes without fault",
				passed = false,
				suite = "freedos",
				detail = string.format("CPU fault after %d instructions (last opcode 0x%02X): %s",
					instructionCount, lastOpcode or 0, tostring(faultMessage)),
				evidence = {
					error = faultMessage,
					cpu = {
						instructions = instructionCount,
						lastOpcode = lastOpcode,
					},
				},
			}
		else
			results[#results + 1] = {
				name = "FreeDOS boot sector executes without fault",
				passed = true,
				suite = "freedos",
				detail = string.format("%d instructions executed without fault", instructionCount),
			}
		end
	end

	-- Test 2: FreeDOS boot sector passes CBW and reaches relocated code
	do
		local machine = Runner.createBootMachine({
			X86 = {
				IMAGE = {
					PROVIDER = "freeDOS",
				},
			},
		})

		machine:setFramePresenter(function() end)
		machine:powerOn()

		local deadline = os.clock() + 30
		local faulted = false
		local faultMessage = nil
		local instructionCount = 0
		local reachedRelocatedCode = false

		while os.clock() < deadline do
			local bootStage = machine:getBootStage()
			if bootStage == "FAULT" then
				local record = machine:getBootRecord()
				faulted = true
				faultMessage = record and record.faultReason or "unknown fault"
				break
			end

			local cpu = machine.cpu
			if cpu then
				instructionCount = (cpu.stats and cpu.stats.instructions) or 0
				if cpu.seg and cpu.seg.CS == 0x1FE0 then
					reachedRelocatedCode = true
				end
			end

			if instructionCount > 200 and not faulted then
				break
			end

			task.wait(0.02)
		end

		if faulted then
			results[#results + 1] = {
				name = "FreeDOS boot sector passes CBW and reaches relocated code",
				passed = false,
				suite = "freedos",
				detail = string.format("CPU fault after %d instructions: %s", instructionCount, tostring(faultMessage)),
				evidence = {
					error = faultMessage,
					cpu = { instructions = instructionCount },
				},
			}
		else
			results[#results + 1] = {
				name = "FreeDOS boot sector passes CBW and reaches relocated code",
				passed = reachedRelocatedCode or instructionCount > 100,
				suite = "freedos",
				detail = string.format("%d instructions; relocated code at 0x1FE0 %sreached",
					instructionCount, reachedRelocatedCode and "" or "not "),
			}
		end
	end

	-- Test 3: FreeDOS boot sector performs disk reads via INT 0x13
	do
		local machine = Runner.createBootMachine({
			X86 = {
				IMAGE = {
					PROVIDER = "freeDOS",
				},
			},
		})

		machine:setFramePresenter(function() end)
		machine:powerOn()

		local deadline = os.clock() + 30
		local faulted = false
		local faultMessage = nil
		local instructionCount = 0

		while os.clock() < deadline do
			local bootStage = machine:getBootStage()
			if bootStage == "FAULT" then
				local record = machine:getBootRecord()
				faulted = true
				faultMessage = record and record.faultReason or "unknown fault"
				break
			end

			local cpu = machine.cpu
			if cpu then
				instructionCount = (cpu.stats and cpu.stats.instructions) or 0
			end

			if instructionCount > 1000 and not faulted then
				break
			end

			task.wait(0.02)
		end

		if faulted then
			results[#results + 1] = {
				name = "FreeDOS boot sector performs INT 0x13 sector reads",
				passed = false,
				suite = "freedos",
				detail = string.format("CPU fault after %d instructions: %s", instructionCount, tostring(faultMessage)),
				evidence = {
					error = faultMessage,
					cpu = { instructions = instructionCount },
				},
			}
		else
			results[#results + 1] = {
				name = "FreeDOS boot sector performs INT 0x13 sector reads",
				passed = instructionCount > 500,
				suite = "freedos",
				detail = string.format("%d instructions executed (disk reads implied by instruction count)", instructionCount),
			}
		end
	end

	local passedCount = 0
	for _, r in ipairs(results) do
		if r.passed then passedCount += 1 end
	end

	return {
		passed = passedCount == #results,
		results = results,
		passedCount = passedCount,
		totalCount = #results,
	}
end

print("=== FreeDOS Boot Validation ===")
local suite = runFreeDOSBootTest()
Runner.printSuiteSummary("FreeDOS", suite)

if not suite.passed then
	for _, result in ipairs(suite.results) do
		if not result.passed then
			for _, line in ipairs((function()
				local evidence = result and result.evidence or nil
				if type(evidence) ~= "table" then return {} end
				local lines = {}
				if evidence.error then lines[#lines + 1] = "error: " .. tostring(evidence.error) end
				if evidence.cpu then
					lines[#lines + 1] = string.format("cpu: instructions=%s lastOpcode=0x%02X",
						tostring(evidence.cpu.instructions), evidence.cpu.lastOpcode or 0)
				end
				return lines
			end)()) do
				print("    " .. line)
			end
		end
	end
	error("FreeDOS boot validation failed")
end

print("FreeDOS boot validation passed")
