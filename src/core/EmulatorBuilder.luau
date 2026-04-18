local I486Emulator = require("@src/targets/x86/i486/I486Emulator")

local EmulatorBuilder = {}

local constructors = {
	["x86-i486-pc"] = I486Emulator,
	["i486"] = I486Emulator,
}

function EmulatorBuilder.availableTargets()
	return { "x86-i486-pc" }
end

function EmulatorBuilder.create(options)
	options = options or {}
	local target = options.target or "x86-i486-pc"
	local constructor = constructors[target]
	if constructor == nil then
		error(string.format("unsupported emulator target '%s'", tostring(target)))
	end

	return constructor.new(options.config)
end

return EmulatorBuilder
