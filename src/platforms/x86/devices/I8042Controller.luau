local I8042Controller = {}
I8042Controller.__index = I8042Controller

local KBD_ACK = 0xFA
local KBD_SELF_TEST_PASSED = 0xAA

local STATUS_OUTPUT_FULL = 0x01
local STATUS_INPUT_FULL = 0x02
local STATUS_SYSTEM = 0x04
local STATUS_COMMAND = 0x08

local COMMAND_IRQ1_ENABLE = 0x01
local COMMAND_SYSTEM_FLAG = 0x04
local COMMAND_DISABLE_KEYBOARD = 0x10

local OUTPUT_BUFFER_LIMIT = 64
local ASCII_BUFFER_LIMIT = 128

local OUTPUT_PORT_A20_ENABLED = 0x02
local OUTPUT_PORT_KEYBOARD_ENABLED = 0x10

local SCAN_MAKE = {
	A = 0x1E,
	B = 0x30,
	C = 0x2E,
	D = 0x20,
	E = 0x12,
	F = 0x21,
	G = 0x22,
	H = 0x23,
	I = 0x17,
	J = 0x24,
	K = 0x25,
	L = 0x26,
	M = 0x32,
	N = 0x31,
	O = 0x18,
	P = 0x19,
	Q = 0x10,
	R = 0x13,
	S = 0x1F,
	T = 0x14,
	U = 0x16,
	V = 0x2F,
	W = 0x11,
	X = 0x2D,
	Y = 0x15,
	Z = 0x2C,
	Zero = 0x0B,
	One = 0x02,
	Two = 0x03,
	Three = 0x04,
	Four = 0x05,
	Five = 0x06,
	Six = 0x07,
	Seven = 0x08,
	Eight = 0x09,
	Nine = 0x0A,
	Return = 0x1C,
	Space = 0x39,
	Backspace = 0x0E,
	Tab = 0x0F,
	Escape = 0x01,
	LeftShift = 0x2A,
	RightShift = 0x36,
	LeftControl = 0x1D,
	RightControl = { 0xE0, 0x1D },
	LeftAlt = 0x38,
	RightAlt = { 0xE0, 0x38 },
	CapsLock = 0x3A,
	F1 = 0x3B,
	F2 = 0x3C,
	F3 = 0x3D,
	F4 = 0x3E,
	F5 = 0x3F,
	F6 = 0x40,
	F7 = 0x41,
	F8 = 0x42,
	F9 = 0x43,
	F10 = 0x44,
	F11 = 0x57,
	F12 = 0x58,
	Up = { 0xE0, 0x48 },
	Down = { 0xE0, 0x50 },
	Left = { 0xE0, 0x4B },
	Right = { 0xE0, 0x4D },
	Delete = { 0xE0, 0x53 },
	Insert = { 0xE0, 0x52 },
	Home = { 0xE0, 0x47 },
	End = { 0xE0, 0x4F },
	PageUp = { 0xE0, 0x49 },
	PageDown = { 0xE0, 0x51 },
	Minus = 0x0C,
	Equals = 0x0D,
	LeftBracket = 0x1A,
	RightBracket = 0x1B,
	Semicolon = 0x27,
	Quote = 0x28,
	Backquote = 0x29,
	BackSlash = 0x2B,
	Comma = 0x33,
	Period = 0x34,
	Slash = 0x35,
}

local SC_TO_ASCII_LOWER = {
	[0x02] = "1",
	[0x03] = "2",
	[0x04] = "3",
	[0x05] = "4",
	[0x06] = "5",
	[0x07] = "6",
	[0x08] = "7",
	[0x09] = "8",
	[0x0A] = "9",
	[0x0B] = "0",
	[0x0C] = "-",
	[0x0D] = "=",
	[0x0E] = "\b",
	[0x0F] = "\t",
	[0x10] = "q",
	[0x11] = "w",
	[0x12] = "e",
	[0x13] = "r",
	[0x14] = "t",
	[0x15] = "y",
	[0x16] = "u",
	[0x17] = "i",
	[0x18] = "o",
	[0x19] = "p",
	[0x1A] = "[",
	[0x1B] = "]",
	[0x1C] = "\n",
	[0x1E] = "a",
	[0x1F] = "s",
	[0x20] = "d",
	[0x21] = "f",
	[0x22] = "g",
	[0x23] = "h",
	[0x24] = "j",
	[0x25] = "k",
	[0x26] = "l",
	[0x27] = ";",
	[0x28] = "'",
	[0x29] = "`",
	[0x2B] = "\\",
	[0x2C] = "z",
	[0x2D] = "x",
	[0x2E] = "c",
	[0x2F] = "v",
	[0x30] = "b",
	[0x31] = "n",
	[0x32] = "m",
	[0x33] = ",",
	[0x34] = ".",
	[0x35] = "/",
	[0x39] = " ",
}

local SC_TO_ASCII_UPPER = {
	[0x02] = "!",
	[0x03] = "@",
	[0x04] = "#",
	[0x05] = "$",
	[0x06] = "%",
	[0x07] = "^",
	[0x08] = "&",
	[0x09] = "*",
	[0x0A] = "(",
	[0x0B] = ")",
	[0x0C] = "_",
	[0x0D] = "+",
	[0x0E] = "\b",
	[0x0F] = "\t",
	[0x10] = "Q",
	[0x11] = "W",
	[0x12] = "E",
	[0x13] = "R",
	[0x14] = "T",
	[0x15] = "Y",
	[0x16] = "U",
	[0x17] = "I",
	[0x18] = "O",
	[0x19] = "P",
	[0x1A] = "{",
	[0x1B] = "}",
	[0x1C] = "\n",
	[0x1E] = "A",
	[0x1F] = "S",
	[0x20] = "D",
	[0x21] = "F",
	[0x22] = "G",
	[0x23] = "H",
	[0x24] = "J",
	[0x25] = "K",
	[0x26] = "L",
	[0x27] = ":",
	[0x28] = '"',
	[0x29] = "~",
	[0x2B] = "|",
	[0x2C] = "Z",
	[0x2D] = "X",
	[0x2E] = "C",
	[0x2F] = "V",
	[0x30] = "B",
	[0x31] = "N",
	[0x32] = "M",
	[0x33] = "<",
	[0x34] = ">",
	[0x35] = "?",
	[0x39] = " ",
}

local function cloneSequence(entry)
	if type(entry) == "table" then
		return table.clone(entry)
	end
	return { entry }
end

function I8042Controller.new(config, bus)
	local self = setmetatable({}, I8042Controller)
	self.config = config
	self.bus = bus
	self._buffer = {}
	self._ascii = {}
	self._shift = false
	self._ctrl = false
	self._alt = false
	self._capsLock = false
	self._enabled = true
	self._scanningEnabled = true
	self._controllerCommandByte = bit32.bor(COMMAND_IRQ1_ENABLE, COMMAND_SYSTEM_FLAG)
	self._pendingControllerData = nil
	self._pendingI8042ControllerData = nil
	self._status = STATUS_SYSTEM
	self._outputPort = bit32.bor(OUTPUT_PORT_A20_ENABLED, OUTPUT_PORT_KEYBOARD_ENABLED)
	self._pendingOutputPortWrite = nil
	self.stats = { keyPresses = 0, bufferOverruns = 0 }

	bus:registerPort(config.PORT.KBD_DATA, function()
		return self:_readData()
	end, function(v)
		self:_writeData(v)
	end, "KBD Data")
	bus:registerPort(config.PORT.KBD_STATUS, function()
		return self:_readStatus()
	end, function(v)
		self:_writeCtrl(v)
	end, "KBD Status/Ctrl")
	return self
end

function I8042Controller:_setInputFull(enabled)
	if enabled then
		self._status = bit32.bor(self._status, STATUS_INPUT_FULL)
	else
		self._status = bit32.band(self._status, bit32.bnot(STATUS_INPUT_FULL))
	end
end

function I8042Controller:_setOutputPort(value)
	self._outputPort = bit32.band(tonumber(value) or 0, 0xFF)
	self._scanningEnabled = bit32.band(self._outputPort, OUTPUT_PORT_KEYBOARD_ENABLED) ~= 0
	if self.bus and self.bus.setA20Enabled then
		self.bus:setA20Enabled(bit32.band(self._outputPort, OUTPUT_PORT_A20_ENABLED) ~= 0)
	end
end

function I8042Controller:_syncStatus()
	if #self._buffer > 0 then
		self._status = bit32.bor(self._status, STATUS_OUTPUT_FULL)
	else
		self._status = bit32.band(self._status, bit32.bnot(STATUS_OUTPUT_FULL))
	end

	local pendingInput = self._pendingControllerData ~= nil or self._pendingOutputPortWrite ~= nil
	self:_setInputFull(pendingInput)
end

function I8042Controller:_raiseIRQ()
	if bit32.band(self._controllerCommandByte, COMMAND_IRQ1_ENABLE) ~= 0 and self._enabled then
		self.bus:raiseIRQ(self.config.IRQ.KEYBOARD, { source = "keyboard", status = self._status })
	end
end

function I8042Controller:_pushOutputByte(value, raiseIRQ)
	if #self._buffer >= OUTPUT_BUFFER_LIMIT then
		self.stats.bufferOverruns = self.stats.bufferOverruns + 1
		return
	end
	self._buffer[#self._buffer + 1] = bit32.band(tonumber(value) or 0, 0xFF)
	self:_syncStatus()
	if raiseIRQ ~= false then
		self:_raiseIRQ()
	end
end

function I8042Controller:_clearOutputStatus()
	self:_syncStatus()
end

function I8042Controller:_translateASCII(scanCode)
	local lower = SC_TO_ASCII_LOWER[scanCode]
	local upper = SC_TO_ASCII_UPPER[scanCode]
	local ascii
	if lower and upper then
		local isLetter = lower:match("^[a-z]$") ~= nil
		if isLetter then
			local useUpper = (self._shift and not self._capsLock) or (self._capsLock and not self._shift)
			ascii = useUpper and upper or lower
		else
			ascii = self._shift and upper or lower
		end
	else
		ascii = lower or upper
	end

	if self._ctrl and ascii and #ascii == 1 then
		local upperAscii = string.upper(ascii)
		local byteValue = string.byte(upperAscii)
		local controlCode = byteValue - 64
		if controlCode > 0 and controlCode < 32 then
			ascii = string.char(controlCode)
		end
	end

	if ascii and #self._ascii < ASCII_BUFFER_LIMIT then
		self._ascii[#self._ascii + 1] = ascii
	end
end

function I8042Controller:_queueScanSequence(sequence, isBreak)
	local codes = cloneSequence(sequence)
	if isBreak then
		codes[#codes] = bit32.bor(codes[#codes], 0x80)
	end
	for _, code in ipairs(codes) do
		self:_pushOutputByte(code)
	end
end

function I8042Controller:_setModifierState(keyCode, isDown)
	if keyCode == "LeftShift" or keyCode == "RightShift" then
		self._shift = isDown
	elseif keyCode == "LeftControl" or keyCode == "RightControl" then
		self._ctrl = isDown
	elseif keyCode == "LeftAlt" or keyCode == "RightAlt" then
		self._alt = isDown
	elseif keyCode == "CapsLock" and isDown then
		self._capsLock = not self._capsLock
	end
end

function I8042Controller:keyDown(key)
	if not self._scanningEnabled then
		return
	end

	self:_setModifierState(key, true)

	local sequence = SCAN_MAKE[key]
	if not sequence then
		return
	end

	self.stats.keyPresses = self.stats.keyPresses + 1
	self:_queueScanSequence(sequence, false)

	if type(sequence) ~= "table" then
		self:_translateASCII(sequence)
	end
end

function I8042Controller:keyUp(key)
	if not self._scanningEnabled then
		return
	end

	self:_setModifierState(key, false)

	local sequence = SCAN_MAKE[key]
	if sequence then
		self:_queueScanSequence(sequence, true)
	end
end

function I8042Controller:_readData()
	local value = table.remove(self._buffer, 1) or 0
	self:_clearOutputStatus()
	return value
end

function I8042Controller:_readStatus()
	return self._status
end

function I8042Controller:_resetBuffers()
	self._buffer = {}
	self._ascii = {}
end

function I8042Controller:_writeI8042ControllerCommand(value)
	local v = bit32.band(tonumber(value) or 0, 0xFF)
	if self._pendingI8042ControllerData == "led" then
		self._pendingI8042ControllerData = nil
		self:_pushOutputByte(KBD_ACK, false)
		return
	end

	if self._pendingOutputPortWrite ~= nil then
		self:_setOutputPort(v)
		self._pendingOutputPortWrite = nil
		self:_syncStatus()
		return
	end

	if v == 0xED then
		self._pendingI8042ControllerData = "led"
		self:_pushOutputByte(KBD_ACK, false)
	elseif v == 0xF2 then
		self:_pushOutputByte(KBD_ACK, false)
		self:_pushOutputByte(0xAB, false)
		self:_pushOutputByte(0x83, false)
	elseif v == 0xF4 then
		self._scanningEnabled = true
		self:_pushOutputByte(KBD_ACK, false)
	elseif v == 0xF5 then
		self._scanningEnabled = false
		self:_pushOutputByte(KBD_ACK, false)
	elseif v == 0xFF then
		self:_resetBuffers()
		self._scanningEnabled = true
		self:_pushOutputByte(KBD_ACK, false)
		self:_pushOutputByte(KBD_SELF_TEST_PASSED, false)
	elseif v == 0xD0 then
		self:_pushOutputByte(self._outputPort, false)
	elseif v == 0xD1 then
		self._pendingOutputPortWrite = true
		self:_setInputFull(true)
	else
		self:_pushOutputByte(KBD_ACK, false)
	end
end

function I8042Controller:_writeData(value)
	local v = bit32.band(tonumber(value) or 0, 0xFF)
	if self._pendingControllerData == "command-byte" then
		self._controllerCommandByte = v
		self._scanningEnabled = bit32.band(self._controllerCommandByte, COMMAND_DISABLE_KEYBOARD) == 0
		self._pendingControllerData = nil
		self:_syncStatus()
		return
	end

	if self._pendingOutputPortWrite then
		self._pendingOutputPortWrite = nil
		self:_setOutputPort(v)
		self:_syncStatus()
		return
	end

	self:_writeI8042ControllerCommand(v)
end

function I8042Controller:_writeCtrl(value)
	local v = bit32.band(tonumber(value) or 0, 0xFF)
	self._status = bit32.bor(self._status, STATUS_COMMAND)
	if v == 0x20 then
		self:_pushOutputByte(self._controllerCommandByte, false)
	elseif v == 0x60 then
		self._pendingControllerData = "command-byte"
		self:_setInputFull(true)
	elseif v == 0xAA then
		self._status = bit32.bor(self._status, STATUS_SYSTEM)
		self:_pushOutputByte(0x55, false)
	elseif v == 0xAB or v == 0xFE then
		self:_pushOutputByte(0x00, false)
	elseif v == 0xAD then
		self._scanningEnabled = false
		self._controllerCommandByte = bit32.bor(self._controllerCommandByte, COMMAND_DISABLE_KEYBOARD)
		self._outputPort = bit32.band(self._outputPort, bit32.bnot(OUTPUT_PORT_KEYBOARD_ENABLED))
	elseif v == 0xAE then
		self._scanningEnabled = true
		self._controllerCommandByte = bit32.band(self._controllerCommandByte, bit32.bnot(COMMAND_DISABLE_KEYBOARD))
		self._outputPort = bit32.bor(self._outputPort, OUTPUT_PORT_KEYBOARD_ENABLED)
	end
	self:_syncStatus()
	self._status = bit32.band(self._status, bit32.bnot(STATUS_COMMAND))
end

function I8042Controller:readChar()
	return table.remove(self._ascii, 1)
end

function I8042Controller:peekChar()
	return self._ascii[1]
end

function I8042Controller:pollLine(currentLine, echo, gpu)
	local ch = self:readChar()
	if not ch then
		return nil
	end

	if ch == "\n" or ch == "\r" then
		local line = table.concat(currentLine)
		for index = #currentLine, 1, -1 do
			currentLine[index] = nil
		end
		if echo and gpu and gpu.biosTeletype then
			gpu:biosTeletype(10)
		end
		return line
	end

	if ch == "\b" then
		if #currentLine > 0 then
			table.remove(currentLine)
			if echo and gpu and gpu.biosTeletype then
				gpu:biosTeletype(8)
			end
		end
	else
		table.insert(currentLine, ch)
		if echo and gpu and gpu.biosTeletype then
			gpu:biosTeletype(string.byte(ch))
		end
	end

	return nil
end

function I8042Controller:getStats()
	return self.stats
end

return I8042Controller
