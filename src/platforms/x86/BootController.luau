local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")
local BiosRom = require("@src/platforms/x86/BiosRom")
local HardwareDiagnostics = require("@src/platforms/x86/HardwareDiagnostics")
local BootImageLoader = require("@src/platforms/x86/BootImageLoader")
local MachineProfile = require("@src/platforms/x86/MachineProfile")

local BootController = {}
BootController.__index = BootController

local function sectorsToBytes(sectors)
	local maxLba = -1
	for lba in pairs(sectors or {}) do
		maxLba = math.max(maxLba, tonumber(lba) or -1)
	end

	local bytes = {}
	for lba = 0, maxLba do
		local sector = sectors[lba] or {}
		for i = 1, 512 do
			bytes[#bytes + 1] = sector[i] or 0
		end
	end
	return bytes
end

local function imageByteCount(image)
	local maxLba = -1
	for lba in pairs((image and image.sectors) or {}) do
		maxLba = math.max(maxLba, tonumber(lba) or -1)
	end
	return math.max(0, maxLba + 1) * 512
end

local function writeWord(cpu, address, value)
	local word = (tonumber(value) or 0) % 0x10000
	cpu:writePhysical8(address, word % 256)
	cpu:writePhysical8(address + 1, math.floor(word / 256) % 256)
end

function BootController.new(machine)
	local self = setmetatable({}, BootController)
	self.machine = machine
	self.config = machine.config
	self.x86 = machine.config.X86 or {}
	self._profile = MachineProfile.validateConfig(machine.config)
	self._trace = self._profile.trace
	self.image = nil
	self.bios = nil
	self._kernelLinear = ((self.x86.KERNEL_LOAD_SEG or 0x1000) * 16) + (self.x86.KERNEL_LOAD_OFF or 0)
	self._bootLinear = ((self.x86.BOOT_SECTOR_LOAD_SEG or 0) * 16) + (self.x86.BOOT_SECTOR_LOAD_OFF or 0x7C00)
	self._readyFlagLinear = nil

	if self.x86.BOOT_DRIVE == nil then
		self.x86.BOOT_DRIVE = 0x00
	end

	return self
end

function BootController:_refreshProfile()
	self._profile = MachineProfile.validateConfig(self.machine.config)
	self._trace = self._profile.trace
	self.x86 = self.machine.config.X86 or {}
	if self.machine then
		self.machine._trace = self._trace
	end
	if self.machine and self.machine.bus then
		self.machine.bus._trace = self._trace
	end
end

function BootController:_traceLog(flagName, message)
	if not self._trace or self._trace.ENABLED ~= true then
		return
	end
	if flagName and self._trace[flagName] ~= true then
		return
	end
	if self.machine and self.machine.bus and self.machine.bus._log then
		self.machine.bus:_log("BOOT", message)
	end
end

function BootController:_setX86Field(key, value)
	self.machine.config.X86 = self.machine.config.X86 or {}
	self.machine.boardConfig.X86 = self.machine.boardConfig.X86 or {}
	self.machine.config.X86[key] = value
	self.machine.boardConfig.X86[key] = value
	self.x86[key] = value
end

function BootController:_setBootDevice(device)
	local bootDrive = MachineProfile.bootDriveForDevice(device)
	self:_setX86Field("BOOT_DRIVE", bootDrive)
	self:_traceLog(
		"DISK",
		string.format(
			"boot device resolved to %s (drive %02Xh, order=%s)",
			tostring(device),
			bootDrive,
			table.concat(self._profile.bootOrder, ",")
		)
	)
end

function BootController:applyConfigOverride(override)
	if not override then
		return
	end

	for k, v in pairs(override) do
		self:_setX86Field(k, v)
	end

	if (override.FLOPPY_TRACKS or override.FLOPPY_HEADS or override.FLOPPY_SECTORS) and override.FLOPPY_A_TYPE == nil then
		self:_setX86Field(
			"FLOPPY_A_TYPE",
			MachineProfile.floppyTypeForGeometry(
				self.x86.FLOPPY_TRACKS,
				self.x86.FLOPPY_HEADS,
				self.x86.FLOPPY_SECTORS
			)
		)
	end

	if override.KERNEL_LOAD_SEG then
		self._kernelLinear = override.KERNEL_LOAD_SEG * 16
	end
	if override.KERNEL_LOAD_OFF then
		self._kernelLinear = self._kernelLinear + override.KERNEL_LOAD_OFF
	end
	if override.BOOT_SECTOR_LOAD_SEG or override.BOOT_SECTOR_LOAD_OFF then
		self._bootLinear = ((self.x86.BOOT_SECTOR_LOAD_SEG or 0) * 16) + (self.x86.BOOT_SECTOR_LOAD_OFF or 0x7C00)
	end

	if self.machine.rtc and type(self.machine.rtc.refreshHardwareTable) == "function" then
		self.machine.rtc:refreshHardwareTable(self.machine.boardConfig)
	end

	self:_refreshProfile()
end

function BootController:_resolveBootDevice(image)
	self:_refreshProfile()
	local device = MachineProfile.resolveBootDevice(self.machine.config, {
		imageByteCount = imageByteCount(image),
	})
	assert(device ~= nil, "x86 machine profile has no bootable device for the loaded image")
	return device
end

function BootController:_clearBootMedia()
	if self.machine.hdd then
		self.machine.hdd._sectors = {}
	end
	if self.machine.fdc then
		self.machine.fdc._sectors = {}
		if type(self.machine.fdc.reset) == "function" then
			self.machine.fdc:reset()
		end
	end
end

function BootController:_loadBootMedia(image, device)
	self:_clearBootMedia()

	if device == "floppy" then
		assert(self.machine.fdc ~= nil, "boot order selected floppy but the FDC is unavailable")
		local bytes = sectorsToBytes(image.sectors)
		assert(type(self.machine.fdc.loadImage) == "function", "FDC cannot accept raw image bytes")
		self.machine.fdc:loadImage(bytes)
		self:_traceLog("DISK", string.format("loaded %d bytes into floppy drive A:", #bytes))
		return
	end

	assert(self.machine.hdd ~= nil, "boot order selected ATA but the ATA controller is unavailable")
	for lba, sector in pairs(image.sectors or {}) do
		self.machine.hdd:writeSector(lba, sector)
	end
	self:_traceLog("DISK", string.format("loaded %d sectors into ATA drive 0x80", imageByteCount(image) / 512))
end

function BootController:_rebuildBiosRom()
	local biosArtifact = BiosRom.buildArtifact(self.machine.config)
	self.image.romBytes = BiosRom.buildROMBytes(self.machine.config, biosArtifact)
	if self.image.symbols == nil then
		self.image.symbols = {}
	end
	self.image.symbols.bios = biosArtifact.symbols
end

function BootController:startBoot()
	self:_refreshProfile()
	self.machine:_setBootStage("BIOS")
	self.machine.gpu:clearHostOverlay()
	self.machine.gpu:biosSetVideoMode(0x03)

	if self.machine.bus and self.machine.bus.timer then
		self.machine.bus.timer._enabled = false
		self.machine.bus.timer._irqEnabled = false
	end

	local ok, imageOrErr = pcall(function()
		return BootImageLoader.load(self.config)
	end)
	if not ok then
		self.machine:_setBootStage("FAULT", tostring(imageOrErr))
		self.machine.gpu:hostClear(0x0C)
		self.machine.gpu:hostWriteLine("x86 image build failed", 0x0C)
		self.machine.gpu:hostWriteLine(tostring(imageOrErr), 0x0C)
		return
	end

	self.image = imageOrErr

	if self.image.configOverride then
		self:applyConfigOverride(self.image.configOverride)
	end

	local bootDevice = self:_resolveBootDevice(self.image)
	self:_setBootDevice(bootDevice)
	self:_loadBootMedia(self.image, bootDevice)
	self:_rebuildBiosRom()

	self.machine.rom:flash(self.image.romBytes)
	self.machine.cpu:reset()

	local diagnostics = nil
	local diagnosticsConfig = (self.x86 and self.x86.DIAGNOSTICS) or {}
	if diagnosticsConfig.ENABLED ~= false then
		self.machine:_setBootStage("DIAG")
		diagnostics = HardwareDiagnostics.run(self.machine, self.config)
		if diagnosticsConfig.PRINT_SUMMARY ~= false then
			local color = diagnostics.passed and 0x0A or 0x0E
			self.machine.gpu:hostClear(color)
			self.machine.gpu:hostWriteLine(
				string.format("Device diagnostics %d/%d", diagnostics.passedCount, diagnostics.totalCount),
				color
			)
		end
		self.machine.cpu:reset()
		self.machine.gpu:biosSetVideoMode(0x03)
	end

	self:_initializeIVT()
	self:_initializeBDA()

	if self.machine.bus and self.machine.bus.timer then
		self.machine.bus.timer._enabled = true
		self.machine.bus.timer._irqEnabled = true
	end

	self.bios = BiosInterrupts.new(self.machine, self, self.image)
	self.machine.cpu:attachBIOS(self.bios)
	local kernelSymbols = self.image.symbols and self.image.symbols.kernel or nil
	local readyFlagOffset = kernelSymbols and kernelSymbols.BOOT_READY_FLAG or nil
	self._readyFlagLinear = readyFlagOffset and (self._kernelLinear + readyFlagOffset) or nil

	self.machine:setBootRecord({
		profile = "x86-bios",
		machineProfile = self._profile.profile,
		bootOrder = table.clone(self._profile.bootOrder),
		bootDevice = bootDevice,
		bootDrive = self.x86.BOOT_DRIVE,
		imageSource = self.image.meta and self.image.meta.source or "external",
		imageProvider = self.image.meta and self.image.meta.provider or "ProtectedModeBringUp",
		imageName = self.image.meta and self.image.meta.name or "ProtectedModeBringUp",
		kernelSectorStart = self.image.layout.kernelSectorStart,
		kernelSectorCount = self.image.layout.kernelSectorCount,
		fsSuperSector = self.image.layout.fsSuperSector,
		rootDirSector = self.image.layout.rootDirSector,
		rootDirSectorCount = self.image.layout.rootDirSectorCount,
		dataStartSector = self.image.layout.dataStartSector,
		fileCount = self.image.layout.fileCount,
		readyFlagLinear = self._readyFlagLinear,
		diagnostics = diagnostics,
	})
	self.machine.gpu:clearHostOverlay()
	self.machine:_setBootStage("BIOS")
end

function BootController:onDiskRead(startLba, _count, bufferAddress)
	if startLba == 0 and bufferAddress == self._bootLinear then
		self.machine:_setBootStage("BOOT")
	elseif startLba >= (self.image.layout.kernelSectorStart - 1) and bufferAddress == self._kernelLinear then
		self.machine:_setBootStage("KERNEL")
	end
end

function BootController:_leftBootSector(pc)
	local linearPc = tonumber(pc) or 0
	local romBase = tonumber(self.x86.ROM_BASE) or 0xF0000
	local romSize = tonumber(self.x86.ROM_SIZE) or 0x10000
	local inRom = linearPc >= romBase and linearPc < (romBase + romSize)
	local inBootSector = linearPc >= self._bootLinear and linearPc < (self._bootLinear + 512)
	return (not inRom) and (not inBootSector)
end

function BootController:tick(_dt)
	local stage = self.machine:getBootStage()
	local pc = self.machine.cpu:getLinearPC()

	if stage == "BOOT" then
		if self._readyFlagLinear and self.machine.cpu:readPhysical16(self._readyFlagLinear) == 1 then
			self.machine:_setBootStage("RUNNING")
			return
		end

		if self:_leftBootSector(pc) then
			if self._readyFlagLinear then
				self.machine:_setBootStage("KERNEL")
				stage = "KERNEL"
			else
				self.machine:_setBootStage("RUNNING")
				return
			end
		end
	end

	if stage == "KERNEL" and not self._readyFlagLinear then
		self.machine:_setBootStage("RUNNING")
		return
	end

	if stage ~= "KERNEL" then
		return
	end

	if self._readyFlagLinear and self.machine.cpu:readPhysical16(self._readyFlagLinear) == 1 then
		self.machine:_setBootStage("RUNNING")
		return
	end

	if not self._readyFlagLinear and pc >= self._kernelLinear then
		self.machine:_setBootStage("RUNNING")
	end
end

function BootController:_initializeIVT()
	local cpu = self.machine.cpu
	local romBase = self.x86.ROM_BASE or 0xF0000
	local biosSymbols = self.image and self.image.symbols and self.image.symbols.bios or nil
	local defaultHandler = (biosSymbols and biosSymbols.DEFAULT_INT_HANDLER) or (self.x86.BIOS_ENTRY_OFFSET or 0x0100)
	local romSegment = math.floor(romBase / 16) % 0x10000
	for vector = 0, 0xFF do
		local ivtOffset = vector * 4
		local offsetLow = defaultHandler % 256
		local offsetHigh = math.floor(defaultHandler / 256) % 256
		cpu:writePhysical8(ivtOffset, offsetLow)
		cpu:writePhysical8(ivtOffset + 1, offsetHigh)
		cpu:writePhysical8(ivtOffset + 2, bit32.band(romSegment, 0xFF))
		cpu:writePhysical8(ivtOffset + 3, bit32.rshift(romSegment, 8) % 0x100)
	end
end

function BootController:_initializeBDA()
	local cpu = self.machine.cpu
	local profile = MachineProfile.validateConfig(self.machine.config)
	local cols = tonumber(self.config.TEXT_COLS) or 80
	local rows = tonumber(self.config.TEXT_ROWS) or 25
	local charHeight = tonumber(self.config.CHAR_H) or 16
	local baseMemK = math.floor((tonumber(self.x86.LOW_RAM_SIZE) or 0xA0000) / 1024)
	local equipmentWord = MachineProfile.getEquipmentWord(self.machine.config)

	for address = 0x0400, 0x04FF do
		cpu:writePhysical8(address, 0x00)
	end

	writeWord(cpu, 0x0400, (self.config.PORT and self.config.PORT.COM1_BASE) or 0x03F8)
	writeWord(cpu, 0x0410, equipmentWord)
	writeWord(cpu, 0x0413, baseMemK)

	cpu:writePhysical8(0x0417, 0x00)
	cpu:writePhysical8(0x0418, 0x00)
	cpu:writePhysical8(0x0419, 0x00)
	writeWord(cpu, 0x041A, 0x001E)
	writeWord(cpu, 0x041C, 0x001E)

	cpu:writePhysical8(0x043E, 0x00)
	cpu:writePhysical8(0x043F, 0x00)
	cpu:writePhysical8(0x0440, 0x00)
	cpu:writePhysical8(0x0441, 0x00)
	cpu:writePhysical8(0x0447, 0x03)
	writeWord(cpu, 0x044A, cols)
	writeWord(cpu, 0x044C, 0x1000)
	writeWord(cpu, 0x044E, 0x0000)
	cpu:writePhysical8(0x0462, 0x00)
	writeWord(cpu, 0x0463, 0x03D4)
	cpu:writePhysical8(0x0475, self.machine.hdd and 0x01 or 0x00)
	cpu:writePhysical8(0x0484, math.max(0, rows - 1))
	cpu:writePhysical8(0x0485, charHeight)
	cpu:writePhysical8(0x0487, 0x60)
	cpu:writePhysical8(0x0488, profile.floppy.present and profile.floppy.nibble or 0x00)
	cpu:writePhysical8(0x0490, self.x86.BOOT_DRIVE or 0x00)
end

return BootController
