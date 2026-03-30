local Runner = require("./_runner")
local BootImageCatalog = require("@src/platforms/x86/BootImageCatalog")
local BiosInterrupts = require("@src/platforms/x86/BiosInterrupts")
local DiagnosticsState = require("@src/platforms/x86/HardwareDiagnosticsState")
local MachineProfile = require("@src/platforms/x86/MachineProfile")

local imageName = "ProtectedModeSegmentValidation"
local maxSteps = 4000

local machine = Runner.createDiagnosticMachine({
	X86 = {
		DIAGNOSTICS = {
			PRINT_SUMMARY = false,
		},
	},
})

local entry = assert(BootImageCatalog[imageName], "missing image " .. imageName)
local image = entry.build(machine.config)
local buildConfig = Runner.newConfig({})
buildConfig.X86 = DiagnosticsState.deepCopy(machine.config.X86 or {})
if image.configOverride then
	for key, value in pairs(image.configOverride) do
		buildConfig.X86[key] = DiagnosticsState.deepCopy(value)
	end
end
buildConfig.X86.BOOT_DRIVE = MachineProfile.resolveBootDrive(buildConfig)

if machine.hdd then
	machine.hdd._sectors = {}
	for lba, sector in pairs(image.sectors or {}) do
		machine.hdd:writeSector(lba, sector)
	end
end

if machine.fdc then
	machine.fdc._sectors = {}
	if type(machine.fdc.reset) == "function" then
		machine.fdc:reset()
	end
	local bytes = {}
	for lba = 0, math.max(0, (((image.layout and image.layout.kernelSectorCount) or 0) + 1) - 1) do
		local sector = (image.sectors or {})[lba] or {}
		for i = 1, 512 do
			bytes[#bytes + 1] = sector[i] or 0
		end
	end
	machine.fdc:loadImage(bytes)
end

if machine.rom and image.romBytes then
	machine.rom:flash(image.romBytes)
end

local bios = BiosInterrupts.new(machine, {}, image)
machine.cpu:attachBIOS(bios)
machine.cpu:reset()

local function readBytes(startAddress, count)
	local out = {}
	for offset = 0, count - 1 do
		out[#out + 1] = string.format("%02X", machine.bus:memRead(startAddress + offset))
	end
	return table.concat(out, " ")
end

local function readImageBytes(startAddress, count)
	local out = {}
	local kernelOrigin = 0x0500
	local firstKernelLba = 1
	for offset = 0, count - 1 do
		local absolute = startAddress + offset
		local relative = absolute - kernelOrigin
		local value = 0
		if relative >= 0 then
			local lba = firstKernelLba + math.floor(relative / 512)
			local sector = (image.sectors or {})[lba]
			if sector then
				local sectorOffset = (relative % 512) + 1
				value = sector[sectorOffset] or 0
			end
		end
		out[#out + 1] = string.format("%02X", value)
	end
	return table.concat(out, " ")
end

print("image=" .. imageName)
print("boot drive=" .. tostring(buildConfig.X86.BOOT_DRIVE))
print("initial boot sector bytes @7C00: " .. readBytes(0x7C00, 32))
print("initial kernel bytes @0500: " .. readBytes(0x0500, 32))
print("image kernel bytes @0500: " .. readImageBytes(0x0500, 32))
if image.symbols and image.symbols.kernel then
	local symbols = image.symbols.kernel
	print("symbol GDT=" .. tostring(symbols.GDT))
	print("symbol GDT_DESC=" .. tostring(symbols.GDT_DESC))
	print("symbol IDT=" .. tostring(symbols.IDT))
	print("symbol IDT_DESC=" .. tostring(symbols.IDT_DESC))
	print("symbol TSS=" .. tostring(symbols.TSS))
	print("symbol IRET16_TARGET=" .. tostring(symbols.IRET16_TARGET))
	print("symbol IRETD_TARGET=" .. tostring(symbols.IRETD_TARGET))
	print("symbol FAULT_PHASE=" .. tostring(symbols.FAULT_PHASE))
	print("symbol NULL_DS_FLAG=" .. tostring(symbols.NULL_DS_FLAG))
	print("symbol NULL_FS_FLAG=" .. tostring(symbols.NULL_FS_FLAG))
	print("symbol EXPAND_GP_FLAG=" .. tostring(symbols.EXPAND_GP_FLAG))
	if symbols.GDT_DESC then
		print("image bytes @GDT_DESC: " .. readImageBytes(symbols.GDT_DESC, 8))
		print("symbol bytes @GDT_DESC: " .. readBytes(symbols.GDT_DESC, 8))
	end
	if symbols.IDT_DESC then
		print("image bytes @IDT_DESC: " .. readImageBytes(symbols.IDT_DESC, 8))
		print("symbol bytes @IDT_DESC: " .. readBytes(symbols.IDT_DESC, 8))
	end
	if symbols.TSS then
		print("image bytes @TSS: " .. readImageBytes(symbols.TSS, 16))
		print("symbol bytes @TSS: " .. readBytes(symbols.TSS, 16))
	end
end

local lastMode = nil
local lastCs = nil
local lastIp = nil

for step = 1, maxSteps do
	local stats = machine.cpu:getStats()
	local interesting = step <= 32
		or stats.mode ~= lastMode
		or stats.cs ~= lastCs
		or (stats.cs == 0 and (stats.ip or 0) >= 0x0500)
		or (
			stats.mode == "protected"
			and (stats.cs or 0) == 0x0008
			and (stats.ip or 0) >= 0x0600
			and (stats.ip or 0) <= 0x06F0
		)
		or (step % 256 == 0)
	if interesting then
		local linear = ((stats.pc or 0) % 0x100000000)
		print(
			string.format(
				"pre step=%d mode=%s cs=%04X ip=%04X eip=%08X pc=%05X cr0=%04X esp=%08X gdt=%08X:%04X idt=%08X:%04X bytes=%s",
				step,
				tostring(stats.mode or "?"),
				(stats.cs or 0) % 0x10000,
				(stats.ip or 0) % 0x10000,
				(stats.eip or 0) % 0x100000000,
				linear % 0x100000,
				(stats.cr0 or 0) % 0x10000,
				(stats.esp or 0) % 0x100000000,
				(stats.gdtBase or 0) % 0x100000000,
				(stats.gdtLimit or 0) % 0x10000,
				(stats.idtBase or 0) % 0x100000000,
				(stats.idtLimit or 0) % 0x10000,
				readBytes(linear, 8)
			)
		)
		if stats.mode == "protected" then
			print("stack @esp: " .. readBytes((stats.esp or 0) % 0x100000000, 16))
		end
		if image.symbols and image.symbols.kernel then
			local symbols = image.symbols.kernel
			if symbols.FAULT_PHASE then
				print(
					string.format(
						"fault phase=%02X null_ds=%02X null_fs=%02X expand=%02X",
						machine.bus:memRead(symbols.FAULT_PHASE),
						symbols.NULL_DS_FLAG and machine.bus:memRead(symbols.NULL_DS_FLAG) or 0,
						symbols.NULL_FS_FLAG and machine.bus:memRead(symbols.NULL_FS_FLAG) or 0,
						symbols.EXPAND_GP_FLAG and machine.bus:memRead(symbols.EXPAND_GP_FLAG) or 0
					)
				)
			end
		end
	end

	local ok, result = pcall(function()
		return machine.cpu:step()
	end)
	lastMode = stats.mode
	lastCs = stats.cs
	lastIp = stats.ip

	local screen = DiagnosticsState.readTextScreen(machine, buildConfig):sub(1, 120)
	if interesting or not ok or string.find(screen, "FAIL", 1, true) or string.find(screen, "PASS", 1, true) then
		print("post  result=" .. tostring(result) .. " ok=" .. tostring(ok) .. " screen=" .. screen)
	end
	if not ok or string.find(screen, "FAIL", 1, true) or string.find(screen, "PASS", 1, true) then
		break
	end
end

if machine and machine:isPowered() then
	machine:shutdown()
end
