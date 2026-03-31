-- Frame capture and pixel analysis for bootOS app diagnostics.
-- Reads the VGA framebuffer directly to avoid the _dirtyPixelRect staleness bug.

local FrameCapture = {}

-- Replicate VgaAdapter's local mode detection functions.
local function isTextState(gpu)
	return bit32.band(gpu._attribute[0x10] or 0, 0x01) == 0
		and bit32.band(gpu._graphics[0x06] or 0, 0x01) == 0
end

local function isChain4State(gpu)
	return bit32.band(gpu._sequencer[0x04] or 0, 0x04) ~= 0
		and bit32.band(gpu._graphics[0x05] or 0, 0x40) ~= 0
end

-- Capture current frame by forcing render + reading _framebuf directly.
-- Returns a lightweight sampled representation suitable for diffing.
-- Always re-renders regardless of _dirty flag to avoid stale-frame issues.
function FrameCapture.capture(machine)
	local gpu = machine.gpu

	-- Always force a full render pass.
	-- The _dirty flag is unreliable for frame capture because:
	--   1. _dirtyPixelRect is set to nil after first _packPixelBuffer(), causing stale buffers
	--   2. Guest may not set _dirty between frames in tight loops
	--   3. flush() frame-rate limiter can skip rendering entirely
	if isTextState(gpu) then
		-- _renderText() is incremental (dirty cells only), which gives stale results
		-- when called from outside the normal render loop. Always use full-frame render.
		gpu:_renderHardwareText()
		if gpu._hostOverlay and gpu._hostOverlay.active then
			gpu:_renderHostOverlay()
		end
	elseif isChain4State(gpu) then
		gpu:_renderMode13()
		gpu:_renderHostOverlay()
	else
		gpu:_renderPlanar()
		gpu:_renderHostOverlay()
	end

	local framebuf = gpu._framebuf
	local w = gpu.W
	local h = gpu.H

	-- Sample every Nth pixel to keep comparisons fast.
	-- At stride=4 on 640x400: 160x100 = 16,000 samples.
	local stride = 4
	local pixels = {}
	local count = 0
	for y = 0, h - 1, stride do
		local rowBase = y * w
		for x = 0, w - 1, stride do
			count = count + 1
			pixels[count] = framebuf[rowBase + x] or 0xFF000000
		end
	end

	return {
		width = w,
		height = h,
		pixels = pixels,
		stride = stride,
		sampleCount = count,
		mode = gpu.mode,
		biosMode = gpu._biosMode,
		timestamp = os.clock(),
	}
end

-- Compare two captured frames. Returns diff metrics.
function FrameCapture.diff(frameA, frameB)
	local total = math.min(#frameA.pixels, #frameB.pixels)
	if total == 0 then
		return { percentChanged = 0, percentActive = 0, uniqueColors = 0, changed = 0, total = 0 }
	end

	local changed = 0
	local activeCount = 0
	local colorSet = {}

	for i = 1, total do
		local a = frameA.pixels[i]
		local b = frameB.pixels[i]
		if a ~= b then
			changed = changed + 1
		end
		if b ~= 0xFF000000 then
			activeCount = activeCount + 1
			-- Track unique RGB values (mask off alpha)
			local rgb = bit32.band(b, 0x00FFFFFF)
			colorSet[rgb] = true
		end
	end

	local uniqueColors = 0
	for _ in pairs(colorSet) do
		uniqueColors = uniqueColors + 1
	end

	return {
		percentChanged = (changed / total) * 100,
		percentActive = (activeCount / total) * 100,
		uniqueColors = uniqueColors,
		changed = changed,
		total = total,
	}
end

-- True if two frames are effectively identical (frozen screen).
function FrameCapture.isFrozen(frameA, frameB, threshold)
	local diff = FrameCapture.diff(frameA, frameB)
	return diff.percentChanged < (threshold or 0.1)
end

-- True if the frame is almost entirely black (rendering failure).
function FrameCapture.isAllBlack(frame, threshold)
	local active = 0
	local total = #frame.pixels
	for i = 1, total do
		if frame.pixels[i] ~= 0xFF000000 then
			active = active + 1
		end
	end
	return (active / total) < (threshold or 0.01)
end

-- Return a human-readable summary of a frame capture.
function FrameCapture.summary(frame)
	return string.format(
		"mode=%s biosMode=0x%02X samples=%d",
		tostring(frame.mode),
		frame.biosMode or 0,
		frame.sampleCount or 0
	)
end

return FrameCapture
