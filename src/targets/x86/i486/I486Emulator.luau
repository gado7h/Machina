local DefaultConfiguration = require("@src/DefaultConfiguration")
local PcSystem = require("@src/platforms/x86/PcSystem")
local ConfigMerge = require("@src/core/ConfigMerge")
local I486Configuration = require("./I486Configuration")

local I486Emulator = {}
I486Emulator.__index = I486Emulator

function I486Emulator.new(overrides)
	local merged = ConfigMerge.apply(DefaultConfiguration, I486Configuration.defaults)
	merged = ConfigMerge.apply(merged, overrides)

	local machine = PcSystem.new(merged)
	machine:setFramePresenter(function() end)

	local self = setmetatable({
		name = I486Configuration.name,
		config = merged,
		machine = machine,
	}, I486Emulator)

	return self
end

function I486Emulator:powerOn()
	self.machine:powerOn()
end

function I486Emulator:shutdown()
	self.machine:shutdown()
end

function I486Emulator:reboot()
	self.machine:reboot()
end

function I486Emulator:setFramePresenter(presenter)
	self.machine:setFramePresenter(presenter)
end

function I486Emulator:keyDown(key)
	self.machine:keyDown(key)
end

function I486Emulator:keyUp(key)
	self.machine:keyUp(key)
end

function I486Emulator:getStats()
	return self.machine:getStats()
end

function I486Emulator:getBootStage()
	return self.machine:getBootStage()
end

function I486Emulator:getBootRecord()
	return self.machine:getBootRecord()
end

return I486Emulator
