local ProductionImages = require("@src/platforms/x86/BootImageCatalogProductionImages")
local ValidationImages = require("@src/platforms/x86/BootImageCatalogValidationImages")

local BootImageCatalog = {}

local function mergeEntries(source)
	for name, entry in pairs(source) do
		BootImageCatalog[name] = entry
	end
end

mergeEntries(ProductionImages)
mergeEntries(ValidationImages)

return BootImageCatalog
