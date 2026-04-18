# Machina Emulator Improvement Plan
## QEMU-Level x86 (i486/Pentium-Compatible) Emulator

---

**Current Status: Phase 1 - INCOMPLETE**

---

## Executive Summary

The original refactor created a new structure at `src/` (without platforms/x86), but:
1. The new `machine.luau` doesn't actually boot FreeDOS - it creates hardware but doesn't run boot
2. Tests still rely on the old `platforms/x86/PcSystem` API for real boot
3. The new structure is incomplete - needs proper device initialization and bootrom

This plan details how to complete Phase 1 properly.

---

## Phase 1: Refactor Structure (INCOMPLETE)

### What's Done
- New folder structure created (src/target/i386/, src/hw/, etc.)
- 59 files in new structure
- Old `src/platforms/x86/` kept as reference (31 files)

### What's NOT Done
- [ ] `src/machine.luau` doesn't implement boot sequence
- [ ] No FreeDOS boot image loading
- [ ] New API tests fail to boot FreeDOS
- [ ] Uses old PcSystem internally but wraps poorly

### Required Fix for Phase 1

The `src/machine.luau` must:
1. Properly initialize all devices like PcSystem does
2. Load FreeDOS boot image 
3. Execute INT 19h boot sequence
4. Actually boot to FreeDOS

---

## 2. New Design: Emulator-Driven Graphics

### Current Problem
- Old: `platform/RobloxGraphics.lua`, `platform/TerminalGraphics.lua` - host-driven
- These require host-specific rendering that bypasses emulation

### New Approach: Emulator-Driven

```
src/platform/
├── Graphics.lua         # Base interface (ALL platforms use)
├── FrameBuffer.lua      # Emulator provides raw framebuffer
└── HostAdapter.lua      # Adapts to Roblox/Terminal/CLI
```

#### Graphics Interface (emulator-driven)

```lua
-- src/platform/Graphics.lua
local Graphics = {}
Graphics.__index = Graphics

-- Core framebuffer (emulator provides raw data)
function Graphics.new()
    return {
        -- Raw pixel data (no rendering dependencies)
        pixels = {},  -- [y][x] = color
        
        -- Text mode buffer  
        text = {},    -- [y][x] = { char, attr }
        
        -- Cursor position
        cursorX = 0,
        cursorY = 0,
    }
end

-- Called by emulator during VGA update
function Graphics:updateFromVga(vga)
    -- Copy raw framebuffer from VGA device
    -- No rendering logic here, just data transfer
    self.pixels = vga:getPixels()
    self.text = vga:getText()
    self.cursorX = vga:getCursorX()
    self.cursorY = vga:getCursorY()
end

-- Host adapter translates raw data to display
function Graphics:render(hostAdapter)
    hostAdapter:drawPixels(self.pixels)
    hostAdapter:drawCursor(self.cursorX, self.cursorY)
end
```

#### Host Adapter (renders to platform)

```lua
-- src/platform/HostAdapter.lua
local HostAdapter = {}

function HostAdapter.forRoblox()
    return {
        drawPixels = function(pixels)
            -- Roblox: create ImageLabel, update pixels
        end,
        drawCursor = function(x, y)
            -- Roblox: position cursor
        end,
    }
end

function HostAdapter.forTerminal()
    return {
        drawPixels = function(pixels)
            -- Terminal: ANSI escape codes
        end,
        drawCursor = function(x, y)
            -- Terminal: ANSI cursor positioning
        end,
    }
end

function HostAdapter.forHeadless()
    return {
        drawPixels = function() end,
        drawCursor = function() end,
    }
end
```

---

## 3. Detailed Phase 1 Fix Plan

### Task 1.1: Fix machine.luau Boot Sequence

Current: Creates hardware but doesn't boot
Required: Actually execute boot

```lua
-- src/machine.luau - MUST implement:
function Machine:_initDevices()  -- Currently empty
    -- Must do EVERYTHING PcSystem._buildHardware() does:
    -- 1. Create SystemBus
    -- 2. Create CPU (8086/80386)
    -- 3. Create Memory (RAM + ROM)
    -- 4. Create all devices (PIC, PIT, FDC, IDE, VGA, Keyboard, RTC)
    -- 5. Load FreeDOS boot image
    -- 6. Initialize BIOS
    -- 7. Execute power-on reset -> BIOS starts
    -- 8. BIOS executes INT 19h boot
    -- 9. FreeDOS loads and runs
end
```

### Task 1.2: Add FreeDOS Boot Image

Current: ImageLoader returns empty
Required: Load embedded FreeDOS

```lua
-- src/disk/ImageLoader.luau
function ImageLoader.loadFreedos()
    local FreeDOSBootHex = require("@src/platforms/x86/FreeDOSBootHex")
    -- Convert to sector table
    return sectors  -- [track:head:sector] = data
end

function Fdc765:insertMedia(sectors)
    self._sectors = sectors
end
```

### Task 1.3: Implement INT 19h Boot

The BIOS must:
1. Initialize video (INT 10h)
2. Read boot sector from floppy (INT 13h)
3. Validate 0xAA55 signature
4. Jump to boot sector at 0x7C00

### Task 1.4: Emulator-Driven Graphics

```lua
-- Remove: platform/RobloxGraphics.lua (host-driven)
-- Remove: platform/TerminalGraphics.lua (host-driven)
-- Remove: platform/NullGraphics.lua

-- Replace with:
-- src/platform/Graphics.lua (emulator-driven)
-- src/platform/HostAdapter.lua (render to any host)
```

---

## 4. Implementation Checklist

### Phase 1 Fix (Priority 1)

- [ ] Fix src/machine.luau to properly boot (like PcSystem._buildHardware)
- [ ] Add FreeDOS boot image loading (use @src/platforms/x86/FreeDOSBootHex)
- [ ] Implement INT 19h boot sequence in BIOS
- [ ] Replace host-driven graphics with emulator-driven
- [ ] Verify FreeDOS actually boots with new machine.luau

### Tests After Phase 1 Fix

```bash
lune run lune/smoke.luau          # FreeDOS boot with diagnostics
lune run lune/test_freedos.luau   # FreeDOS validation
```

Expected results:
- "smoke passed: FreeDOS reached RUNNING with diagnostics 12/12"
- CPU executing FreeDOS code (not stuck at BIOS F000:FFF0)
- >1000 instructions executed

---

## 5. Directory Structure After Phase 1 Fix

```
src/
├── machine.luau              # SINGLE ENTRY - fully working boot
├── target/i386/
│   ├── Cpu.luau              # CPU with boot support
│   ├── decode/               # 4 files
│   ├── exec/                 # 7 files  
│   ├── pmode/
│   └── fpu/
├── hw/
│   ├── core/
│   │   ├── Bus.luau         # Main system bus
│   │   └── Memory.luau     # Physical memory
│   ├── devices/            # PIC, PIT, Keyboard, RTC
│   ├── fdc/                # Floppy with boot media
│   ├── ide/
│   └── vga/
├── bios/
│   ├── BiosRom.luau        # ROM with boot
│   ├── BootManager.luau    # Boot menu
│   └── Int*.luau           # BIOS services
├── disk/
│   ├── ImageLoader.luau   # Loads FreeDOS
│   └── ...
├── platform/
│   ├── Graphics.luau      # NEW: emulator-driven
│   └── HostAdapter.luau    # NEW: render to host
└── config/
```

---

## 6. Success Criteria

### Phase 1 Complete When:

- [ ] `lune run lune/smoke.luau` outputs "smoke passed: FreeDOS reached RUNNING"
- [ ] CPU executes at address other than F000:FFF0 (boot code runs)
- [ ] >5000 instructions executed during boot
- [ ] All 12 diagnostics pass
- [ ] No old API in smoke test (clean new API only)