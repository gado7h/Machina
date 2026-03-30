local Assembler8086 = require("@src/platforms/x86/Assembler8086")
local Cpu80386 = require("@src/platforms/x86/Cpu80386")

local ProtectedModeSelfTest = {}

local SMOKE_SOURCE = table.concat({
	"ORG 0x0500",
	"START:",
	"  CLI",
	"  LGDT [GDT_DESC]",
	"  MOV AX, 1",
	"  LMSW AX",
	"  DB 0xEA",
	"  DW PM_ENTRY",
	"  DW 0x0008",
	"PM_ENTRY:",
	"  MOV AX, 0x0010",
	"  MOV DS, AX",
	"  MOV ES, AX",
	"  MOV SS, AX",
	"  MOV BYTE [PM_FLAG], 0x5A",
	"  HLT",
	"GDT:",
	"  DW 0x0000, 0x0000, 0x0000, 0x0000",
	"  DW 0xFFFF, 0x0000, 0x9A00, 0x00CF",
	"  DW 0xFFFF, 0x0000, 0x9200, 0x00CF",
	"GDT_DESC:",
	"  DW GDT_END - GDT - 1",
	"  DW GDT",
	"  DW 0x0000",
	"GDT_END:",
	"PM_FLAG:",
	"  DB 0x00",
}, "\n")

local function readRegion(ram, origin, length)
	local bytes = {}
	for index = 0, length - 1 do
		bytes[index + 1] = ram:memRead(origin + index)
	end
	return bytes
end

local function writeRegion(ram, origin, bytes)
	for index = 1, #bytes do
		ram:memWrite(origin + index - 1, bytes[index])
	end
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in pairs(value) do
		out[key] = deepCopy(child)
	end
	return out
end

function ProtectedModeSelfTest.run(machine, config)
	local artifact = Assembler8086.compile(SMOKE_SOURCE)
	local origin = artifact.origin or 0x0500
	local flagOffset = artifact.symbols and artifact.symbols.PM_FLAG
	if not flagOffset then
		return false, "smoke symbol PM_FLAG missing"
	end

	local previousBytes = readRegion(machine.ram, origin, #artifact.bytes)
	writeRegion(machine.ram, origin, artifact.bytes)

	local cpu = machine.cpu
	local usingLiveCPU = cpu and type(cpu.setSeg) == "function" and cpu.protectedMode ~= nil
	if not usingLiveCPU then
		cpu = Cpu80386.new(machine.bus, config)
	end

	local cpuSnapshot = nil
	if usingLiveCPU then
		cpuSnapshot = {
			reg16 = deepCopy(cpu.reg16),
			reg32 = deepCopy(cpu.reg32),
			seg = deepCopy(cpu.seg),
			ip = cpu.ip,
			eip = cpu.eip,
			flags = cpu.flags,
			halted = cpu.halted,
			gdtr = deepCopy(cpu.gdtr),
			idtr = deepCopy(cpu.idtr),
			cr0 = cpu.cr0,
			protectedMode = cpu.protectedMode,
			segCache = deepCopy(cpu.segCache),
			lastError = cpu._lastError,
			lastStep = deepCopy(cpu._lastStep),
			stats = deepCopy(cpu.stats),
		}
	end

	local ok, passed, detail = pcall(function()
		cpu:reset()
		cpu:setSeg(1, 0x0000)
		cpu:setSeg(3, 0x0000)
		cpu:setSeg(2, 0x0000)
		cpu.reg16.SP = 0x7B00
		cpu.ip = origin

		for _ = 1, 64 do
			cpu:step()
			if cpu.halted then
				break
			end
		end

		local flagValue = machine.ram:memRead(flagOffset)
		local isPassed = cpu.protectedMode and cpu.seg.CS == 0x0008 and cpu.seg.DS == 0x0010 and flagValue == 0x5A
		local result = string.format(
			"mode=%s cs=%04X ds=%04X cr0=%04X flag=%02X",
			cpu.protectedMode and "protected" or "real",
			cpu.seg.CS,
			cpu.seg.DS,
			cpu.cr0,
			flagValue
		)
		return isPassed, result
	end)

	if cpuSnapshot then
		cpu.reg16 = deepCopy(cpuSnapshot.reg16)
		cpu.reg32 = deepCopy(cpuSnapshot.reg32)
		cpu.seg = deepCopy(cpuSnapshot.seg)
		cpu.ip = cpuSnapshot.ip
		cpu.eip = cpuSnapshot.eip
		cpu.flags = cpuSnapshot.flags
		cpu.halted = cpuSnapshot.halted
		cpu.gdtr = deepCopy(cpuSnapshot.gdtr)
		cpu.idtr = deepCopy(cpuSnapshot.idtr)
		cpu.cr0 = cpuSnapshot.cr0
		cpu.protectedMode = cpuSnapshot.protectedMode
		cpu.segCache = deepCopy(cpuSnapshot.segCache)
		cpu._lastError = cpuSnapshot.lastError
		cpu._lastStep = deepCopy(cpuSnapshot.lastStep)
		cpu.stats = deepCopy(cpuSnapshot.stats)
	end
	writeRegion(machine.ram, origin, previousBytes)

	if not ok then
		return false, tostring(passed)
	end
	return passed, detail
end

return ProtectedModeSelfTest
