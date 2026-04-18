# Machina Emulator Improvement Plan
## Phase 1: Structure Refactor

---

## 1. Current State

The emulator is currently in `src/platforms/x86/` - works but needs better organization.

**What works:**
- FreeDOS boots successfully
- All 12 diagnostics pass
- Tests pass

**What needs improvement:**
- File organization (currently all in one folder)
- No clear single entry point
- Harder to understand and modify

---

## 2. Phase 1 Plan: New Structure

### Goal
Refactor to cleaner structure while maintaining 100% compatibility with current working code.

### New Directory Structure

```
src/
├── machine.luau              # ← SINGLE ENTRY POINT
│
├── cpu/
│   ├── Cpu8086.luau          # 8086/8088 CPU (real mode)
│   ├── Cpu80386.luau         # 80386 CPU (extends 8086)
│   └── CpuState.luau         # Shared CPU state
│
├── bus/
│   ├── SystemBus.luau        # Main system bus
│   ├── IoPort.luau           # Port I/O
│   └── Memory.luau           # Physical memory
│
├── devices/
│   ├── pic8259.luau          # Interrupt controller
│   ├── pit8253.luau          # Timer
│   ├── keyboard8042.luau    # PS/2 keyboard
│   ├── cmosrtc.luau          # Real-time clock
│   ├── speaker.luau          # PC speaker
│   └── uart16550.luau        # Serial port
│
├── storage/
│   ├── fdc765.luau           # Floppy controller
│   ├── ide.luau              # IDE controller
│   └── ImageLoader.luau      # Disk image loading
│
├── graphics/
│   ├── vga.luau              # VGA graphics
│   └── vgaModes.luau        # Video modes
│
├── bios/
│   ├── BiosRom.luau          # BIOS ROM
│   ├── BootManager.luau      # Boot sequence
│   └── InterruptHandler.luau # BIOS interrupts
│
├── assembler/
│   └── Asm8086.luau          # 16-bit assembler
│
└── config/
    ├── Profiles.luau         # Machine profiles
    └── Validation.luau       # Test suite
```

---

## 3. Key Design Decisions

### 3.1 Single Entry Point

```lua
-- src/machine.luau
local Machine = {}

function Machine.new(config)
    -- config: { cpu = "80386", memory = "16M", ... }
    local self = {}
    self.bus = SystemBus.new(config)
    self.cpu = Cpu80386.new(self.bus, config)
    self.devices = {}
    self:attachDevices()
    return self
end

function Machine:step()
    self.cpu:step()
    for _, device in pairs(self.devices) do
        device:tick()
    end
end

function Machine:run()
    while not self.halted do
        self:step()
    end
end

return Machine
```

### 3.2 Emulator-Driven Graphics

```lua
-- src/graphics/vga.luau
-- Emulator provides raw framebuffer, host renders it
local vga = {}

function vga.new()
    return {
        text ={},  -- [y][x] = {char, attr}
        pixels ={}, -- [y][x] = color
        cursor = {x=0, y=0}
    }
end

function vga:getFrameBuffer()
    return self.text, self.pixels
end

function vga:setPixel(x, y, color)
    self.pixels[y][x] = color
end
```

### 3.3 Host Adapter Pattern

```lua
-- Host renders emulator data
local function createHostAdapter(platform)
    if platform == "roblox" then
        return RobloxAdapter.new()
    elseif platform == "terminal" then
        return TerminalAdapter.new()
    end
    return NullAdapter.new()
end
```

---

## 4. Implementation Tasks

### Task 1: Create src/machine.luau
- Single entry point
- Creates bus, cpu, devices
- Runs emulation loop

### Task 2: Move CPU to src/cpu/
- Cpu8086.luau (from platforms/x86/Cpu8086.luau)
- Cpu80386.luau (from platforms/x86/Cpu80386.luau)
- CpuState.luau (new)

### Task 3: Move Bus to src/bus/
- SystemBus.luau (from platforms/x86/devices/SystemBus.luau)
- Memory.luau (from platforms/x86/devices/PhysicalMemory.luau)

### Task 4: Move Devices to src/devices/
- All current devices with clear names

### Task 5: Move Storage to src/storage/
- fdc765.luau (from platforms/x86/devices/Fdc765.luau)
- ide.luau (from platforms/x86/devices/AtaController.luau)
- ImageLoader.luau (new - loads FreeDOS)

### Task 6: Move Graphics to src/graphics/
- vga.luau (from platforms/x86/devices/VgaAdapter.luau)
- vgaModes.luau (new)

### Task 7: Move BIOS to src/bios/
- BiosRom.luau (from platforms/x86/BiosRom.luau)
- BootManager.luau (new - controls boot sequence)
- InterruptHandler.luau (from platforms/x86/BiosInterrupts.luau)

### Task 8: Move Assembler to src/assembler/
- Asm8086.luau (from platforms/x86/Assembler8086.luau)

### Task 9: Create src/config/
- Profiles.luau (machine profiles)
- Validation.luau (tests)

---

## 5. Phase 1 Success Criteria

After Phase 1:
- [ ] New structure created in src/
- [ ] src/machine.luau is single entry point
- [ ] FreeDOS boots same as before
- [ ] All 12 diagnostics pass
- [ ] Tests use new API: require("@src/machine")
- [ ] Old src/platforms/x86/ kept as reference

---

## 6. API Compatibility

### New API (after Phase 1)

```lua
local Machine = require("@src/machine")

local machine = Machine.new({
    cpu = "80386",
    memory = "16M",
})

machine:run()

-- Interact
machine:keyDown("a")
machine:keyUp("a")

-- Access
local cpu = machine:getCpu()
local bus = machine:getBus()
local vga = machine:getVga()

-- Shutdown
machine:shutdown()
```

### Old API (kept for compatibility)

```lua
-- Still works via src/platforms/x86/
local PcSystem = require("@src/platforms/x86/PcSystem")
```

---

## 7. Test Plan

### Tests that must pass after Phase 1

```bash
lune run lune/smoke.luau
```

Expected output:
```
smoke passed: FreeDOS reached RUNNING with diagnostics 12/12
boot diagnostics: 12/12 passed
  pic [smoke] PASS
  pit [smoke] PASS
  vga [smoke] PASS
  keyboard [smoke] PASS
  rtc [smoke] PASS
  serial [smoke] PASS
  ide [smoke] PASS
  fdc [smoke] PASS
  protected_mode_smoke [smoke] PASS
```

---

## 8. File Mapping

| Current | Phase 1 Target |
|-------------|----------------|
| platforms/x86/Cpu8086.luau | cpu/Cpu8086.luau |
| platforms/x86/Cpu80386.luau | cpu/Cpu80386.luau |
| platforms/x86/devices/SystemBus.luau | bus/SystemBus.luau |
| platforms/x86/devices/PhysicalMemory.luau | bus/Memory.luau |
| platforms/x86/devices/Pic8259.luau | devices/pic8259.luau |
| platforms/x86/devices/Pit8254.luau | devices/pit8253.luau |
| platforms/x86/devices/I8042Controller.luau | devices/keyboard8042.luau |
| platforms/x86/devices/VgaAdapter.luau | graphics/vga.luau |
| platforms/x86/devices/Fdc765.luau | storage/fdc765.luau |
| platforms/x86/devices/AtaController.luau | storage/ide.luau |
| platforms/x86/BiosRom.luau | bios/BiosRom.luau |
| platforms/x86/BiosInterrupts.luau | bios/InterruptHandler.luau |
| platforms/x86/Assembler8086.luau | assembler/Asm8086.luau |
| platforms/x86/PcSystem.luau | (replaced by machine.luau) |