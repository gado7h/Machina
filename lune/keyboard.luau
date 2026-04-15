-- Keyboard injection helpers for bootOS app testing.
-- Wraps I8042Controller:keyDown/keyUp with CPU stepping to deliver IRQs.

local Keyboard = {}

local SCAN_TO_KEY = {
	["\r"] = "Return",
	["\n"] = "Return",
	[" "] = "Space",
}

-- Type an ASCII string through the emulated keyboard.
-- Each character is sent as keyDown + keyUp, then CPU is stepped
-- to let the IRQ deliver the scan code to the guest.
function Keyboard.type(machine, text, delaySteps)
	delaySteps = delaySteps or 64
	local kbd = machine.keyboard
	if not kbd then
		return
	end

	for i = 1, #text do
		local ch = text:sub(i, i)
		local key = SCAN_TO_KEY[ch]
		if key then
			kbd:keyDown(key)
			kbd:keyUp(key)
		elseif ch:match("%a") then
			local keyName = string.upper(ch)
			kbd:keyDown(keyName)
			kbd:keyUp(keyName)
		end
		-- Step CPU so the keyboard IRQ delivers and the guest reads the key.
		local cpu = machine.cpu
		if cpu then
			for _ = 1, delaySteps do
				pcall(function()
					cpu:step()
				end)
			end
		end
	end
end

-- Inject all characters at once without stepping, then step the CPU
-- to let the guest process the queued input. This avoids the INT 0x16
-- AH=00 spin loop starving the guest of CPU budget.
function Keyboard.typeAll(machine, text)
	local kbd = machine.keyboard
	if not kbd then
		return
	end

	for i = 1, #text do
		local ch = text:sub(i, i)
		local key = SCAN_TO_KEY[ch]
		if key then
			kbd:keyDown(key)
			kbd:keyUp(key)
		elseif ch:match("%a") then
			local keyName = string.upper(ch)
			kbd:keyDown(keyName)
			kbd:keyUp(keyName)
		end
	end
end

-- Press and release a single named key (e.g. "Up", "Space", "Escape").
function Keyboard.press(machine, key, delaySteps)
	delaySteps = delaySteps or 16
	local kbd = machine.keyboard
	if not kbd then
		return
	end
	kbd:keyDown(key)
	kbd:keyUp(key)
	local cpu = machine.cpu
	if cpu then
		for _ = 1, delaySteps do
			pcall(function()
				cpu:step()
			end)
		end
	end
end

-- Execute a sequence of timed key presses.
-- actions = { { frame = 30, key = "Space" }, { frame = 60, key = "Up" } }
function Keyboard.executeSequence(machine, actions, currentFrame)
	for _, action in ipairs(actions) do
		if action.frame == currentFrame then
			Keyboard.press(machine, action.key, action.delaySteps)
		end
	end
end

return Keyboard
