local Contracts = {}

Contracts.Package = "machina"

Contracts.EntryPoints = {
	config = "@src/DefaultConfiguration",
	machine = "@src/platforms/x86/PcSystem",
	platformContracts = "@src/Contracts",
}

Contracts.ManifestFormats = {
	luauPackage = "machina-luau-package/v1",
	robloxPackage = "machina-roblox-package/v1",
	releaseMetadata = "machina-release-metadata/v1",
}

Contracts.Services = {
	clock = {
		required = true,
		description = "Supplies monotonically increasing time and scheduling hooks.",
	},
	imageLoader = {
		required = true,
		description = "Loads boot images, ROM payloads, and imported disk content.",
	},
	frameSink = {
		required = false,
		description = "Accepts rendered frame output from the emulator core.",
	},
	keyboard = {
		required = false,
		description = "Translates host input into emulator keyboard events.",
	},
	logger = {
		required = false,
		description = "Collects diagnostics, warnings, and fault messages.",
	},
	persistence = {
		required = false,
		description = "Supplies host-backed save and load hooks.",
	},
}

function Contracts.getEntryPoints()
	return Contracts.EntryPoints
end

function Contracts.getServiceNames()
	local names = {}
	for name in pairs(Contracts.Services) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

return Contracts
