local BootImageCatalog = require("@src/platforms/x86/BootImageCatalog")
local BiosRom = require("@src/platforms/x86/BiosRom")
local ImageCatalogUtils = require("@src/platforms/x86/ImageCatalogUtils")
local MachineProfile = require("@src/platforms/x86/MachineProfile")
local RawImageCatalog = require("@src/platforms/x86/RawImageCatalog")
local ImportedImageCatalog = require("@src/platforms/x86/ImportedImageCatalog")

local BootImageLoader = {}

local DEFAULT_IMAGE_NAME = "ProtectedModeBringUp"
local DEFAULT_SOURCE = "provider"

local function normalizeLayout(layout, files)
	local normalizedLayout = ImageCatalogUtils.deepCopy(layout or {})
	normalizedLayout.kernelSectorStart = normalizedLayout.kernelSectorStart or 2
	normalizedLayout.kernelSectorCount = normalizedLayout.kernelSectorCount or 1
	normalizedLayout.fsSuperSector = normalizedLayout.fsSuperSector or 0
	normalizedLayout.rootDirSector = normalizedLayout.rootDirSector or 0
	normalizedLayout.rootDirSectorCount = normalizedLayout.rootDirSectorCount or 0
	normalizedLayout.dataStartSector = normalizedLayout.dataStartSector or 0
	normalizedLayout.fileCount = normalizedLayout.fileCount or #(files or {})
	return normalizedLayout
end

local function normalizeImage(image, meta)
	assert(type(image) == "table", "x86 image loader expected an image table")
	assert(image.sectors ~= nil or image.diskBytes ~= nil, "x86 image is missing sectors/diskBytes")

	local romBytes = image.romBytes
	if romBytes == nil then
		local artifact = BiosRom.buildArtifact(meta.config)
		romBytes = BiosRom.buildROMBytes(meta.config, artifact)
	end

	local files = image.files or {}
	local normalized = {
		name = image.name,
		romBytes = BootImageLoader._normalizeByteArray(romBytes),
		sectors = image.sectors and BootImageLoader._normalizeSectors(image.sectors)
			or BootImageLoader._diskBytesToSectors(image.diskBytes, image.diskStartLba or 0),
		layout = normalizeLayout(image.layout, files),
		files = files,
		symbols = image.symbols or {},
		configOverride = ImageCatalogUtils.deepCopy(image.configOverride),
	}

	normalized.meta = {
		source = meta.source,
		provider = meta.provider,
		name = meta.name or meta.provider,
	}

	return normalized
end

local function resolveSource(imageConfig)
	return tostring(
		imageConfig.SOURCE
			or (imageConfig.IMPORT_IMAGE and "imported")
			or (imageConfig.RAW_IMAGE and "raw")
			or DEFAULT_SOURCE
	)
end

local function resolveEntry(catalog, name, errorPrefix)
	local entry = catalog[name]
	assert(entry, errorPrefix .. name)
	return entry
end

local function providerImage(provider, config)
	if type(provider) == "function" then
		return provider(config)
	end
	if type(provider) == "table" and type(provider.build) == "function" then
		return provider.build(config)
	end
	if type(provider) == "table" then
		return provider
	end
	error("invalid external x86 image provider")
end

local function rawImage(rawEntry)
	if type(rawEntry) == "function" then
		return rawEntry()
	end
	if type(rawEntry) == "table" then
		return rawEntry
	end
	error("invalid raw x86 image entry")
end

function BootImageLoader._normalizeByteArray(value)
	if type(value) == "table" then
		local out = {}
		for index, byte in ipairs(value) do
			out[index] = (tonumber(byte) or 0) % 256
		end
		return out
	end
	if type(value) == "string" then
		local out = {}
		for index = 1, #value do
			out[index] = string.byte(value, index)
		end
		return out
	end
	error("x86 image byte payload must be a table or string")
end

function BootImageLoader._normalizeSectorPayload(sector)
	local normalized = BootImageLoader._normalizeByteArray(sector)
	local out = {}
	for index = 1, 512 do
		out[index] = normalized[index] or 0
	end
	return out
end

function BootImageLoader._normalizeSectors(sectors)
	assert(type(sectors) == "table", "x86 sectors payload must be a table")
	local out = {}
	for lba, sector in pairs(sectors) do
		out[tonumber(lba) or 0] = BootImageLoader._normalizeSectorPayload(sector)
	end
	return out
end

function BootImageLoader._diskBytesToSectors(diskBytes, startLba)
	local bytes = BootImageLoader._normalizeByteArray(diskBytes)
	local sectors = {}
	local sectorCount = math.max(1, math.ceil(#bytes / 512))
	for sectorIndex = 0, sectorCount - 1 do
		local sector = {}
		for byteIndex = 1, 512 do
			sector[byteIndex] = bytes[sectorIndex * 512 + byteIndex] or 0
		end
		sectors[(tonumber(startLba) or 0) + sectorIndex] = sector
	end
	return sectors
end

function BootImageLoader.load(config)
	MachineProfile.validateConfig(config)

	local x86 = config.X86 or {}
	local imageConfig = x86.IMAGE or {}
	local source = resolveSource(imageConfig)

	if source == "imported" then
		local importName = tostring(imageConfig.IMPORT_IMAGE or imageConfig.NAME or DEFAULT_IMAGE_NAME)
		local entry = resolveEntry(ImportedImageCatalog, importName, "unknown x86 imported image entry: ")
		local image = rawImage(entry)
		return normalizeImage(image, {
			config = config,
			source = "imported",
			provider = importName,
			name = image and image.name or importName,
		})
	end

	if source == "raw" then
		local rawName = tostring(imageConfig.RAW_IMAGE or imageConfig.NAME or DEFAULT_IMAGE_NAME)
		local entry = resolveEntry(RawImageCatalog, rawName, "unknown x86 raw image entry: ")
		local image = rawImage(entry)
		return normalizeImage(image, {
			config = config,
			source = "raw",
			provider = rawName,
			name = image and image.name or rawName,
		})
	end

	local providerName = tostring(imageConfig.PROVIDER or imageConfig.NAME or DEFAULT_IMAGE_NAME)
	local provider = resolveEntry(BootImageCatalog, providerName, "unknown x86 external image provider: ")
	local image = providerImage(provider, config)
	return normalizeImage(image, {
		config = config,
		source = "provider",
		provider = providerName,
		name = image and image.name or providerName,
	})
end

return BootImageLoader
