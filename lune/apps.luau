--> Diagnostic smoke test for bootOS apps.
--> Boots each app, runs it for N frames, checks rendering + scheduler health.
--> Reports specific failures: frozen screen, wrong mode, all-black frames, no motion.
-->
--> Usage:
-->   lune run lune/apps           -- test all apps
-->   lune run lune/apps fbird     -- test single app

local Runner = require("./_runner")
local FrameCapture = require("./frame_capture")
local Keyboard = require("./keyboard")
local DiagnosticsState = require("@src/platforms/x86/HardwareDiagnosticsState")

-- App registry. Each entry defines what to launch and how to test it.
local APPS = {
	{
		name = "fbird",
		mode = "graphics",
		launchKeys = "fbird\r",
		inputSequence = {
			{ frame = 30, key = "Space" },
			{ frame = 60, key = "Space" },
			{ frame = 90, key = "Space" },
		},
		frames = 120,
		stepsPerFrame = 2048,
	},
	{
		name = "invaders",
		mode = "graphics",
		launchKeys = "invaders\r",
		inputSequence = {
			{ frame = 40, key = "Left" },
			{ frame = 60, key = "Right" },
			{ frame = 80, key = "Space" },
		},
		frames = 150,
		stepsPerFrame = 2048,
	},
	{
		name = "pillman",
		mode = "graphics",
		launchKeys = "pillman\r",
		inputSequence = {
			{ frame = 30, key = "Right" },
			{ frame = 60, key = "Down" },
			{ frame = 90, key = "Left" },
		},
		frames = 150,
		stepsPerFrame = 2048,
	},
	{
		name = "cubicdoom",
		mode = "graphics",
		launchKeys = "cubicdoom\r",
		inputSequence = {
			{ frame = 30, key = "Right" },
			{ frame = 60, key = "Up" },
		},
		frames = 100,
		stepsPerFrame = 2048,
	},
	{
		name = "bricks",
		mode = "graphics",
		launchKeys = "bricks\r",
		inputSequence = {
			{ frame = 30, key = "Left" },
			{ frame = 60, key = "Right" },
		},
		frames = 100,
		stepsPerFrame = 2048,
	},
	{
		name = "snake",
		mode = "text",
		launchKeys = "snake\r",
		inputSequence = {
			{ frame = 30, key = "Right" },
			{ frame = 60, key = "Down" },
		},
		frames = 100,
		stepsPerFrame = 1024,
	},
	{
		name = "tetranflix",
		mode = "text",
		launchKeys = "tetranflix\r",
		inputSequence = {
			{ frame = 30, key = "Left" },
			{ frame = 60, key = "Right" },
		},
		frames = 100,
		stepsPerFrame = 1024,
	},
	{
		name = "mine",
		mode = "text",
		launchKeys = "mine\r",
		inputSequence = {},
		frames = 80,
		stepsPerFrame = 1024,
	},
	{
		name = "rogue",
		mode = "text",
		launchKeys = "rogue\r",
		inputSequence = {
			{ frame = 30, key = "Right" },
		},
		frames = 100,
		stepsPerFrame = 1024,
	},
	{
		name = "sokoban",
		mode = "text",
		launchKeys = "sokoban\r",
		inputSequence = {
			{ frame = 30, key = "Right" },
		},
		frames = 80,
		stepsPerFrame = 1024,
	},
	{
		name = "basic",
		mode = "text",
		launchKeys = "basic\r",
		inputSequence = {},
		frames = 60,
		stepsPerFrame = 1024,
	},
	{
		name = "counter",
		mode = "text",
		launchKeys = "counter\r",
		inputSequence = {},
		frames = 80,
		stepsPerFrame = 1024,
	},
	{
		name = "textmode",
		mode = "text",
		launchKeys = "textmode\r",
		inputSequence = {},
		frames = 60,
		stepsPerFrame = 1024,
	},
	{
		name = "bootslide",
		mode = "text",
		launchKeys = "bootslide\r",
		inputSequence = {},
		frames = 80,
		stepsPerFrame = 1024,
	},
	{
		name = "atomchess",
		mode = "text",
		launchKeys = "atomchess\r",
		inputSequence = {},
		frames = 60,
		stepsPerFrame = 1024,
	},
	{
		name = "heart",
		mode = "text",
		launchKeys = "heart\r",
		inputSequence = {},
		frames = 60,
		stepsPerFrame = 1024,
	},
	{
		name = "pi",
		mode = "text",
		launchKeys = "pi\r",
		inputSequence = {},
		frames = 80,
		stepsPerFrame = 1024,
	},
}

-- Run one heartbeat tick: DMA + CPU steps + device ticks + runtime tick.
local function heartbeatTick(machine, stepsPerTick)
	stepsPerTick = stepsPerTick or 1024
	machine.bus:processDMA(1 / 60)
	for _ = 1, stepsPerTick do
		local ok = pcall(function()
			machine.cpu:step()
		end)
		if not ok then
			return false
		end
	end
	if machine.runtime then
		machine.runtime:tick(1 / 60)
	end
	return true
end

-- Boot bootOS to the shell prompt using the proper heartbeat loop.
local function bootToShell(machine, timeoutSeconds)
	local deadline = os.clock() + (timeoutSeconds or 30)
	machine:powerOn()

	local shellSeen = false
	local shellCheckCounter = 0

	while os.clock() < deadline do
		local ok = heartbeatTick(machine, 1024)
		if not ok then
			return false, "bus fault during boot", { bootStage = machine:getBootStage() }
		end

		local stage = machine:getBootStage()
		if stage == "FAULT" then
			return false, "boot fault", { bootStage = stage }
		end

		if stage == "RUNNING" then
			shellCheckCounter = shellCheckCounter + 1
			if shellCheckCounter % 4 == 0 then
				local screen = DiagnosticsState.readTextScreen(machine, machine.config)
				if screen:find("$") then
					shellSeen = true
					break
				end
			end
		end
	end

	if not shellSeen then
		return false, "shell prompt not found within timeout", {
			bootStage = machine:getBootStage(),
		}
	end

	return true, "shell ready"
end

-- Test a single bootOS app. Returns a result table.
local function testApp(machine, config, app)
	local function fail(reason, evidence)
		return { passed = false, name = app.name, detail = reason, evidence = evidence or {} }
	end

	-- Snapshot full machine state so we can restore after the test.
	local snapshot = DiagnosticsState.snapshotMachine(machine)

	-- Boot bootOS to the shell.
	local ok, msg, ctx = bootToShell(machine, 30)
	if not ok then
		DiagnosticsState.restoreMachine(machine, snapshot)
		return fail("boot failed: " .. msg, ctx)
	end

	-- Launch the app by typing its name + Enter.
	-- Inject all characters at once so the I8042 ASCII buffer is fully populated,
	-- then let the shell's INT 0x16 AH=00 spin loop consume them naturally.
	Keyboard.typeAll(machine, app.launchKeys)

	-- Warmup: let the app initialize and render its first frame.
	local warmupTicks = app.mode == "graphics" and 10 or 6
	for _ = 1, warmupTicks do
		heartbeatTick(machine, 1024)
	end

	-- Run the app for N frames, capturing and analyzing each one.
	local frames = {}
	local frameTimes = {}
	local frozenStreak = 0
	local lastFrame = nil
	local maxFrameTime = 0
	local totalFrameTime = 0
	local busFaults = 0
	local frozenThreshold = app.mode == "text" and 20 or 8

	for frameNum = 1, app.frames do
		local frameStart = os.clock()

		-- Step CPU for this frame using proper heartbeat ticks.
		local ticksNeeded = math.ceil(app.stepsPerFrame / 1024)
		for _ = 1, ticksNeeded do
			local ok = heartbeatTick(machine, 1024)
			if not ok then
				busFaults = busFaults + 1
				if busFaults > 10 then
					DiagnosticsState.restoreMachine(machine, snapshot)
					return fail("too many bus faults during frame " .. frameNum, {
						frame = frameNum,
						busFaults = busFaults,
					})
				end
			end
		end

		-- Inject scheduled input for this frame.
		Keyboard.executeSequence(machine, app.inputSequence or {}, frameNum)

		-- Capture the frame.
		local frame = FrameCapture.capture(machine)
		frames[#frames + 1] = frame
		local frameElapsed = os.clock() - frameStart
		frameTimes[#frameTimes + 1] = frameElapsed
		totalFrameTime = totalFrameTime + frameElapsed
		if frameElapsed > maxFrameTime then
			maxFrameTime = frameElapsed
		end

		-- Check 1: Frame must not be all black.
		if FrameCapture.isAllBlack(frame, 0.005) then
			DiagnosticsState.restoreMachine(machine, snapshot)
			return fail("frame " .. frameNum .. " is all black (rendering failure)", {
				frame = frameNum,
				mode = frame.mode,
				biosMode = string.format("0x%02X", frame.biosMode or 0),
			})
		end

		-- Check 2: Graphics apps should not be in TEXT mode.
		if app.mode == "graphics" and frame.mode == "TEXT" then
			DiagnosticsState.restoreMachine(machine, snapshot)
			return fail("expected graphics mode but got TEXT at frame " .. frameNum .. " (app may not have launched)", {
				frame = frameNum,
				mode = frame.mode,
				biosMode = string.format("0x%02X", frame.biosMode or 0),
			})
		end

		-- Check 3: Screen must not be frozen (consecutive identical frames).
		if lastFrame then
			if FrameCapture.isFrozen(lastFrame, frame, 0.05) then
				frozenStreak = frozenStreak + 1
				if frozenStreak > frozenThreshold then
					DiagnosticsState.restoreMachine(machine, snapshot)
					return fail(
						"screen frozen for " .. frozenStreak .. " consecutive frames (scheduler or app stuck)",
						{
							frame = frameNum,
							frozenStreak = frozenStreak,
							mode = frame.mode,
						}
					)
				end
			else
				frozenStreak = 0
			end
		end

		lastFrame = frame
	end

	-- Check 4: Overall motion — first vs last frame must differ significantly.
	local overallDiff = FrameCapture.diff(frames[1], frames[#frames])
	if overallDiff.percentChanged < 0.5 then
		DiagnosticsState.restoreMachine(machine, snapshot)
		return fail(
			"no significant motion ("
				.. string.format("%.1f", overallDiff.percentChanged)
				.. "% changed) (app may not respond to input)",
			{
				firstMode = frames[1].mode,
				lastMode = frames[#frames].mode,
				percentChanged = overallDiff.percentChanged,
				frames = app.frames,
			}
		)
	end

	-- Check 5: Frame timing — no extreme outliers (scheduler health).
	local avgFrameTime = totalFrameTime / app.frames
	if maxFrameTime > avgFrameTime * 20 and maxFrameTime > 1.0 then
		DiagnosticsState.restoreMachine(machine, snapshot)
		return fail("scheduler timing inconsistent", {
			avgFrameTime = string.format("%.3f", avgFrameTime),
			maxFrameTime = string.format("%.3f", maxFrameTime),
			ratio = string.format("%.1f", maxFrameTime / math.max(avgFrameTime, 0.001)),
		})
	end

	-- Restore machine state.
	DiagnosticsState.restoreMachine(machine, snapshot)

	return {
		passed = true,
		name = app.name,
		detail = string.format(
			"%d frames, mode=%s, motion=%.1f%%, avg=%.1fms, colors=%d",
			app.frames,
			frames[#frames].mode,
			overallDiff.percentChanged,
			avgFrameTime * 1000,
			overallDiff.uniqueColors
		),
	}
end

-- Main entry point.
local appName = arg and arg[1] or nil

local machine, config = Runner.createDiagnosticMachine({
	X86 = {
		DIAGNOSTICS = {
			PRINT_SUMMARY = false,
		},
	},
})

local appsToTest
if appName then
	appsToTest = {}
	for _, a in ipairs(APPS) do
		if a.name == appName then
			appsToTest = { a }
			break
		end
	end
	if #appsToTest == 0 then
		error("unknown app: " .. tostring(appName))
	end
else
	appsToTest = APPS
end

local passed = 0
local failed = 0

for _, app in ipairs(appsToTest) do
	print("testing " .. app.name .. "...")
	local result = testApp(machine, config, app)
	if result.passed then
		print("  PASS: " .. result.detail)
		passed = passed + 1
	else
		print("  FAIL: " .. result.detail)
		if result.evidence then
			for k, v in pairs(result.evidence) do
				print("    " .. k .. " = " .. tostring(v))
			end
		end
		failed = failed + 1
	end
end

local total = passed + failed
print(string.format("\n%d/%d passed", passed, total))

if machine and machine:isPowered() then
	machine:shutdown()
end

if failed > 0 then
	error(failed .. " app(s) failed")
end
