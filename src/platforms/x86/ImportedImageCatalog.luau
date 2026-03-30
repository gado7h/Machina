local BootImageCatalog = require("@src/platforms/x86/BootImageCatalog")
local ImageCatalogUtils = require("@src/platforms/x86/ImageCatalogUtils")

local ImportedImageCatalog = {}

local FROZEN_IMPORT_CONFIG = {
	X86 = {
		MACHINE_PROFILE = "ibm-pc-386-bios-v2",
		BOOT_DRIVE = 0x00,
		BOOT_ORDER = { "floppy", "ata" },
		BIOS_ENTRY_OFFSET = 0x0100,
		RESET_VECTOR_SEG = 0xF000,
		RESET_VECTOR_OFF = 0xFFF0,
		KERNEL_LOAD_SEG = 0x1000,
		KERNEL_LOAD_OFF = 0x0000,
		VIDEO_BASE = 0x000A0000,
		VIDEO_SIZE = 0x20000,
		TEXT_BUFFER_BASE = 0x000B8000,
		TEXT_BUFFER_SIZE = 0x8000,
		SECTORS_PER_TRACK = 18,
		HEADS = 2,
		FLOPPY_A_PRESENT = true,
		FLOPPY_A_TYPE = "35_1440k",
		FLOPPY_TRACKS = 80,
		FLOPPY_HEADS = 2,
		FLOPPY_SECTORS = 18,
	},
}

local function buildCatalogImage(entryName, config)
	local entry = BootImageCatalog[entryName]
	assert(entry, "unknown x86 imported image entry: " .. tostring(entryName))

	if type(entry) == "table" and type(entry.build) == "function" then
		return entry.build(config)
	end
	return entry
end

local function snapshotImage(image)
	assert(type(image) == "table", "x86 imported image builder returned an invalid image")
	assert(type(image.sectors) == "table", "x86 imported image is missing sectors")

	return {
		name = image.name,
		diskBytes = ImageCatalogUtils.sectorsToDiskBytes(image.sectors),
		layout = ImageCatalogUtils.deepCopy(image.layout or {}),
		files = ImageCatalogUtils.deepCopy(image.files or {}),
		symbols = ImageCatalogUtils.deepCopy(image.symbols or {}),
		configOverride = ImageCatalogUtils.deepCopy(image.configOverride),
		meta = ImageCatalogUtils.deepCopy(image.meta),
	}
end

local function buildImportedImage(entryName)
	local frozenConfig = ImageCatalogUtils.deepCopy(FROZEN_IMPORT_CONFIG)
	local image = buildCatalogImage(entryName, frozenConfig)
	return snapshotImage(image)
end

ImportedImageCatalog.ProtectedModeBringUp = buildImportedImage("bootOS")
ImportedImageCatalog.bootOS = buildImportedImage("bootOS")

function ImportedImageCatalog.get(name)
	return ImportedImageCatalog[name]
end

return ImportedImageCatalog
