local function normalizeHostTask(value)
	if type(value) ~= "table" then
		return nil
	end
	if type(value.wait) ~= "function" then
		return nil
	end
	if type(value.delay) ~= "function" then
		return nil
	end
	if type(value.defer) ~= "function" then
		return nil
	end
	if type(value.spawn) ~= "function" then
		return nil
	end

	return {
		wait = value.wait,
		delay = value.delay,
		defer = value.defer,
		spawn = value.spawn,
		close = value.close or coroutine.close,
		start = value.start or function()
			error("task.start is not supported by the host task backend")
		end,
	}
end

local hostTask = normalizeHostTask(task)
if hostTask == nil then
	local ok, luneTask = pcall(require, "@lune/task")
	if ok then
		hostTask = normalizeHostTask(luneTask)
	end
end

if hostTask ~= nil then
	return hostTask
end

local function resumeWithErrorCheck(thread, ...)
	local success, message = coroutine.resume(thread, ...)
	if not success then
		print(string.char(27) .. "[31m" .. tostring(message))
	end
end

local lastTick = os.clock()

local waitingThreads = {}

local function processWaiting()
	local processing = waitingThreads
	waitingThreads = {}

	for thread, data in processing do
		if coroutine.status(thread) ~= "dead" then
			if type(data) == "table" and lastTick >= data.resume then
				if data.start then
					resumeWithErrorCheck(thread, lastTick - data.start)
				else
					resumeWithErrorCheck(thread, table.unpack(data, 1, data.n))
				end
			else
				waitingThreads[thread] = data
			end
		end
	end
end

local function wait(timeSeconds)
	waitingThreads[coroutine.running()] = {
		resume = lastTick + timeSeconds,
		start = lastTick,
	}
	return coroutine.yield()
end

local function delay(timeSeconds, callback, ...)
	local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
	local data = table.pack(...)
	data.resume = lastTick + timeSeconds
	waitingThreads[thread] = data
	return thread
end

local deferredThreads = {}

local function processDeferred()
	local index = 1
	while index <= #deferredThreads do
		local data = deferredThreads[index]
		if coroutine.status(data.thread) ~= "dead" then
			resumeWithErrorCheck(data.thread, table.unpack(data.args))
		end
		index += 1
	end

	table.clear(deferredThreads)
end

local function defer(callback, ...)
	local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
	table.insert(deferredThreads, {
		thread = thread,
		args = table.pack(...),
	})
	return thread
end

local function spawn(callback, ...)
	local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
	resumeWithErrorCheck(thread, ...)
	return thread
end

local function close(thread)
	coroutine.close(thread)
end

local function start()
	while true do
		lastTick = os.clock()
		processWaiting()
		processDeferred()
	end
end

return {
	wait = wait,
	delay = delay,
	defer = defer,
	spawn = spawn,
	close = close,
	start = start,
}
