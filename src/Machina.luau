local EmulatorBuilder = require("@src/core/EmulatorBuilder")
local PackageManifest = require("@src/packaging/PackageManifest")

local Machina = {}

function Machina.createEmulator(options)
	return EmulatorBuilder.create(options)
end

function Machina.availableTargets()
	return EmulatorBuilder.availableTargets()
end

function Machina.packageManifest()
	return PackageManifest.describe()
end

return Machina
