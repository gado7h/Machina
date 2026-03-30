local BootImageCatalog = require("@src/platforms/x86/BootImageCatalog")
local DefaultConfiguration = require("@src/DefaultConfiguration")
local ImageCatalogUtils = require("@src/platforms/x86/ImageCatalogUtils")

local RawImageCatalog = {}

local function buildCatalogImage(entryName, config)
	local cfg = config or DefaultConfiguration
	local entry = BootImageCatalog[entryName]
	assert(entry, "unknown x86 raw image entry: " .. tostring(entryName))

	if type(entry) == "table" and type(entry.build) == "function" then
		return entry.build(cfg)
	end
	return entry
end

local function snapshotImage(image)
	assert(type(image) == "table", "x86 raw image builder returned an invalid image")
	assert(type(image.romBytes) == "table", "x86 raw image is missing romBytes")
	assert(type(image.sectors) == "table", "x86 raw image is missing sectors")

	return {
		name = image.name,
		romBytes = ImageCatalogUtils.deepCopy(image.romBytes),
		diskBytes = ImageCatalogUtils.sectorsToDiskBytes(image.sectors),
		layout = ImageCatalogUtils.deepCopy(image.layout or {}),
		files = ImageCatalogUtils.deepCopy(image.files or {}),
		symbols = ImageCatalogUtils.deepCopy(image.symbols or {}),
		configOverride = ImageCatalogUtils.deepCopy(image.configOverride),
		meta = ImageCatalogUtils.deepCopy(image.meta),
	}
end

local function buildRawImage(entryName, config)
	return snapshotImage(buildCatalogImage(entryName, config))
end

RawImageCatalog.ProtectedModeBringUp = buildRawImage("bootOS")
RawImageCatalog.bootOS = buildRawImage("bootOS")

function RawImageCatalog.get(name)
	return RawImageCatalog[name]
end

return RawImageCatalog
