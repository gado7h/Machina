local BootOSHex = require("@src/platforms/x86/BootOSHex")
local FreeDOSBootHex = require("@src/platforms/x86/FreeDOSBootHex")
local BiosRom = require("@src/platforms/x86/BiosRom")
local MachineProfile = require("@src/platforms/x86/MachineProfile")

local ProductionImages = {}

local function rawHexToBytes(raw)
	if type(raw) == "string" then
		local bytes = {}
		for hexByte in raw:gmatch("0[xX]([0-9A-Fa-f][0-9A-Fa-f])") do
			bytes[#bytes + 1] = tonumber(hexByte, 16)
		end
		if #bytes == 0 then
			local cleaned = raw:gsub("[^0-9A-Fa-f]", "")
			for i = 1, #cleaned, 2 do
				bytes[#bytes + 1] = tonumber(cleaned:sub(i, i + 1), 16) or 0
			end
		end
		return bytes
	end
	if type(raw) == "table" then
		-- Already a byte table (e.g. FreeDOSBootHex format: {0xEB, 0x3C, ...})
		local bytes = {}
		for i = 1, #raw do
			bytes[i] = (tonumber(raw[i]) or 0) % 256
		end
		return bytes
	end
	return {}
end

local function detectFloppyGeometry(byteCount)
	if byteCount <= (360 * 1024) then
		return 40, 2, 9
	end
	if byteCount <= (720 * 1024) then
		return 80, 2, 9
	end
	return 80, 2, 18
end

local function bytesToSectors(bytes, sectorSize)
	sectorSize = sectorSize or 512
	local byteCount = #bytes
	local totalSectors = math.max(1, math.ceil(byteCount / sectorSize))
	local expectedSize = totalSectors * sectorSize

	while #bytes < expectedSize do
		table.insert(bytes, 0)
	end

	local sectors = {}
	for sectorIndex = 0, totalSectors - 1 do
		local sectorData = {}
		for byteIndex = 1, sectorSize do
			local offset = sectorIndex * sectorSize + byteIndex
			sectorData[byteIndex] = bytes[offset] or 0
		end
		sectors[sectorIndex] = sectorData
	end

	return sectors, totalSectors
end

local function buildBootOS(config)
	local hexStr = BootOSHex
	local bytes = rawHexToBytes(hexStr)

	local byteCount = #bytes
	local tracks, heads, sectorsPerTrack = detectFloppyGeometry(byteCount)
	local sectors, totalSectors = bytesToSectors(bytes)

	local bootOSConfig = {}
	for k, v in pairs(config) do
		bootOSConfig[k] = v
	end
	bootOSConfig.X86 = bootOSConfig.X86 or {}
	for k, v in pairs(config.X86 or {}) do
		bootOSConfig.X86[k] = v
	end
	bootOSConfig.X86.KERNEL_LOAD_SEG = 0x0780

	local biosArtifact = BiosRom.buildArtifact(bootOSConfig)

	local configOverride = {
		KERNEL_LOAD_SEG = 0x0780,
		FLOPPY_A_PRESENT = true,
		FLOPPY_A_TYPE = MachineProfile.floppyTypeForGeometry(tracks, heads, sectorsPerTrack),
		FLOPPY_TRACKS = tracks,
		FLOPPY_HEADS = heads,
		FLOPPY_SECTORS = sectorsPerTrack,
		HEADS = heads,
		SECTORS_PER_TRACK = sectorsPerTrack,
		DIAGNOSTICS = {
			PRINT_SUMMARY = false,
		},
	}

	return {
		name = "bootOS",
		romBytes = BiosRom.buildROMBytes(bootOSConfig, biosArtifact),
		sectors = sectors,
		layout = {
			kernelSectorStart = 1,
			kernelSectorCount = math.max(0, totalSectors - 1),
			kernelLoadSeg = 0x0780,
			fsSuperSector = 0,
			rootDirSector = 0,
			rootDirSectorCount = 0,
			dataStartSector = 0,
			fileCount = 0,
			totalSectors = totalSectors,
		},
		configOverride = configOverride,
		files = {},
		symbols = {
			bios = biosArtifact.symbols,
		},
		meta = {
			source = "embedded",
			provider = "bootOS",
			name = "bootOS",
		},
	}
end

ProductionImages.bootOS = {
	name = "bootOS",
	build = buildBootOS,
}

local function buildFreeDOS(config)
	local hexStr = FreeDOSBootHex
	local bytes = rawHexToBytes(hexStr)

	local byteCount = #bytes
	local tracks, heads, sectorsPerTrack = 80, 2, 18
	local sectors, totalSectors = bytesToSectors(bytes)

	local bootOSConfig = {}
	for k, v in pairs(config) do
		bootOSConfig[k] = v
	end
	bootOSConfig.X86 = bootOSConfig.X86 or {}
	for k, v in pairs(config.X86 or {}) do
		bootOSConfig.X86[k] = v
	end
	bootOSConfig.X86.KERNEL_LOAD_SEG = 0x07C0
	bootOSConfig.X86.BOOT_DRIVE = 0x00

	local biosArtifact = BiosRom.buildArtifact(bootOSConfig)

	local configOverride = {
		KERNEL_LOAD_SEG = 0x07C0,
		FLOPPY_A_PRESENT = true,
		FLOPPY_A_TYPE = MachineProfile.floppyTypeForGeometry(tracks, heads, sectorsPerTrack),
		FLOPPY_TRACKS = tracks,
		FLOPPY_HEADS = heads,
		FLOPPY_SECTORS = sectorsPerTrack,
		HEADS = heads,
		SECTORS_PER_TRACK = sectorsPerTrack,
		DIAGNOSTICS = {
			PRINT_SUMMARY = false,
		},
	}

	return {
		name = "freeDOS",
		romBytes = BiosRom.buildROMBytes(bootOSConfig, biosArtifact),
		sectors = sectors,
		layout = {
			kernelSectorStart = 0,
			kernelSectorCount = totalSectors,
			kernelLoadSeg = 0x07C0,
			fsSuperSector = 0,
			rootDirSector = 0,
			rootDirSectorCount = 0,
			dataStartSector = 0,
			fileCount = 0,
			totalSectors = totalSectors,
		},
		configOverride = configOverride,
		files = {},
		symbols = {
			bios = biosArtifact.symbols,
		},
		meta = {
			source = "embedded",
			provider = "freeDOS",
			name = "freeDOS",
		},
	}
end

ProductionImages.freeDOS = {
	name = "freeDOS",
	build = buildFreeDOS,
}

return ProductionImages
