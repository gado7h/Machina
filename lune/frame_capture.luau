-- Frame capture utilities for FreeDOS visual testing.
-- Extracts text from VGA text mode VRAM for validation.

local FrameCapture = {}

-- Text mode VRAM base address
local TEXT_VRAM_BASE = 0xB8000
local TEXT_COLS = 80
local TEXT_ROWS = 25
local TEXT_CELL_SIZE = 2

function FrameCapture.getVRAMAddress(machine)
	if not machine.gpu then
		return nil
	end
	local gpu = machine.gpu
	if not gpu._vram then
		return nil
	end
	return gpu._vram
end

function FrameCapture.capture(machine)
	local vram = FrameCapture.getVRAMAddress(machine)
	if not vram then
		return {
			text = "",
			vram = {},
			width = TEXT_COLS,
			height = TEXT_ROWS,
			capturedAt = os.clock(),
		}
	end

	local cells = {}
	for i = 0, TEXT_COLS * TEXT_ROWS - 1 do
		local charAddr = i * TEXT_CELL_SIZE
		local attrAddr = charAddr + 1
		local char = vram[charAddr] or 32
		local attr = vram[attrAddr] or 7
		cells[i + 1] = {
			char = char,
			attr = attr,
		}
	end

	return {
		text = FrameCapture.extractText({ cells = cells, width = TEXT_COLS, height = TEXT_ROWS }),
		vram = vram,
		width = TEXT_COLS,
		height = TEXT_ROWS,
		capturedAt = os.clock(),
	}
end

function FrameCapture.extractText(frame)
	if not frame or not frame.cells then
		return ""
	end

	local lines = {}
	local width = frame.width or TEXT_COLS

	for row = 0, (frame.height or TEXT_ROWS) - 1 do
		local line = {}
		for col = 0, width - 1 do
			local cellIndex = row * width + col + 1
			local cell = frame.cells[cellIndex]
			if cell and cell.char then
				local char = cell.char
				if char == 0 or char == 255 then
					char = 32
				end
				table.insert(line, string.char(char))
			else
				table.insert(line, " ")
			end
		end

		local lineStr = table.concat(line)
		if lineStr:match("%S") then
			table.insert(lines, lineStr)
		end
	end

	return table.concat(lines, "\n")
end

function FrameCapture.compare(frame1, frame2)
	if not frame1 or not frame2 then
		return {
			match = false,
			diff = 100,
			reason = "missing frame data",
		}
	end

	local text1 = frame1.text or ""
	local text2 = frame2.text or ""

	if text1 == text2 then
		return {
			match = true,
			diff = 0,
		}
	end

	local len1 = #text1
	local len2 = #text2
	local maxLen = math.max(len1, len2)
	if maxLen == 0 then
		return {
			match = true,
			diff = 0,
		}
	end

	local diff = 0
	for i = 1, maxLen do
		if text1:sub(i, i) ~= text2:sub(i, i) then
			diff = diff + 1
		end
	end

	return {
		match = false,
		diff = math.floor((diff / maxLen) * 100),
	}
end

function FrameCapture.containsText(frame, searchText)
	if not frame or not frame.text then
		return false
	end
	return frame.text:find(searchText, 1, true) ~= nil
end

function FrameCapture.waitForText(machine, searchText, options)
	options = options or {}
	local timeoutSeconds = options.timeoutSeconds or 10
	local pollInterval = options.pollInterval or 0.5

	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		local frame = FrameCapture.capture(machine)
		if FrameCapture.containsText(frame, searchText) then
			return {
				found = true,
				frame = frame,
			}
		end
		task.wait(pollInterval)
	end

	return {
		found = false,
		frame = FrameCapture.capture(machine),
	}
end

return FrameCapture