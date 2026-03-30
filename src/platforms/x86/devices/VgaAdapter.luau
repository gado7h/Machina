-- VgaAdapter module

local VgaAdapter = {}
VgaAdapter.__index = VgaAdapter

-- CGA 16-color palette (packed ARGB as Lua integer)
local PALETTE = {
	[0] = 0xFF000000, -- black
	[1] = 0xFF0000AA, -- blue
	[2] = 0xFF00AA00, -- green
	[3] = 0xFF00AAAA, -- cyan
	[4] = 0xFFAA0000, -- red
	[5] = 0xFFAA00AA, -- magenta
	[6] = 0xFFAA5500, -- brown
	[7] = 0xFFAAAAAA, -- light gray
	[8] = 0xFF555555, -- dark gray
	[9] = 0xFF5555FF, -- bright blue
	[10] = 0xFF55FF55, -- bright green
	[11] = 0xFF55FFFF, -- bright cyan
	[12] = 0xFFFF5555, -- bright red
	[13] = 0xFFFF55FF, -- bright magenta
	[14] = 0xFFFFFF55, -- yellow
	[15] = 0xFFFFFFFF, -- white
}

-- 4Ã—8 bitmap font (ASCII 32-126).
-- Each glyph is 8 bytes; each byte is one scanline with bits 3..0 = columns 0..3.
local function F(...)
	return { ... }
end
local _GLYPHS = {
	[32] = F(0, 0, 0, 0, 0, 0, 0, 0), -- space
	[33] = F(4, 4, 4, 4, 0, 4, 0, 0), -- !
	[34] = F(10, 10, 0, 0, 0, 0, 0, 0), -- "
	[35] = F(10, 10, 15, 10, 15, 10, 10, 0), -- #
	[36] = F(4, 7, 8, 6, 1, 14, 4, 0), -- $
	[37] = F(9, 1, 2, 4, 8, 9, 0, 0), -- %
	[38] = F(4, 10, 10, 4, 11, 9, 6, 0), -- &
	[39] = F(4, 4, 0, 0, 0, 0, 0, 0), -- '
	[40] = F(2, 4, 8, 8, 8, 4, 2, 0), -- (
	[41] = F(8, 4, 2, 2, 2, 4, 8, 0), -- )
	[42] = F(0, 4, 14, 4, 14, 4, 0, 0), -- *
	[43] = F(0, 4, 4, 15, 4, 4, 0, 0), -- +
	[44] = F(0, 0, 0, 0, 4, 4, 8, 0), -- ,
	[45] = F(0, 0, 0, 15, 0, 0, 0, 0), -- -
	[46] = F(0, 0, 0, 0, 0, 6, 6, 0), -- .
	[47] = F(1, 1, 2, 4, 8, 8, 0, 0), -- /
	[48] = F(6, 9, 11, 13, 9, 6, 0, 0), -- 0
	[49] = F(4, 6, 4, 4, 4, 14, 0, 0), -- 1
	[50] = F(6, 9, 1, 2, 4, 15, 0, 0), -- 2
	[51] = F(6, 9, 2, 1, 9, 6, 0, 0), -- 3
	[52] = F(2, 6, 10, 15, 2, 2, 0, 0), -- 4
	[53] = F(15, 8, 14, 1, 9, 6, 0, 0), -- 5
	[54] = F(3, 4, 14, 9, 9, 6, 0, 0), -- 6
	[55] = F(15, 1, 2, 4, 4, 4, 0, 0), -- 7
	[56] = F(6, 9, 6, 9, 9, 6, 0, 0), -- 8
	[57] = F(6, 9, 7, 1, 2, 12, 0, 0), -- 9
	[58] = F(0, 6, 6, 0, 6, 6, 0, 0), -- :
	[59] = F(0, 6, 6, 0, 6, 6, 4, 0), -- ;
	[60] = F(2, 4, 8, 4, 2, 0, 0, 0), -- <
	[61] = F(0, 15, 0, 15, 0, 0, 0, 0), -- =
	[62] = F(8, 4, 2, 4, 8, 0, 0, 0), -- >
	[63] = F(6, 9, 1, 2, 0, 2, 0, 0), -- ?
	[64] = F(6, 9, 11, 13, 8, 6, 0, 0), -- @
	[65] = F(6, 9, 15, 9, 9, 9, 0, 0), -- A
	[66] = F(14, 9, 14, 9, 9, 14, 0, 0), -- B
	[67] = F(6, 9, 8, 8, 9, 6, 0, 0), -- C
	[68] = F(14, 9, 9, 9, 9, 14, 0, 0), -- D
	[69] = F(15, 8, 14, 8, 8, 15, 0, 0), -- E
	[70] = F(15, 8, 14, 8, 8, 8, 0, 0), -- F
	[71] = F(6, 9, 8, 11, 9, 7, 0, 0), -- G
	[72] = F(9, 9, 15, 9, 9, 9, 0, 0), -- H
	[73] = F(14, 4, 4, 4, 4, 14, 0, 0), -- I
	[74] = F(7, 2, 2, 2, 10, 4, 0, 0), -- J
	[75] = F(9, 10, 12, 10, 9, 9, 0, 0), -- K
	[76] = F(8, 8, 8, 8, 8, 15, 0, 0), -- L
	[77] = F(9, 15, 15, 9, 9, 9, 0, 0), -- M
	[78] = F(9, 13, 11, 9, 9, 9, 0, 0), -- N
	[79] = F(6, 9, 9, 9, 9, 6, 0, 0), -- O
	[80] = F(14, 9, 14, 8, 8, 8, 0, 0), -- P
	[81] = F(6, 9, 9, 11, 9, 7, 0, 0), -- Q
	[82] = F(14, 9, 14, 10, 9, 9, 0, 0), -- R
	[83] = F(7, 8, 6, 1, 9, 6, 0, 0), -- S
	[84] = F(15, 4, 4, 4, 4, 4, 0, 0), -- T
	[85] = F(9, 9, 9, 9, 9, 6, 0, 0), -- U
	[86] = F(9, 9, 9, 9, 6, 4, 0, 0), -- V
	[87] = F(9, 9, 9, 15, 15, 9, 0, 0), -- W
	[88] = F(9, 9, 6, 6, 9, 9, 0, 0), -- X
	[89] = F(9, 9, 6, 4, 4, 4, 0, 0), -- Y
	[90] = F(15, 1, 2, 4, 8, 15, 0, 0), -- Z
	[91] = F(6, 4, 4, 4, 4, 6, 0, 0), -- [
	[92] = F(8, 8, 4, 2, 1, 1, 0, 0), -- backslash
	[93] = F(6, 2, 2, 2, 2, 6, 0, 0), -- ]
	[94] = F(4, 10, 0, 0, 0, 0, 0, 0), -- ^
	[95] = F(0, 0, 0, 0, 0, 0, 15, 0), -- _
	[96] = F(8, 4, 0, 0, 0, 0, 0, 0), -- `
	[97] = F(0, 0, 6, 1, 7, 7, 0, 0), -- a
	[98] = F(8, 8, 14, 9, 9, 14, 0, 0), -- b
	[99] = F(0, 0, 6, 8, 8, 6, 0, 0), -- c
	[100] = F(1, 1, 7, 9, 9, 7, 0, 0), -- d
	[101] = F(0, 0, 6, 15, 8, 6, 0, 0), -- e
	[102] = F(3, 4, 14, 4, 4, 4, 0, 0), -- f
	[103] = F(0, 0, 7, 9, 7, 1, 6, 0), -- g
	[104] = F(8, 8, 14, 9, 9, 9, 0, 0), -- h
	[105] = F(4, 0, 4, 4, 4, 6, 0, 0), -- i
	[106] = F(2, 0, 2, 2, 10, 4, 0, 0), -- j
	[107] = F(8, 8, 9, 14, 9, 9, 0, 0), -- k
	[108] = F(6, 4, 4, 4, 4, 6, 0, 0), -- l
	[109] = F(0, 0, 15, 15, 9, 9, 0, 0), -- m
	[110] = F(0, 0, 14, 9, 9, 9, 0, 0), -- n
	[111] = F(0, 0, 6, 9, 9, 6, 0, 0), -- o
	[112] = F(0, 0, 14, 9, 14, 8, 8, 0), -- p
	[113] = F(0, 0, 7, 9, 7, 1, 1, 0), -- q
	[114] = F(0, 0, 11, 12, 8, 8, 0, 0), -- r
	[115] = F(0, 0, 6, 4, 2, 14, 0, 0), -- s
	[116] = F(4, 4, 14, 4, 4, 3, 0, 0), -- t
	[117] = F(0, 0, 9, 9, 9, 7, 0, 0), -- u
	[118] = F(0, 0, 9, 9, 6, 4, 0, 0), -- v
	[119] = F(0, 0, 9, 15, 15, 6, 0, 0), -- w
	[120] = F(0, 0, 9, 6, 6, 9, 0, 0), -- x
	[121] = F(0, 0, 9, 7, 1, 6, 0, 0), -- y
	[122] = F(0, 0, 15, 2, 4, 15, 0, 0), -- z
	[123] = F(3, 4, 4, 8, 4, 4, 3, 0), -- {
	[124] = F(4, 4, 4, 4, 4, 4, 0, 0), -- |
	[125] = F(12, 2, 2, 1, 2, 2, 12, 0), -- }
	[126] = F(0, 0, 5, 10, 0, 0, 0, 0), -- ~
}
local FONT = table.clone(_GLYPHS)
local fontByte
local isTextState
local isChain4State

local GLYPH_DEFAULT = F(15, 9, 9, 9, 9, 15, 0, 0)
local function getGlyph(ch)
	return FONT[ch] or GLYPH_DEFAULT
end

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function unpackARGB(c)
	local a = math.floor(c / 16777216) % 256
	local r = math.floor(c / 65536) % 256
	local g = math.floor(c / 256) % 256
	local b = c % 256
	return a, r, g, b
end

local function packARGB(a, r, g, b)
	return ((a % 256) * 16777216) + ((r % 256) * 65536) + ((g % 256) * 256) + (b % 256)
end

local function scale6To8(value)
	return math.floor(((tonumber(value) or 0) % 64) * 255 / 63 + 0.5)
end

local function defaultDacEntry(index)
	local egaColor = PALETTE[index]
	if egaColor ~= nil then
		local _, r, g, b = unpackARGB(egaColor)
		return {
			r = math.floor(r * 63 / 255 + 0.5),
			g = math.floor(g * 63 / 255 + 0.5),
			b = math.floor(b * 63 / 255 + 0.5),
		}
	end

	local gray = math.floor(((tonumber(index) or 0) % 64) * 63 / 63 + 0.5)
	return { r = gray, g = gray, b = gray }
end

local function clearCells(cells, count, attr)
	for index = 0, count - 1 do
		cells[index] = { char = 32, attr = attr or 0x07 }
	end
end

local function blendARGB(bg, fg, alpha)
	if alpha <= 0 then
		return bg
	elseif alpha >= 255 then
		return fg
	end
	local _, br, bgc, bb = unpackARGB(bg)
	local _, fr, fgc, fb = unpackARGB(fg)
	local t = alpha / 255
	return packARGB(
		255,
		math.floor(lerp(br, fr, t) + 0.5),
		math.floor(lerp(bgc, fgc, t) + 0.5),
		math.floor(lerp(bb, fb, t) + 0.5)
	)
end

local function glyphBit(glyph, gx, gy)
	if gx < 0 or gx > 3 or gy < 0 or gy > 7 then
		return 0
	end
	local bits = glyph[gy + 1] or 0
	local mask = 2 ^ (3 - gx)
	return (bits % (mask * 2)) >= mask and 1 or 0
end

local function sampleGlyphSmooth(glyph, u, v)
	local x = clamp(u, 0, 3)
	local y = clamp(v, 0, 7)
	local x0 = math.floor(x)
	local y0 = math.floor(y)
	local x1 = math.min(3, x0 + 1)
	local y1 = math.min(7, y0 + 1)
	local tx = x - x0
	local ty = y - y0

	local a = glyphBit(glyph, x0, y0)
	local b = glyphBit(glyph, x1, y0)
	local c = glyphBit(glyph, x0, y1)
	local d = glyphBit(glyph, x1, y1)

	local top = lerp(a, b, tx)
	local bot = lerp(c, d, tx)
	return lerp(top, bot, ty)
end

function VgaAdapter.new(config)
	local self = setmetatable({}, VgaAdapter)
	self.config = config
	self.W = config.SCREEN_W
	self.H = config.SCREEN_H
	self.CW = config.CHAR_W
	self.CH = config.CHAR_H

	self.GW = config.GLYPH_W or self.CW
	self.GH = config.GLYPH_H or self.CH
	self.PX = config.PAD_X or 0
	self.PY = config.PAD_Y or 0

	self.mode = "TEXT"
	self.fontSmoothing = config.FONT_SMOOTHING == true
	self.guiOps = {}
	self._biosMode = 0x03

	self._nextFrameTime = 0
	self._frameInterval = 1 / math.max(1, config.DISPLAY_REFRESH_HZ or 60)

	local x86 = config.X86 or {}
	self._apertureBase = x86.VIDEO_BASE or config.VRAM_BASE or 0xA0000
	self._apertureSize = x86.VIDEO_SIZE or config.VRAM_SIZE or 0x20000
	self._textBaseOffset = ((x86.TEXT_BUFFER_BASE or 0xB8000) - self._apertureBase) % self._apertureSize
	self._textByteCount = x86.TEXT_BUFFER_SIZE or 0x8000
	self._textCellCount = math.max(config.TEXT_COLS * config.TEXT_ROWS, math.floor(self._textByteCount / 2))
	self._planeSize = 0x10000
	self._crtcIndex = 0
	self._crtc = {
		[0x0A] = 0x06,
		[0x0B] = 0x07,
		[0x0C] = 0x00,
		[0x0D] = 0x00,
		[0x0E] = 0x00,
		[0x0F] = 0x00,
	}
	self._miscOutput = 0x67
	self._status1 = 0x00
	self._featureControl = 0x00
	self._attrFlipFlop = false
	self._attrIndex = 0
	self._seqIndex = 0
	self._gcIndex = 0
	self._dacMask = 0xFF
	self._dacReadIndex = 0
	self._dacWriteIndex = 0
	self._dacReadComponent = 0
	self._dacWriteComponent = 0

	self._sequencer = {}
	for index = 0, 4 do
		self._sequencer[index] = 0
	end
	self._graphics = {}
	for index = 0, 8 do
		self._graphics[index] = 0
	end
	self._attribute = {}
	for index = 0, 0x14 do
		self._attribute[index] = 0
	end
	for index = 0, 0x0F do
		self._attribute[index] = index
	end
	self._dac = {}
	for index = 0, 255 do
		self._dac[index] = defaultDacEntry(index)
	end

	-- Text buffer: flat array [0 .. textCellCount-1], each entry {char, attr}
	self._textBuf = {}
	clearCells(self._textBuf, self._textCellCount, 0x07)
	self._cursorRow = 0
	self._cursorCol = 0
	self._cursorVisible = true
	self._lastCursor = { col = 0, row = 0 }

	self._dirtyCells = {}
	self._dirtyCellList = {}

	-- Pixel framebuffer: flat array [0 .. W*H-1] of packed ARGB integers
	self._framebuf = {}
	for i = 0, self.W * self.H - 1 do
		self._framebuf[i] = 0xFF000000
	end

	-- Native buffer for WritePixelsBuffer â€” allocated once, reused every frame.
	-- Layout: RGBA u8 bytes, row-major. Size = W * H * 4 bytes.
	self._pixelBuffer = buffer.create(self.W * self.H * 4)
	self._dirtyPixelRect = {
		x0 = 0,
		y0 = 0,
		x1 = self.W - 1,
		y1 = self.H - 1,
	}

	-- VRAM (bus-mapped region, written by CPU via memWrite)
	self._vram = {}
	self._planes = {
		[0] = {},
		[1] = {},
		[2] = {},
		[3] = {},
	}
	for plane = 0, 3 do
		for index = 0, self._planeSize - 1 do
			self._planes[plane][index] = 0
		end
	end
	self._hostOverlay = {
		active = false,
		cells = {},
		cursorCol = 0,
		cursorRow = 0,
		defaultAttr = 0x0C,
	}
	clearCells(self._hostOverlay.cells, config.TEXT_COLS * config.TEXT_ROWS, self._hostOverlay.defaultAttr)
	self._latch = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
	self._fontHeight = 16
	self._timing = {
		elapsed = 0,
		frameTime = 1 / 70,
		lineTime = 1 / (70 * 449),
		currentLine = 0,
		currentColumn = 0,
		inDisplayEnable = true,
		inVerticalRetrace = false,
	}
	self._dirty = true

	self.stats = {
		flushes = 0,
		textWrites = 0,
		pixelWrites = 0,
		guiDrawCalls = 0,
		vramReads = 0,
		vramWrites = 0,
		registerWrites = 0,
		paletteWrites = 0,
		modeChanges = 0,
		hostWrites = 0,
	}

	self:biosSetVideoMode(0x03)
	self:clearHostOverlay()
	for code = 0, 255 do
		local glyph = getGlyph(code)
		local base = code * 32
		for row = 0, 15 do
			local sourceRow = glyph[math.floor(row / 2) + 1] or 0
			local bits = 0
			for col = 0, 3 do
				if bit32.band(sourceRow, bit32.lshift(1, 3 - col)) ~= 0 then
					bits = bit32.bor(bits, bit32.lshift(1, 7 - col * 2), bit32.lshift(1, 6 - col * 2))
				end
			end
			self._planes[2][base + row] = bits
		end
	end

	return self
end

local function markCellDirty(self, col, row)
	if col < 0 or col >= self.config.TEXT_COLS then
		return
	end
	if row < 0 or row >= self.config.TEXT_ROWS then
		return
	end
	local idx = row * self.config.TEXT_COLS + col
	if not self._dirtyCells[idx] then
		self._dirtyCells[idx] = true
		table.insert(self._dirtyCellList, idx)
	end
end

local function markAllCellsDirty(self)
	for row = 0, self.config.TEXT_ROWS - 1 do
		for col = 0, self.config.TEXT_COLS - 1 do
			markCellDirty(self, col, row)
		end
	end
end

local function clearDirtyCells(self)
	for _, idx in ipairs(self._dirtyCellList) do
		self._dirtyCells[idx] = nil
	end
	self._dirtyCellList = {}
end

local function markTextStateDirty(self)
	if self.mode == "TEXT" then
		markAllCellsDirty(self)
	end
end

local function markPixelRectDirty(self, x, y, w, h)
	if w <= 0 or h <= 0 then
		return
	end
	local x0 = math.max(0, math.floor(x))
	local y0 = math.max(0, math.floor(y))
	local x1 = math.min(self.W - 1, math.floor(x + w - 1))
	local y1 = math.min(self.H - 1, math.floor(y + h - 1))
	if x1 < x0 or y1 < y0 then
		return
	end

	local rect = self._dirtyPixelRect
	if rect == nil then
		self._dirtyPixelRect = {
			x0 = x0,
			y0 = y0,
			x1 = x1,
			y1 = y1,
		}
		return
	end

	rect.x0 = math.min(rect.x0, x0)
	rect.y0 = math.min(rect.y0, y0)
	rect.x1 = math.max(rect.x1, x1)
	rect.y1 = math.max(rect.y1, y1)
end

local function syncCellToVRAM(self, absoluteIdx)
	local cell = self._textBuf[absoluteIdx] or { char = 32, attr = 0x07 }
	local base = absoluteIdx * 2
	self._vram[base] = cell.char
	self._vram[base + 1] = cell.attr
end

local function textStartCell(self)
	local startAddress = ((self._crtc[0x0C] or 0) * 256) + (self._crtc[0x0D] or 0)
	return startAddress % math.max(1, self._textCellCount)
end

local function updateCursorRegisters(self)
	local cursorCell = (textStartCell(self) + (self._cursorRow * self.config.TEXT_COLS) + self._cursorCol)
		% math.max(1, self._textCellCount)
	self._crtc[0x0E] = math.floor(cursorCell / 256) % 256
	self._crtc[0x0F] = cursorCell % 256
end

local function applyCursorRegisters(self)
	local cursorCell = (((self._crtc[0x0E] or 0) * 256) + (self._crtc[0x0F] or 0)) % math.max(1, self._textCellCount)
	local visibleCell = (cursorCell - textStartCell(self)) % math.max(1, self._textCellCount)
	local screenCells = self.config.TEXT_COLS * self.config.TEXT_ROWS
	if visibleCell < screenCells then
		self._cursorRow = math.floor(visibleCell / self.config.TEXT_COLS)
		self._cursorCol = visibleCell % self.config.TEXT_COLS
	end
end

local function absoluteCellToVisible(self, absoluteCell)
	local startCell = textStartCell(self)
	local visibleCell = (absoluteCell - startCell) % math.max(1, self._textCellCount)
	if visibleCell < 0 or visibleCell >= (self.config.TEXT_COLS * self.config.TEXT_ROWS) then
		return nil
	end
	return visibleCell % self.config.TEXT_COLS, math.floor(visibleCell / self.config.TEXT_COLS)
end

function VgaAdapter:writeString(col, row, str, attr)
	for i = 1, #str do
		self:putChar(col + i - 1, row, string.byte(str, i), attr)
	end
end

function VgaAdapter:moveCursor(col, row)
	markCellDirty(self, self._cursorCol, self._cursorRow)
	self._cursorCol = math.max(0, math.min(col, self.config.TEXT_COLS - 1))
	self._cursorRow = math.max(0, math.min(row, self.config.TEXT_ROWS - 1))
	updateCursorRegisters(self)
	markCellDirty(self, self._cursorCol, self._cursorRow)
	self._dirty = true
end

function VgaAdapter:getCursor()
	return self._cursorCol, self._cursorRow
end

function VgaAdapter:_setPixelRaw(x, y, argb)
	if x < 0 or x >= self.W or y < 0 or y >= self.H then
		return
	end
	self._framebuf[y * self.W + x] = argb
end

--  Pixel API

function VgaAdapter:setPixel(x, y, argb)
	if x < 0 or x >= self.W or y < 0 or y >= self.H then
		return
	end
	self._framebuf[y * self.W + x] = argb
	self._dirty = true
	markPixelRectDirty(self, x, y, 1, 1)
	self.stats.pixelWrites = self.stats.pixelWrites + 1
end

function VgaAdapter:fillRect(x, y, w, h, argb)
	if w <= 0 or h <= 0 then
		return
	end
	local x0 = math.max(0, x)
	local y0 = math.max(0, y)
	local x1 = math.min(self.W - 1, x + w - 1)
	local y1 = math.min(self.H - 1, y + h - 1)
	if x1 < x0 or y1 < y0 then
		return
	end

	local written = 0
	for row = y0, y1 do
		local base = row * self.W
		for col = x0, x1 do
			self._framebuf[base + col] = argb
			written = written + 1
		end
	end
	self.stats.pixelWrites = self.stats.pixelWrites + written
	self._dirty = true
	markPixelRectDirty(self, x0, y0, x1 - x0 + 1, y1 - y0 + 1)
end

function VgaAdapter:drawLine(x0, y0, x1, y1, argb)
	x0, y0, x1, y1 = math.floor(x0), math.floor(y0), math.floor(x1), math.floor(y1)
	local minX = math.min(x0, x1)
	local minY = math.min(y0, y1)
	local maxX = math.max(x0, x1)
	local maxY = math.max(y0, y1)
	local dx = math.abs(x1 - x0)
	local dy = -math.abs(y1 - y0)
	local sx = (x0 < x1) and 1 or -1
	local sy = (y0 < y1) and 1 or -1
	local err = dx + dy
	local W = self.W
	local H = self.H
	local fb = self._framebuf
	local written = 0
	while true do
		if x0 >= 0 and x0 < W and y0 >= 0 and y0 < H then
			fb[y0 * W + x0] = argb
			written = written + 1
		end
		if x0 == x1 and y0 == y1 then
			break
		end
		local e2 = err * 2
		if e2 >= dy then
			err = err + dy
			x0 = x0 + sx
		end
		if e2 <= dx then
			err = err + dx
			y0 = y0 + sy
		end
	end
	if written > 0 then
		self.stats.pixelWrites = self.stats.pixelWrites + written
		self._dirty = true
		markPixelRectDirty(self, minX, minY, maxX - minX + 1, maxY - minY + 1)
	end
end

function VgaAdapter:drawRect(x, y, w, h, argb, filled)
	if w <= 0 or h <= 0 then
		return
	end
	if filled then
		self:fillRect(x, y, w, h, argb)
		return
	end
	if w == 1 or h == 1 then
		self:fillRect(x, y, w, h, argb)
		return
	end
	self:drawLine(x, y, x + w - 1, y, argb)
	self:drawLine(x, y + h - 1, x + w - 1, y + h - 1, argb)
	self:drawLine(x, y + 1, x, y + h - 2, argb)
	self:drawLine(x + w - 1, y + 1, x + w - 1, y + h - 2, argb)
end

function VgaAdapter:drawText(x, y, text, fgARGB, bgARGB)
	bgARGB = bgARGB or 0x00000000
	for i = 1, #text do
		self:drawChar(x + (i - 1) * self.CW, y, text:sub(i, i), fgARGB, bgARGB)
	end
	self.stats.guiDrawCalls = self.stats.guiDrawCalls + 1
end

function VgaAdapter:drawChar(x, y, ch, fgARGB, bgARGB)
	local code = (type(ch) == "string") and string.byte(ch, 1) or ch
	local glyph = getGlyph(code)
	local written = 0

	-- Clear full cell first so deletes / narrow glyphs do not leave artifacts
	for row = 0, self.CH - 1 do
		local py = y + row
		if py >= 0 and py < self.H then
			local base = py * self.W
			for col = 0, self.CW - 1 do
				local px = x + col
				if px >= 0 and px < self.W then
					self._framebuf[base + px] = bgARGB
					written = written + 1
				end
			end
		end
	end

	local drawW = math.max(1, self.GW)
	local drawH = math.max(1, self.GH)
	for row = 0, drawH - 1 do
		for col = 0, drawW - 1 do
			local px = x + self.PX + col
			local py = y + self.PY + row
			if
				px >= x
				and px < x + self.CW
				and py >= y
				and py < y + self.CH
				and px >= 0
				and px < self.W
				and py >= 0
				and py < self.H
			then
				local coverage
				if self.fontSmoothing then
					local denomW = math.max(1, drawW)
					local denomH = math.max(1, drawH)
					local u0 = ((col + 0.25) / denomW) * 4 - 0.5
					local v0 = ((row + 0.25) / denomH) * 8 - 0.5
					local u1 = ((col + 0.75) / denomW) * 4 - 0.5
					local v1 = ((row + 0.75) / denomH) * 8 - 0.5
					coverage = (
						sampleGlyphSmooth(glyph, u0, v0)
						+ sampleGlyphSmooth(glyph, u1, v0)
						+ sampleGlyphSmooth(glyph, u0, v1)
						+ sampleGlyphSmooth(glyph, u1, v1)
					) * 0.25
				else
					coverage = glyphBit(glyph, math.floor((col / drawW) * 4), math.floor((row / drawH) * 8))
				end
				if coverage > 0 then
					local idx = py * self.W + px
					self._framebuf[idx] = blendARGB(self._framebuf[idx] or bgARGB, fgARGB, math.floor(coverage * 255))
					written = written + 1
				end
			end
		end
	end
	self.stats.pixelWrites = self.stats.pixelWrites + written
	self._dirty = true
	markPixelRectDirty(self, x, y, self.CW, self.CH)
end

function VgaAdapter:blitRect(srcX, srcY, w, h, dstX, dstY)
	if w <= 0 or h <= 0 then
		return
	end

	local srcX0 = math.max(0, srcX)
	local srcY0 = math.max(0, srcY)
	local srcX1 = math.min(self.W - 1, srcX + w - 1)
	local srcY1 = math.min(self.H - 1, srcY + h - 1)
	if srcX1 < srcX0 or srcY1 < srcY0 then
		return
	end

	local copyW = srcX1 - srcX0 + 1
	local copyH = srcY1 - srcY0 + 1
	local fb = self._framebuf
	local W = self.W
	local scratch = table.create(copyW * copyH)
	local n = 1
	for row = 0, copyH - 1 do
		local base = (srcY0 + row) * W + srcX0
		for col = 0, copyW - 1 do
			scratch[n] = fb[base + col]
			n = n + 1
		end
	end

	n = 1
	local written = 0
	for row = 0, copyH - 1 do
		local py = dstY + row
		if py >= 0 and py < self.H then
			local base = py * W
			for col = 0, copyW - 1 do
				local px = dstX + col
				local c = scratch[n]
				if px >= 0 and px < self.W and c ~= nil then
					fb[base + px] = c
					written = written + 1
				end
				n = n + 1
			end
		else
			n = n + copyW
		end
	end

	if written > 0 then
		self.stats.pixelWrites = self.stats.pixelWrites + written
		self._dirty = true
		markPixelRectDirty(self, dstX, dstY, copyW, copyH)
	end
end

function VgaAdapter:moveWindow(srcX, srcY, w, h, dstX, dstY, clearARGB)
	self:blitRect(srcX, srcY, w, h, dstX, dstY)
	if clearARGB ~= nil then
		self:fillRect(srcX, srcY, w, h, clearARGB)
	end
end

function VgaAdapter:_packPixelBuffer()
	local fb = self._framebuf
	local pb = self._pixelBuffer
	local W = self.W

	local needed = W * self.H * 4
	if buffer.len(pb) ~= needed then
		pb = buffer.create(needed)
		self._pixelBuffer = pb
		self._dirtyPixelRect = {
			x0 = 0,
			y0 = 0,
			x1 = W - 1,
			y1 = self.H - 1,
		}
	end

	local rect = self._dirtyPixelRect
	if rect == nil then
		return pb
	end

	for y = rect.y0, rect.y1 do
		local rowBase = y * W
		for x = rect.x0, rect.x1 do
			local i = rowBase + x
			local argb = fb[i] or 0xFF000000
			local base = i * 4
			local a = math.floor(argb / 16777216) % 256
			local r = math.floor(argb / 65536) % 256
			local g = math.floor(argb / 256) % 256
			local b = argb % 256
			buffer.writeu8(pb, base, r)
			buffer.writeu8(pb, base + 1, g)
			buffer.writeu8(pb, base + 2, b)
			buffer.writeu8(pb, base + 3, a)
		end
	end

	self._dirtyPixelRect = nil
	return pb
end

function VgaAdapter:getFrame()
	if self._dirty then
		if isTextState(self) then
			if self._hostOverlay.active then
				self:_renderHardwareText()
				self:_renderHostOverlay()
			else
				self:_renderText()
			end
		elseif isChain4State(self) then
			self:_renderMode13()
			self:_renderHostOverlay()
		else
			self:_renderPlanar()
			self:_renderHostOverlay()
		end
	end

	return {
		width = self.W,
		height = self.H,
		buffer = self:_packPixelBuffer(),
	}
end

function VgaAdapter:_renderText()
	local cols = self.config.TEXT_COLS
	local startCell = textStartCell(self)
	local blinkEnabled = bit32.band(self._attribute[0x10] or 0, 0x08) ~= 0
	local cursorDisabled = bit32.band(self._crtc[0x0A] or 0, 0x20) ~= 0
	local cursorStart = bit32.band(self._crtc[0x0A] or 0, 0x1F)
	local cursorEnd = bit32.band(self._crtc[0x0B] or 0, 0x1F)

	if self._lastCursor.col ~= self._cursorCol or self._lastCursor.row ~= self._cursorRow then
		markCellDirty(self, self._lastCursor.col, self._lastCursor.row)
		markCellDirty(self, self._cursorCol, self._cursorRow)
	end

	for _, idx in ipairs(self._dirtyCellList) do
		local row = math.floor(idx / cols)
		local col = idx % cols
		local absoluteIdx = (startCell + idx) % math.max(1, self._textCellCount)
		local cell = self._textBuf[absoluteIdx] or { char = 32, attr = 0x07 }
		local attr = cell.attr or 0x07
		local fgIndex = bit32.band(attr, 0x0F)
		local bgIndex = bit32.band(bit32.rshift(attr, 4), 0x07)
		local suppressGlyph = false
		if bit32.band(attr, 0x80) ~= 0 then
			if blinkEnabled then
				suppressGlyph = not self._cursorVisible
			else
				bgIndex = bit32.bor(bgIndex, 0x08)
			end
		end

		local fg = self:_attributeColor(fgIndex)
		local bg = self:_attributeColor(bgIndex)
		local px0 = col * self.CW
		local py0 = row * self.CH
		local charCode = cell.char or 32
		for glyphRow = 0, self._fontHeight - 1 do
			local rowBits = fontByte(self, charCode, glyphRow)
			local py = py0 + glyphRow
			local base = py * self.W + px0
			for glyphCol = 0, 7 do
				local mask = bit32.lshift(1, 7 - glyphCol)
				local on = bit32.band(rowBits, mask) ~= 0
				self._framebuf[base + glyphCol] = (not suppressGlyph and on) and fg or bg
			end
		end

		local drawCursor = not cursorDisabled
			and self._cursorVisible
			and col == self._cursorCol
			and row == self._cursorRow
		if drawCursor then
			local y0 = py0 + math.min(self.CH - 1, cursorStart)
			local y1 = py0 + math.min(self.CH - 1, math.max(cursorStart, cursorEnd))
			for py = y0, y1 do
				local base = py * self.W + px0
				for glyphCol = 0, self.CW - 1 do
					self._framebuf[base + glyphCol] = fg
				end
			end
		end

		markPixelRectDirty(self, px0, py0, self.CW, self.CH)
	end
	clearDirtyCells(self)
	self._lastCursor.col = self._cursorCol
	self._lastCursor.row = self._cursorRow
end

local function resetAttributePalette(self)
	for index = 0, 0x0F do
		self._attribute[index] = index
	end
	self._attribute[0x10] = 0x08
	self._attribute[0x11] = 0x00
	self._attribute[0x12] = 0x0F
	self._attribute[0x13] = 0x08
	self._attribute[0x14] = 0x00
end

local function overflowBit(reg, bitIndex)
	return bit32.band(bit32.rshift(reg or 0, bitIndex), 0x01)
end

local function readVerticalField(self, lowReg, highBitMask, extraBitMask, adjust)
	local overflow = self._crtc[0x07] or 0
	local maxScan = self._crtc[0x09] or 0
	local value = self._crtc[lowReg] or 0
	if bit32.band(highBitMask, 0x100) ~= 0 and overflowBit(overflow, 0) ~= 0 then
		value = bit32.bor(value, 0x100)
	end
	if bit32.band(highBitMask, 0x200) ~= 0 and overflowBit(overflow, 5) ~= 0 then
		value = bit32.bor(value, 0x200)
	end
	if bit32.band(extraBitMask or 0, 0x200) ~= 0 and overflowBit(maxScan, 5) ~= 0 then
		value = bit32.bor(value, 0x200)
	end
	return value + (adjust or 0)
end

fontByte = function(self, charCode, row)
	local offset = ((tonumber(charCode) or 0) % 256) * 32 + ((tonumber(row) or 0) % 32)
	return self._planes[2][offset] or 0
end

local function updateTimingState(self)
	local charWidth = 8
	local clockSelect = bit32.band(bit32.rshift(self._miscOutput or 0, 2), 0x03)
	local dotClock = (clockSelect == 1 or clockSelect == 3) and 28322000 or 25175000
	local horizontalTotal = ((self._crtc[0x00] or 0) + 5)
	local horizontalDisplay = ((self._crtc[0x01] or 0) + 1)
	local verticalTotal = readVerticalField(self, 0x06, 0x300, 0x200, 2)
	local verticalDisplay = readVerticalField(self, 0x12, 0x300, 0, 1)
	local verticalRetraceStart = readVerticalField(self, 0x10, 0x300, 0, 0)
	local verticalRetraceEnd = (self._crtc[0x11] or 0) % 16

	horizontalTotal = math.max(1, horizontalTotal)
	horizontalDisplay = math.max(1, math.min(horizontalDisplay, horizontalTotal))
	verticalTotal = math.max(1, verticalTotal)
	verticalDisplay = math.max(1, math.min(verticalDisplay, verticalTotal))

	local lineTime = (horizontalTotal * charWidth) / dotClock
	local frameTime = lineTime * verticalTotal
	self._timing.lineTime = lineTime
	self._timing.frameTime = frameTime

	local elapsed = self._timing.elapsed % frameTime
	local currentLine = math.floor(elapsed / lineTime)
	local currentColumn = math.floor(((elapsed % lineTime) / lineTime) * horizontalTotal)
	local inVretrace = currentLine >= verticalRetraceStart
		and currentLine <= math.min(verticalTotal - 1, verticalRetraceStart + verticalRetraceEnd)
	local inDisplay = currentLine < verticalDisplay and currentColumn < horizontalDisplay

	self._timing.currentLine = currentLine
	self._timing.currentColumn = currentColumn
	self._timing.inVerticalRetrace = inVretrace
	self._timing.inDisplayEnable = inDisplay
end

local function decodeWindow(self, address)
	local mapSelect = bit32.rshift(bit32.band(self._graphics[0x06] or 0, 0x0C), 2)
	if mapSelect == 0 then
		if address < 0 or address >= 0x20000 then
			return nil
		end
		return address
	elseif mapSelect == 1 then
		if address < 0 or address >= 0x10000 then
			return nil
		end
		return address
	elseif mapSelect == 2 then
		if address < 0x10000 or address >= 0x18000 then
			return nil
		end
		return address - 0x10000
	end
	if address < 0x18000 or address >= 0x20000 then
		return nil
	end
	return address - 0x18000
end

isTextState = function(self)
	return bit32.band(self._attribute[0x10] or 0, 0x01) == 0 and bit32.band(self._graphics[0x06] or 0, 0x01) == 0
end

isChain4State = function(self)
	return bit32.band(self._sequencer[0x04] or 0, 0x04) ~= 0 and bit32.band(self._graphics[0x05] or 0, 0x40) ~= 0
end

local function loadLatches(self, planeOffset)
	local offset = (tonumber(planeOffset) or 0) % self._planeSize
	for plane = 0, 3 do
		self._latch[plane] = self._planes[plane][offset] or 0
	end
	return offset
end

local function rotateRight8(value, count)
	local shift = (tonumber(count) or 0) % 8
	local byteValue = (tonumber(value) or 0) % 256
	if shift == 0 then
		return byteValue
	end
	return bit32.band(bit32.bor(bit32.rshift(byteValue, shift), bit32.lshift(byteValue, 8 - shift)), 0xFF)
end

local function applyRasterOp(func, source, latch)
	if func == 1 then
		return bit32.band(source, latch)
	elseif func == 2 then
		return bit32.bor(source, latch)
	elseif func == 3 then
		return bit32.bxor(source, latch)
	end
	return source
end

local function fullByte(bitValue)
	return bitValue ~= 0 and 0xFF or 0x00
end

local function planarRead(self, apertureOffset)
	local offset = loadLatches(self, apertureOffset)
	local readMode = bit32.band(bit32.rshift(self._graphics[0x05] or 0, 3), 0x01)
	if readMode == 0 then
		local selectedPlane = bit32.band(self._graphics[0x04] or 0, 0x03)
		return self._planes[selectedPlane][offset] or 0
	end

	local colorCompare = self._graphics[0x02] or 0
	local colorDontCare = self._graphics[0x07] or 0x0F
	local result = 0
	for bitIndex = 0, 7 do
		local pixelColor = 0
		for plane = 0, 3 do
			local planeBit = bit32.band(bit32.rshift(self._latch[plane], 7 - bitIndex), 0x01)
			pixelColor = bit32.bor(pixelColor, bit32.lshift(planeBit, plane))
		end
		if bit32.band(pixelColor, colorDontCare) == bit32.band(colorCompare, colorDontCare) then
			result = bit32.bor(result, bit32.lshift(1, 7 - bitIndex))
		end
	end
	return result
end

local function planarWrite(self, apertureOffset, value)
	local offset = loadLatches(self, apertureOffset)
	local mapMask = self._sequencer[0x02] or 0x0F
	local writeMode = bit32.band(self._graphics[0x05] or 0, 0x03)
	local rotateCount = bit32.band(self._graphics[0x03] or 0, 0x07)
	local logicalOp = bit32.band(bit32.rshift(self._graphics[0x03] or 0, 3), 0x03)
	local bitMask = self._graphics[0x08] or 0xFF
	local setReset = self._graphics[0x00] or 0
	local enableSetReset = self._graphics[0x01] or 0
	local rotated = rotateRight8(value, rotateCount)

	for plane = 0, 3 do
		local planeMask = bit32.lshift(1, plane)
		if bit32.band(mapMask, planeMask) ~= 0 then
			local latch = self._latch[plane]
			local source = rotated
			local writeMask = bitMask

			if writeMode == 0 then
				if bit32.band(enableSetReset, planeMask) ~= 0 then
					source = fullByte(bit32.band(bit32.rshift(setReset, plane), 0x01))
				end
				source = applyRasterOp(logicalOp, source, latch)
			elseif writeMode == 1 then
				source = latch
				writeMask = 0xFF
			elseif writeMode == 2 then
				source = fullByte(bit32.band(bit32.rshift(value, plane), 0x01))
				source = applyRasterOp(logicalOp, source, latch)
			else
				source = fullByte(bit32.band(bit32.rshift(setReset, plane), 0x01))
				writeMask = bit32.band(rotated, bitMask)
				source = applyRasterOp(logicalOp, source, latch)
			end

			self._planes[plane][offset] =
				bit32.bor(bit32.band(source, writeMask), bit32.band(latch, bit32.band(bit32.bnot(writeMask), 0xFF)))
		end
	end
end

local function syncTextCellFromPlanes(self, cellIdx)
	local idx = cellIdx % math.max(1, self._textCellCount)
	self._textBuf[idx] = {
		char = self._planes[0][idx] or 32,
		attr = self._planes[1][idx] or 0x07,
	}
	syncCellToVRAM(self, idx)
	local visibleCol, visibleRow = absoluteCellToVisible(self, idx)
	if visibleCol ~= nil and visibleRow ~= nil then
		markCellDirty(self, visibleCol, visibleRow)
	end
end

local function setTextCell(self, cellIdx, ch, attr)
	local idx = cellIdx % math.max(1, self._textCellCount)
	self._planes[0][idx] = (tonumber(ch) or 32) % 256
	self._planes[1][idx] = (tonumber(attr) or 0x07) % 256
	syncTextCellFromPlanes(self, idx)
end

local function hostWriteChar(self, ch, attr)
	local overlay = self._hostOverlay
	local charValue = (type(ch) == "string" and string.byte(ch, 1)) or ((tonumber(ch) or 32) % 256)

	if charValue == 13 then
		overlay.cursorCol = 0
		return
	elseif charValue == 10 then
		overlay.cursorCol = 0
		overlay.cursorRow = overlay.cursorRow + 1
	elseif charValue == 8 then
		if overlay.cursorCol > 0 then
			overlay.cursorCol = overlay.cursorCol - 1
			local idx = overlay.cursorRow * self.config.TEXT_COLS + overlay.cursorCol
			overlay.cells[idx] = { char = 32, attr = attr }
		end
		return
	else
		local idx = overlay.cursorRow * self.config.TEXT_COLS + overlay.cursorCol
		overlay.cells[idx] = { char = charValue, attr = attr }
		overlay.cursorCol = overlay.cursorCol + 1
		if overlay.cursorCol >= self.config.TEXT_COLS then
			overlay.cursorCol = 0
			overlay.cursorRow = overlay.cursorRow + 1
		end
	end

	if overlay.cursorRow >= self.config.TEXT_ROWS then
		for row = 0, self.config.TEXT_ROWS - 2 do
			for col = 0, self.config.TEXT_COLS - 1 do
				local dst = row * self.config.TEXT_COLS + col
				local src = (row + 1) * self.config.TEXT_COLS + col
				overlay.cells[dst] = overlay.cells[src] or { char = 32, attr = overlay.defaultAttr }
			end
		end
		for col = 0, self.config.TEXT_COLS - 1 do
			overlay.cells[(self.config.TEXT_ROWS - 1) * self.config.TEXT_COLS + col] = {
				char = 32,
				attr = overlay.defaultAttr,
			}
		end
		overlay.cursorRow = self.config.TEXT_ROWS - 1
	end
end

function VgaAdapter:_paletteColor(index)
	local entry = self._dac[bit32.band(tonumber(index) or 0, self._dacMask)] or { r = 0, g = 0, b = 0 }
	return packARGB(255, scale6To8(entry.r), scale6To8(entry.g), scale6To8(entry.b))
end

function VgaAdapter:_attributeColor(index)
	local paletteIndex = self._attribute[(tonumber(index) or 0) % 16] or 0
	local colorSelect = self._attribute[0x14] or 0
	paletteIndex = bit32.band(paletteIndex, 0x3F)
	paletteIndex = bit32.bor(paletteIndex, bit32.lshift(bit32.band(colorSelect, 0x0C), 4))
	return self:_paletteColor(paletteIndex)
end

function VgaAdapter:_clearFrame(argb)
	for index = 0, self.W * self.H - 1 do
		self._framebuf[index] = argb
	end
	markPixelRectDirty(self, 0, 0, self.W, self.H)
end

function VgaAdapter:_blitScaledPixel(x, y, argb)
	local px = x * 2
	local py = y * 2
	if px + 1 >= self.W or py + 1 >= self.H then
		return
	end
	self._framebuf[py * self.W + px] = argb
	self._framebuf[py * self.W + px + 1] = argb
	self._framebuf[(py + 1) * self.W + px] = argb
	self._framebuf[(py + 1) * self.W + px + 1] = argb
end

function VgaAdapter:_renderHardwareText()
	self:_clearFrame(0xFF000000)
	local startCell = textStartCell(self)
	local blinkEnabled = bit32.band(self._attribute[0x10] or 0, 0x08) ~= 0
	local cursorDisabled = bit32.band(self._crtc[0x0A] or 0, 0x20) ~= 0
	local cursorStart = bit32.band(self._crtc[0x0A] or 0, 0x1F)
	local cursorEnd = bit32.band(self._crtc[0x0B] or 0, 0x1F)

	for row = 0, self.config.TEXT_ROWS - 1 do
		for col = 0, self.config.TEXT_COLS - 1 do
			local absoluteIdx = (startCell + row * self.config.TEXT_COLS + col) % math.max(1, self._textCellCount)
			local cell = self._textBuf[absoluteIdx] or { char = 32, attr = 0x07 }
			local attr = cell.attr or 0x07
			local fgIndex = bit32.band(attr, 0x0F)
			local bgIndex = bit32.band(bit32.rshift(attr, 4), 0x07)
			local suppressGlyph = false
			if bit32.band(attr, 0x80) ~= 0 then
				if blinkEnabled then
					suppressGlyph = not self._cursorVisible
				else
					bgIndex = bit32.bor(bgIndex, 0x08)
				end
			end

			local fg = self:_attributeColor(fgIndex)
			local bg = self:_attributeColor(bgIndex)
			local charCode = cell.char or 32
			for glyphRow = 0, self._fontHeight - 1 do
				local rowBits = fontByte(self, charCode, glyphRow)
				local py = row * self.CH + glyphRow
				local base = py * self.W
				for glyphCol = 0, 7 do
					local mask = bit32.lshift(1, 7 - glyphCol)
					local on = bit32.band(rowBits, mask) ~= 0
					self._framebuf[base + col * self.CW + glyphCol] = (not suppressGlyph and on) and fg or bg
				end
			end

			local drawCursor = not cursorDisabled
				and self._cursorVisible
				and col == self._cursorCol
				and row == self._cursorRow
			if drawCursor then
				local y0 = row * self.CH + math.min(self.CH - 1, cursorStart)
				local y1 = row * self.CH + math.min(self.CH - 1, math.max(cursorStart, cursorEnd))
				for py = y0, y1 do
					for px = col * self.CW, (col + 1) * self.CW - 1 do
						self:_setPixelRaw(px, py, fg)
					end
				end
			end
		end
	end
end

function VgaAdapter:_renderMode13()
	self:_clearFrame(0xFF000000)
	for y = 0, 199 do
		local rowOffset = y * 320
		for x = 0, 319 do
			local linearOffset = rowOffset + x
			local plane = linearOffset % 4
			local planeOffset = math.floor(linearOffset / 4)
			local colorIndex = self._planes[plane][planeOffset] or 0
			self:_blitScaledPixel(x, y, self:_paletteColor(colorIndex))
		end
	end
end

function VgaAdapter:_renderPlanar()
	self:_clearFrame(0xFF000000)
	for y = 0, 199 do
		local scanOffset = y * 40
		for byteIndex = 0, 39 do
			local offset = scanOffset + byteIndex
			local p0 = self._planes[0][offset] or 0
			local p1 = self._planes[1][offset] or 0
			local p2 = self._planes[2][offset] or 0
			local p3 = self._planes[3][offset] or 0
			for bitIndex = 0, 7 do
				local shift = 7 - bitIndex
				local colorIndex = bit32.band(bit32.rshift(p0, shift), 0x01)
				colorIndex = bit32.bor(colorIndex, bit32.lshift(bit32.band(bit32.rshift(p1, shift), 0x01), 1))
				colorIndex = bit32.bor(colorIndex, bit32.lshift(bit32.band(bit32.rshift(p2, shift), 0x01), 2))
				colorIndex = bit32.bor(colorIndex, bit32.lshift(bit32.band(bit32.rshift(p3, shift), 0x01), 3))
				self:_blitScaledPixel(byteIndex * 8 + bitIndex, y, self:_attributeColor(colorIndex))
			end
		end
	end
end

function VgaAdapter:_renderHostOverlay()
	if not self._hostOverlay.active then
		return
	end
	markPixelRectDirty(self, 0, 0, self.W, self.H)
	for row = 0, self.config.TEXT_ROWS - 1 do
		for col = 0, self.config.TEXT_COLS - 1 do
			local idx = row * self.config.TEXT_COLS + col
			local cell = self._hostOverlay.cells[idx] or { char = 32, attr = self._hostOverlay.defaultAttr }
			local fg = PALETTE[bit32.band(cell.attr or 0x0C, 0x0F)] or 0xFFFF5555
			local bg = PALETTE[bit32.band(bit32.rshift(cell.attr or 0x0C, 4), 0x0F)] or 0xFF000000
			self:drawChar(col * self.CW, row * self.CH, cell.char or 32, fg, bg)
		end
	end
end

function VgaAdapter:biosSetVideoMode(mode)
	local newMode = (tonumber(mode) or 0) % 256
	self._biosMode = newMode
	self._miscOutput = 0x67
	resetAttributePalette(self)
	self._crtc[0x0A] = 0x0D
	self._crtc[0x0B] = 0x0E
	self._crtc[0x0C] = 0
	self._crtc[0x0D] = 0
	self._crtc[0x0E] = 0
	self._crtc[0x0F] = 0

	if newMode == 0x13 then
		self.mode = "MODE13"
		self._sequencer[0x02] = 0x0F
		self._sequencer[0x04] = 0x07
		self._graphics[0x05] = 0x40
		self._graphics[0x06] = 0x05
	elseif newMode == 0x0D or newMode == 0x0E or newMode == 0x10 then
		self.mode = "PLANAR"
		self._sequencer[0x02] = 0x0F
		self._sequencer[0x04] = 0x03
		self._graphics[0x05] = 0x00
		self._graphics[0x06] = 0x05
	else
		self.mode = "TEXT"
		self._sequencer[0x02] = 0x03
		self._sequencer[0x04] = 0x01
		self._graphics[0x05] = 0x10
		self._graphics[0x06] = 0x0C
		self:clearScreen(0x07)
	end

	self.stats.modeChanges = self.stats.modeChanges + 1
	self._dirty = true
end

function VgaAdapter:biosTeletype(ch, attr)
	if self.mode ~= "TEXT" then
		return
	end
	self:print(string.char((tonumber(ch) or 32) % 256), attr or 0x07)
end

function VgaAdapter:setCursorPos(_page, row, col)
	self:moveCursor(tonumber(col) or 0, tonumber(row) or 0)
end

function VgaAdapter:getCursorPos(_page)
	local col, row = self:getCursor()
	return row, col
end

function VgaAdapter:setCursorType(startLine, endLine)
	self._crtc[0x0A] = bit32.band(tonumber(startLine) or 0, 0x1F)
	self._crtc[0x0B] = bit32.band(tonumber(endLine) or (self.CH - 1), 0x1F)
	markCellDirty(self, self._cursorCol, self._cursorRow)
	self._dirty = true
end

function VgaAdapter:getVideoMode()
	return self._biosMode or 0x03, self.config.TEXT_COLS, 0
end

function VgaAdapter:readCharAttr(_page)
	local idx = (textStartCell(self) + (self._cursorRow * self.config.TEXT_COLS) + self._cursorCol)
		% math.max(1, self._textCellCount)
	local cell = self._textBuf[idx] or { char = 32, attr = 0x07 }
	return cell.char or 32, cell.attr or 0x07
end

function VgaAdapter:writeCharAttr(_page, ch, attr, count)
	local repetitions = math.max(0, tonumber(count) or 0)
	for _ = 1, repetitions do
		self:putChar(self._cursorCol, self._cursorRow, ch, attr)
		self._cursorCol = self._cursorCol + 1
		if self._cursorCol >= self.config.TEXT_COLS then
			self._cursorCol = 0
			self._cursorRow = self._cursorRow + 1
		end
		if self._cursorRow >= self.config.TEXT_ROWS then
			self:_scrollUp()
			self._cursorRow = self.config.TEXT_ROWS - 1
		end
	end
	updateCursorRegisters(self)
	self._dirty = true
end

function VgaAdapter:scrollWindow(_page, top, left, bottom, right, lines, attr)
	local cols = self.config.TEXT_COLS
	local rows = self.config.TEXT_ROWS
	local x0 = clamp(tonumber(left) or 0, 0, cols - 1)
	local y0 = clamp(tonumber(top) or 0, 0, rows - 1)
	local x1 = clamp(tonumber(right) or (cols - 1), x0, cols - 1)
	local y1 = clamp(tonumber(bottom) or (rows - 1), y0, rows - 1)
	local fillAttr = (tonumber(attr) or 0x07) % 256
	local distance = math.max(0, tonumber(lines) or 0)

	if distance == 0 or distance >= (y1 - y0 + 1) then
		for row = y0, y1 do
			for col = x0, x1 do
				self:putChar(col, row, 32, fillAttr)
			end
		end
		updateCursorRegisters(self)
		self._dirty = true
		return
	end

	for row = y0, y1 - distance do
		for col = x0, x1 do
			local srcIdx = (textStartCell(self) + ((row + distance) * cols) + col) % math.max(1, self._textCellCount)
			local cell = self._textBuf[srcIdx] or { char = 32, attr = fillAttr }
			self:putChar(col, row, cell.char, cell.attr)
		end
	end

	for row = y1 - distance + 1, y1 do
		for col = x0, x1 do
			self:putChar(col, row, 32, fillAttr)
		end
	end

	updateCursorRegisters(self)
	self._dirty = true
end

function VgaAdapter:hostClear(attr)
	local overlayAttr = (tonumber(attr) or self._hostOverlay.defaultAttr or 0x0C) % 256
	self._hostOverlay.active = true
	self._hostOverlay.defaultAttr = overlayAttr
	self._hostOverlay.cursorCol = 0
	self._hostOverlay.cursorRow = 0
	clearCells(self._hostOverlay.cells, self.config.TEXT_COLS * self.config.TEXT_ROWS, overlayAttr)
	self._dirty = true
	markAllCellsDirty(self)
end

function VgaAdapter:hostWrite(text, attr)
	local overlayAttr = (tonumber(attr) or self._hostOverlay.defaultAttr or 0x0C) % 256
	if not self._hostOverlay.active then
		self:hostClear(overlayAttr)
	end
	local rendered = tostring(text or "")
	for index = 1, #rendered do
		hostWriteChar(self, string.byte(rendered, index), overlayAttr)
	end
	self.stats.hostWrites = self.stats.hostWrites + #rendered
	self._dirty = true
	markAllCellsDirty(self)
end

function VgaAdapter:hostWriteLine(text, attr)
	self:hostWrite(tostring(text or ""), attr)
	hostWriteChar(self, 10, (tonumber(attr) or self._hostOverlay.defaultAttr or 0x0C) % 256)
	self._dirty = true
	markAllCellsDirty(self)
end

function VgaAdapter:clearHostOverlay()
	self._hostOverlay.active = false
	self._hostOverlay.cursorCol = 0
	self._hostOverlay.cursorRow = 0
	clearCells(self._hostOverlay.cells, self.config.TEXT_COLS * self.config.TEXT_ROWS, self._hostOverlay.defaultAttr)
	self._dirty = true
	markAllCellsDirty(self)
end

function VgaAdapter:attachBus(bus)
	bus:registerPort(self.config.PORT.VGA_ATTR_INDEX, function()
		return self._attrIndex
	end, function(v)
		local value = bit32.band(tonumber(v) or 0, 0x3F)
		if not self._attrFlipFlop then
			self._attrIndex = bit32.band(value, 0x1F)
			self._attrFlipFlop = true
		else
			self._attribute[self._attrIndex] = value
			self._attrFlipFlop = false
			self.stats.registerWrites = self.stats.registerWrites + 1
			self._dirty = true
			markTextStateDirty(self)
		end
	end, "VGA Attribute")
	bus:registerPort(self.config.PORT.VGA_ATTR_DATA_READ, function()
		return self._attribute[self._attrIndex] or 0
	end, nil, "VGA Attribute Read")
	bus:registerPort(self.config.PORT.VGA_MISC_WRITE, function()
		return self._miscOutput
	end, function(v)
		self._miscOutput = bit32.band(tonumber(v) or 0, 0xFF)
		self.stats.registerWrites = self.stats.registerWrites + 1
		self._dirty = true
		markTextStateDirty(self)
	end, "VGA Misc")
	bus:registerPort(self.config.PORT.VGA_SEQ_INDEX, function()
		return self._seqIndex
	end, function(v)
		self._seqIndex = bit32.band(tonumber(v) or 0, 0x07)
	end, "VGA Sequencer Index")
	bus:registerPort(self.config.PORT.VGA_SEQ_DATA, function()
		return self._sequencer[self._seqIndex] or 0
	end, function(v)
		self._sequencer[self._seqIndex] = bit32.band(tonumber(v) or 0, 0xFF)
		self.stats.registerWrites = self.stats.registerWrites + 1
		self._dirty = true
		markTextStateDirty(self)
	end, "VGA Sequencer Data")
	bus:registerPort(self.config.PORT.VGA_DAC_MASK, function()
		return self._dacMask
	end, function(v)
		self._dacMask = bit32.band(tonumber(v) or 0, 0xFF)
	end, "VGA DAC Mask")
	bus:registerPort(self.config.PORT.VGA_DAC_READ_INDEX, function()
		return self._dacReadIndex
	end, function(v)
		self._dacReadIndex = bit32.band(tonumber(v) or 0, 0xFF)
		self._dacReadComponent = 0
	end, "VGA DAC Read Index")
	bus:registerPort(self.config.PORT.VGA_DAC_WRITE_INDEX, function()
		return self._dacWriteIndex
	end, function(v)
		self._dacWriteIndex = bit32.band(tonumber(v) or 0, 0xFF)
		self._dacWriteComponent = 0
	end, "VGA DAC Write Index")
	bus:registerPort(self.config.PORT.VGA_DAC_DATA, function()
		local entry = self._dac[self._dacReadIndex] or { r = 0, g = 0, b = 0 }
		local component = entry.r
		if self._dacReadComponent == 1 then
			component = entry.g
		elseif self._dacReadComponent == 2 then
			component = entry.b
		end
		self._dacReadComponent = (self._dacReadComponent + 1) % 3
		if self._dacReadComponent == 0 then
			self._dacReadIndex = (self._dacReadIndex + 1) % 256
		end
		return component
	end, function(v)
		local entry = self._dac[self._dacWriteIndex] or { r = 0, g = 0, b = 0 }
		local value = bit32.band(tonumber(v) or 0, 0x3F)
		if self._dacWriteComponent == 0 then
			entry.r = value
		elseif self._dacWriteComponent == 1 then
			entry.g = value
		else
			entry.b = value
		end
		self._dac[self._dacWriteIndex] = entry
		self._dacWriteComponent = (self._dacWriteComponent + 1) % 3
		if self._dacWriteComponent == 0 then
			self._dacWriteIndex = (self._dacWriteIndex + 1) % 256
		end
		self.stats.paletteWrites = self.stats.paletteWrites + 1
		self._dirty = true
		markTextStateDirty(self)
	end, "VGA DAC Data")
	bus:registerPort(self.config.PORT.VGA_MISC_READ, function()
		return self._miscOutput
	end, nil, "VGA Misc Read")
	bus:registerPort(self.config.PORT.VGA_GC_INDEX, function()
		return self._gcIndex
	end, function(v)
		self._gcIndex = bit32.band(tonumber(v) or 0, 0x0F)
	end, "VGA Graphics Index")
	bus:registerPort(self.config.PORT.VGA_GC_DATA, function()
		return self._graphics[self._gcIndex] or 0
	end, function(v)
		self._graphics[self._gcIndex] = bit32.band(tonumber(v) or 0, 0xFF)
		self.stats.registerWrites = self.stats.registerWrites + 1
		self._dirty = true
		markTextStateDirty(self)
	end, "VGA Graphics Data")
	bus:registerPort(self.config.PORT.VGA_CRTC_INDEX, function()
		return self._crtcIndex
	end, function(v)
		self._crtcIndex = bit32.band(tonumber(v) or 0, 0x1F)
	end, "VGA CRTC Index")
	bus:registerPort(self.config.PORT.VGA_CRTC_DATA, function()
		return self._crtc[self._crtcIndex] or 0
	end, function(v)
		local value = bit32.band(tonumber(v) or 0, 0xFF)
		self._crtc[self._crtcIndex] = value
		self.stats.registerWrites = self.stats.registerWrites + 1
		if self._crtcIndex == 0x0C or self._crtcIndex == 0x0D then
			markAllCellsDirty(self)
			applyCursorRegisters(self)
		elseif self._crtcIndex == 0x0E or self._crtcIndex == 0x0F then
			markCellDirty(self, self._cursorCol, self._cursorRow)
			applyCursorRegisters(self)
			markCellDirty(self, self._cursorCol, self._cursorRow)
		end
		self._dirty = true
		markTextStateDirty(self)
	end, "VGA CRTC Data")
	bus:registerPort(self.config.PORT.VGA_INPUT_STATUS1, function()
		self._attrFlipFlop = false
		updateTimingState(self)
		self._status1 = (self._timing.inVerticalRetrace and 0x08 or 0x00)
			+ (self._timing.inDisplayEnable and 0x00 or 0x01)
		return self._status1
	end, nil, "VGA Input Status 1")
end

function VgaAdapter:memRead(offset)
	self.stats.vramReads = self.stats.vramReads + 1
	local address = (tonumber(offset) or 0) % self._apertureSize
	local apertureOffset = decodeWindow(self, address)
	if
		isTextState(self)
		and address >= self._textBaseOffset
		and address < self._textBaseOffset + self._textByteCount
	then
		local textOffset = address - self._textBaseOffset
		local cellIdx = math.floor(textOffset / 2) % math.max(1, self._textCellCount)
		if textOffset % 2 == 0 then
			return self._planes[0][cellIdx] or 32
		end
		return self._planes[1][cellIdx] or 0x07
	end
	if apertureOffset == nil then
		return 0xFF
	end

	if isChain4State(self) then
		local plane = apertureOffset % 4
		local planeOffset = math.floor(apertureOffset / 4) % self._planeSize
		return self._planes[plane][planeOffset] or 0
	end
	return planarRead(self, apertureOffset % self._planeSize)
end

function VgaAdapter:memWrite(offset, value)
	self.stats.vramWrites = self.stats.vramWrites + 1
	local address = (tonumber(offset) or 0) % self._apertureSize
	local byteValue = (tonumber(value) or 0) % 256

	if
		isTextState(self)
		and address >= self._textBaseOffset
		and address < self._textBaseOffset + self._textByteCount
	then
		local textOffset = address - self._textBaseOffset
		local cellIdx = math.floor(textOffset / 2) % math.max(1, self._textCellCount)
		if textOffset % 2 == 0 then
			self._planes[0][cellIdx] = byteValue
		else
			self._planes[1][cellIdx] = byteValue
		end
		syncTextCellFromPlanes(self, cellIdx)
		self.stats.textWrites = self.stats.textWrites + 1
		self._dirty = true
		return
	end
	local apertureOffset = decodeWindow(self, address)
	if apertureOffset == nil then
		return
	end

	if isChain4State(self) then
		local plane = apertureOffset % 4
		local planeOffset = math.floor(apertureOffset / 4) % self._planeSize
		self._planes[plane][planeOffset] = byteValue
	else
		planarWrite(self, apertureOffset % self._planeSize, byteValue)
	end
	self._dirty = true
end

function VgaAdapter:setMode(mode)
	if mode == "TEXT" then
		self:biosSetVideoMode(0x03)
	elseif mode == "MODE13" then
		self:biosSetVideoMode(0x13)
	else
		self.mode = mode
		self._dirty = true
	end
end

function VgaAdapter:clearScreen(attr)
	local cellAttr = (tonumber(attr) or 0x07) % 256
	for index = 0, self._textCellCount - 1 do
		setTextCell(self, index, 32, cellAttr)
	end
	self._cursorRow = 0
	self._cursorCol = 0
	self._crtc[0x0C] = 0
	self._crtc[0x0D] = 0
	updateCursorRegisters(self)
	self._lastCursor.col = 0
	self._lastCursor.row = 0
	markAllCellsDirty(self)
	self._dirty = true
end

function VgaAdapter:putChar(col, row, ch, attr)
	if col < 0 or col >= self.config.TEXT_COLS or row < 0 or row >= self.config.TEXT_ROWS then
		return
	end
	local idx = (textStartCell(self) + (row * self.config.TEXT_COLS) + col) % math.max(1, self._textCellCount)
	setTextCell(self, idx, (type(ch) == "string") and string.byte(ch, 1) or ch, attr or 0x07)
	self.stats.textWrites = self.stats.textWrites + 1
	self._dirty = true
end

function VgaAdapter:_scrollUp()
	local cols = self.config.TEXT_COLS
	local rows = self.config.TEXT_ROWS
	local startCell = textStartCell(self)
	for row = 0, rows - 2 do
		for col = 0, cols - 1 do
			local dstIdx = (startCell + row * cols + col) % math.max(1, self._textCellCount)
			local srcIdx = (startCell + (row + 1) * cols + col) % math.max(1, self._textCellCount)
			local src = self._textBuf[srcIdx] or { char = 32, attr = 0x07 }
			setTextCell(self, dstIdx, src.char, src.attr)
		end
	end
	for col = 0, cols - 1 do
		local idx = (startCell + (rows - 1) * cols + col) % math.max(1, self._textCellCount)
		setTextCell(self, idx, 32, 0x07)
	end
	markAllCellsDirty(self)
end

function VgaAdapter:print(str, attr)
	attr = attr or 0x07
	for i = 1, #str do
		local c = string.byte(str, i)
		if c == 10 then
			self._cursorRow = self._cursorRow + 1
		elseif c == 13 then
			self._cursorCol = 0
		elseif c == 8 then
			if self._cursorCol > 0 then
				self._cursorCol = self._cursorCol - 1
			end
		else
			self:putChar(self._cursorCol, self._cursorRow, c, attr)
			self._cursorCol = self._cursorCol + 1
			if self._cursorCol >= self.config.TEXT_COLS then
				self._cursorCol = 0
				self._cursorRow = self._cursorRow + 1
			end
		end
		if self._cursorRow >= self.config.TEXT_ROWS then
			self:_scrollUp()
			self._cursorRow = self.config.TEXT_ROWS - 1
		end
	end
	updateCursorRegisters(self)
	self._dirty = true
end

function VgaAdapter:println(str, attr)
	self:print((str or "") .. "\n", attr)
end

function VgaAdapter:toggleCursor()
	markCellDirty(self, self._cursorCol, self._cursorRow)
	markCellDirty(self, self._lastCursor.col, self._lastCursor.row)
	self._cursorVisible = not self._cursorVisible
	self._dirty = true
end

function VgaAdapter:flush(presentFn)
	if not self._dirty then
		return
	end

	local now = os.clock()
	if self._nextFrameTime ~= 0 and now < self._nextFrameTime then
		return
	end

	if isTextState(self) then
		if self._hostOverlay.active then
			self:_renderHardwareText()
			self:_renderHostOverlay()
		else
			self:_renderText()
		end
	elseif isChain4State(self) then
		self:_renderMode13()
		self:_renderHostOverlay()
	else
		self:_renderPlanar()
		self:_renderHostOverlay()
	end
	self.stats.flushes = self.stats.flushes + 1

	local pixelBuffer = self:_packPixelBuffer()
	if presentFn then
		presentFn(pixelBuffer, self.W, self.H)
	end

	self._dirty = false
	self._nextFrameTime = now + self._frameInterval
end

function VgaAdapter:present(presentFn)
	self:flush(presentFn)
end

function VgaAdapter:tick(dt)
	self._timing.elapsed = self._timing.elapsed + math.max(0, tonumber(dt) or 0)
	updateTimingState(self)
end

function VgaAdapter:getStats()
	return self.stats
end
VgaAdapter.PALETTE = PALETTE

return VgaAdapter
