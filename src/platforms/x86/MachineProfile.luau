local MachineProfile = {}

MachineProfile.LOCKED_PROFILE = "ibm-pc-386-bios-v2"

local DEFAULT_BOOT_ORDER = { "floppy", "ata" }

local FLOPPY_TYPES = {
	none = {
		present = false,
		nibble = 0x00,
		tracks = 0,
		heads = 0,
		sectors = 0,
		size = 0,
	},
	["525_360k"] = {
		present = true,
		nibble = 0x01,
		tracks = 40,
		heads = 2,
		sectors = 9,
		size = 360 * 1024,
	},
	["35_720k"] = {
		present = true,
		nibble = 0x03,
		tracks = 80,
		heads = 2,
		sectors = 9,
		size = 720 * 1024,
	},
	["35_1440k"] = {
		present = true,
		nibble = 0x04,
		tracks = 80,
		heads = 2,
		sectors = 18,
		size = 1440 * 1024,
	},
}

local VALID_BOOT_DEVICE = {
	floppy = true,
	ata = true,
}

local TRACE_DEFAULTS = {
	ENABLED = false,
	CPU_STATE = false,
	IRQ_ROUTING = false,
	PORT_IO = false,
	BIOS_CALLS = false,
	DISK = false,
}

local function shallowCopy(value)
	local out = {}
	for key, child in pairs(value or {}) do
		out[key] = child
	end
	return out
end

local function countEnabledSerialPorts(config)
	local ports = config.PORT or {}
	local count = 0
	if tonumber(ports.COM1_BASE) then
		count = count + 1
	end
	return count
end

local function ataPresent(config)
	return (tonumber(config.DISK_BLOCKS) or 0) > 0
end

function MachineProfile.getMachineProfile(config)
	local x86 = (config and config.X86) or {}
	return tostring(x86.MACHINE_PROFILE or MachineProfile.LOCKED_PROFILE)
end

function MachineProfile.getTraceConfig(config)
	local trace = shallowCopy(TRACE_DEFAULTS)
	local configured = ((config or {}).X86 or {}).TRACE or {}
	for key, value in pairs(configured) do
		trace[key] = value
	end
	return trace
end

function MachineProfile.normalizeBootOrder(value)
	if type(value) ~= "table" then
		return table.clone(DEFAULT_BOOT_ORDER)
	end

	local out = {}
	local seen = {}
	for _, entry in ipairs(value) do
		local device = tostring(entry)
		if VALID_BOOT_DEVICE[device] and not seen[device] then
			out[#out + 1] = device
			seen[device] = true
		end
	end

	if #out == 0 then
		return table.clone(DEFAULT_BOOT_ORDER)
	end

	return out
end

function MachineProfile.floppyTypeForGeometry(tracks, heads, sectors)
	local normalizedTracks = tonumber(tracks) or 0
	local normalizedHeads = tonumber(heads) or 0
	local normalizedSectors = tonumber(sectors) or 0

	if normalizedHeads == 2 and normalizedSectors == 9 and normalizedTracks <= 40 then
		return "525_360k"
	end
	if normalizedHeads == 2 and normalizedSectors == 9 and normalizedTracks >= 80 then
		return "35_720k"
	end
	if normalizedHeads == 2 and normalizedSectors == 18 and normalizedTracks >= 80 then
		return "35_1440k"
	end
	return "none"
end

function MachineProfile.getFloppyDriveA(config)
	local x86 = (config and config.X86) or {}
	local floppyPresent = x86.FLOPPY_A_PRESENT ~= false
	local requestedType = tostring(x86.FLOPPY_A_TYPE or "35_1440k")
	local inferredType = MachineProfile.floppyTypeForGeometry(x86.FLOPPY_TRACKS, x86.FLOPPY_HEADS, x86.FLOPPY_SECTORS)
	local typeName = requestedType

	if typeName == "auto" then
		typeName = inferredType
	end
	if typeName == "none" and floppyPresent then
		typeName = inferredType ~= "none" and inferredType or "35_1440k"
	end
	if not FLOPPY_TYPES[typeName] then
		typeName = inferredType ~= "none" and inferredType or "35_1440k"
	end
	if not floppyPresent then
		typeName = "none"
	end

	local template = FLOPPY_TYPES[typeName] or FLOPPY_TYPES.none
	local geometry = {
		type = typeName,
		present = template.present and floppyPresent,
		nibble = template.nibble,
		tracks = tonumber(x86.FLOPPY_TRACKS) or template.tracks,
		heads = tonumber(x86.FLOPPY_HEADS) or template.heads,
		sectors = tonumber(x86.FLOPPY_SECTORS) or template.sectors,
		size = template.size,
	}

	if not geometry.present then
		geometry.tracks = 0
		geometry.heads = 0
		geometry.sectors = 0
	end

	return geometry
end

function MachineProfile.getEquipmentWord(config)
	local floppy = MachineProfile.getFloppyDriveA(config)
	local serialPorts = countEnabledSerialPorts(config)
	local floppyDrives = floppy.present and 1 or 0

	local word = 0x0020
	if floppy.present then
		word = bit32.bor(word, 0x0001)
	end
	word = bit32.bor(word, bit32.lshift(math.max(0, math.min(3, floppyDrives - 1)), 6))
	word = bit32.bor(word, bit32.lshift(math.max(0, math.min(7, serialPorts)), 9))
	return word
end

function MachineProfile.getCmosEquipmentByte(config)
	local floppy = MachineProfile.getFloppyDriveA(config)
	return bit32.bor(floppy.present and 0x01 or 0x00, 0x40)
end

function MachineProfile.deviceNameForBootDrive(drive)
	if (tonumber(drive) or 0) >= 0x80 then
		return "ata"
	end
	return "floppy"
end

function MachineProfile.bootDriveForDevice(device)
	if tostring(device) == "ata" then
		return 0x80
	end
	return 0x00
end

function MachineProfile.resolveBootDevice(config, options)
	local descriptor = MachineProfile.validateConfig(config)
	local imageByteCount = tonumber(options and options.imageByteCount) or 0
	local floppy = descriptor.floppy
	local floppyFitsImage = imageByteCount <= 0 or (floppy.present and imageByteCount <= math.max(0, floppy.size))

	for _, device in ipairs(descriptor.bootOrder) do
		if device == "floppy" and floppy.present and floppyFitsImage then
			return "floppy"
		end
		if device == "ata" and descriptor.ata.present then
			return "ata"
		end
	end

	if floppy.present and floppyFitsImage then
		return "floppy"
	end
	if descriptor.ata.present then
		return "ata"
	end
	return nil
end

function MachineProfile.resolveBootDrive(config, options)
	local device = MachineProfile.resolveBootDevice(config, options)
	if device == nil then
		return nil
	end
	return MachineProfile.bootDriveForDevice(device)
end

function MachineProfile.validateConfig(config)
	local profile = MachineProfile.getMachineProfile(config)
	assert(
		profile == MachineProfile.LOCKED_PROFILE,
		"unsupported x86 machine profile: " .. tostring(profile) .. " (expected " .. MachineProfile.LOCKED_PROFILE .. ")"
	)

	local bootOrder = MachineProfile.normalizeBootOrder(((config or {}).X86 or {}).BOOT_ORDER)
	local floppy = MachineProfile.getFloppyDriveA(config)
	local hasAta = ataPresent(config)
	local hasBootableDevice = false
	for _, device in ipairs(bootOrder) do
		if device == "floppy" and floppy.present then
			hasBootableDevice = true
			break
		end
		if device == "ata" and hasAta then
			hasBootableDevice = true
			break
		end
	end
	assert(hasBootableDevice, "x86 machine profile requires at least one bootable device in BOOT_ORDER")

	return {
		profile = profile,
		bootOrder = bootOrder,
		floppy = floppy,
		ata = {
			present = hasAta,
		},
		trace = MachineProfile.getTraceConfig(config),
	}
end

return MachineProfile
