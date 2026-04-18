local EmulatorBuilder = require("@src/core/EmulatorBuilder")
local Contracts = require("@src/Contracts")

local PackageManifest = {}

function PackageManifest.describe()
	return {
		name = Contracts.Package,
		entryPoints = Contracts.getEntryPoints(),
		targets = EmulatorBuilder.availableTargets(),
		manifestFormats = Contracts.ManifestFormats,
		services = Contracts.Services,
	}
end

return PackageManifest
