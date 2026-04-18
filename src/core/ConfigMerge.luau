local ConfigMerge = {}

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

function ConfigMerge.apply(baseConfig, overrides)
	local merged = deepCopy(baseConfig or {})
	mergeInto(merged, overrides)
	return merged
end

return ConfigMerge
