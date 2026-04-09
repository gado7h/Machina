# FreeDOS Boot Issue Investigation

## Overview

This document details the investigation into FreeDOS boot failure in the Machina x86 emulator. It covers the diagnostic logging implementation, identified suspects, and recommended fix strategies.

## Background

The emulator is a pure emulation system (not host-driven). All disk I/O goes through emulated BIOS interrupts (INT 13h), and the emulated CPU executes the FreeDOS boot sector directly.

### FreeDOS Boot Flow

```
1. BIOS loads boot sector to 0x7C00
2. Boot sector executes and prints "FreeDOS" via INT 10h
3. Boot sector checks for keypress (INT 16h AH=01h) to skip CONFIG.SYS
4. If no key, loads kernel from disk via INT 13h
5. Jumps to kernel at 0x07C0:0000
```

## Implemented Diagnostics

### 1. CPU Boot Sector Execution Trace

**Files Modified:**
- `src/platforms/x86/Cpu8086.luau` (~line 1000)
- `src/platforms/x86/Cpu80386.luau` (~line 1922)

**Purpose:** Log every instruction executed in the boot sector area (0x7C00-0x8000) to identify tight loops.

**Code:**
```lua
if self._trace and self._trace.CPU_STATE then
    local linear = self:linearAddress(self.seg.CS, self.ip)
    if linear >= 0x7C00 and linear < 0x8000 then
        self.bus:_log("CPU", string.format("%04X:%04X (%05X) op=%02X", 
            self.seg.CS, self.ip, linear, opcode))
    end
end
```

**Expected Output:**
```
BOOT: 0000:7C00 (07C00) op=EB
BOOT: 0000:7C02 (07C02) op=3C
...
```

### 2. INT 16h (Keyboard) Status Check Trace

**File Modified:** `src/platforms/x86/BiosInterrupts.luau` (~line 741)

**Purpose:** Trace keyboard status checks (AH=01h) to detect if keyboard falsely reports key available.

**Code:**
```lua
self:_traceLog("BIOS_CALLS", string.format("INT16 AH=01h ZF=%d", ch and 0 or 1))
```

**Expected Output:**
```
BIOS: INT16 AH=01h ZF=1  (no key pressed - correct)
BIOS: INT16 AH=01h ZF=0  (key pressed)
```

**If Problem:** Seeing ZF=0 repeatedly indicates keyboard is falsely reporting keys.

### 3. PIT IRQ Rate Monitor

**File Modified:** `src/platforms/x86/devices/Pit8254.luau` (~line 259)

**Purpose:** Monitor timer interrupt rate to detect if PIT fires too rapidly.

**Code:**
```lua
if self.stats.irqs % 1000 == 0 then
    self._bus:_log("PIT", string.format("IRQ rate: %d total IRQs fired", self.stats.irqs))
end
```

**Expected Output:**
```
PIT: IRQ rate: 1000 total IRQs fired  (~18.2 IRQs/sec)
```

**If Problem:** Seeing rapid IRQ counts indicates PIT timing is off.

### 4. INT 10h (Video) Character Output Trace

**File Modified:** `src/platforms/x86/BiosInterrupts.luau` (~line 172)

**Purpose:** Trace character output to detect printing loops.

**Code:**
```lua
self:_traceLog("BIOS_CALLS", string.format("INT10 AH=0Eh AL='%s' (%02X)", 
    ch ~= 0 and string.char(ch) or "?", ch))
```

**Expected Output:**
```
BIOS: INT10 AH=0Eh AL='F' (46)
BIOS: INT10 AH=0Eh AL='r' (72)
...
```

**If Problem:** Seeing same character repeatedly indicates an infinite loop.

## Suspected Culprits (In Probability Order)

### 1. Keyboard Status Always "Key Ready" (HIGH PRIORITY)

**Symptom:** FreeDOS boot sector checks for keypress (INT 16h AH=01h) to optionally skip CONFIG.SYS. If emulator always reports a key available, boot sector enters a "print and wait" loop.

**Check:** In `BiosInterrupts:_keyboardInterrupt` (AH=01h), verify `peekChar()` returns nil when keyboard buffer is empty.

**Files:** 
- `src/platforms/x86/devices/I8042Controller.luau` - `peekChar()` function
- `src/platforms/x86/devices/I8042Controller.luau` - `_readStatus()` function

### 2. IRET Flag Not Restored (MEDIUM PRIORITY)

**Symptom:** If IRET fails to re-enable interrupts (IF stays 0), boot sector may rely on polling loops that get stuck.

**Check:** In `Cpu80386:_returnFar()` and `Cpu8086:step()` IRET handler, verify flags are popped after CS:IP with reserved bit (0x0002) forced set.

**Files:**
- `src/platforms/x86/Cpu80386.luau` - `_returnFar()` function (~line 1718)
- `src/platforms/x86/Cpu8086.luau` - IRET opcode handling

### 3. Timer Interrupt (IRQ0) Firing Too Fast (MEDIUM PRIORITY)

**Symptom:** If PIT is misconfigured, INT 08h may trigger hundreds of times per second. BIOS tick handlers may call INT 10h to update cursor, causing spurious output.

**Check:** Verify `Pit8254:_tickChannel0()` uses correct divisor and fires at ~18.2 Hz.

**Files:**
- `src/platforms/x86/devices/Pit8254.luau` - `_tickChannel0()` function (~line 262)

### 4. String Instruction Direction Flag Bug (LOW PRIORITY)

**Symptom:** Boot sector uses REP MOVSW to relocate itself. If DF is not handled correctly, copy may corrupt code creating an unintended loop.

**Check:** In `Cpu8086:_executeStringOp()`, verify CX decrements correctly and DF handling.

**Files:**
- `src/platforms/x86/Cpu8086.luau` - `_executeStringOp()` function (~line 817)

### 5. Segment Wrap / A20 Masking (LOW PRIORITY)

**Symptom:** Boot sector relocates to 1FE0:0000 using RETF after CBW trick. If linear address calculation is wrong, jump lands in wrong place.

**Check:** Verify `Cpu8086:linearAddress()` correctly applies A20 mask.

**Files:**
- `src/platforms/x86/Cpu8086.luau` - `linearAddress()` function

## Enabling Diagnostics

To use these traces, enable CPU state tracing in configuration:

```lua
X86 = {
    -- ... existing config ...
    TRACE = {
        ENABLED = true,
        CPU_STATE = true,
        BIOS_CALLS = true,
        DISK = true,
    },
}
```

## Quick Workaround for Testing

Force boot to use ATA (hard disk) instead of floppy:

```lua
X86 = {
    BOOT_DRIVE = 0x80,
    BOOT_ORDER = {"ata"},
}
```

Then ensure FreeDOS image is written to HDD sectors in `BootController:_loadBootMedia()`.

## Related Source Files

| File | Purpose |
|------|---------|
| `src/platforms/x86/FreeDOSBootHex.luau` | FreeDOS 1.4MB floppy image as hex bytes |
| `src/platforms/x86/BootImageCatalogProductionImages.luau` | Builds FreeDOS boot image |
| `src/platforms/x86/BootController.luau` | Boot sequence orchestration |
| `src/platforms/x86/BootImageLoader.luau` | Image loading logic |
| `src/platforms/x86/BiosInterrupts.luau` | BIOS INT 10h, 13h, 16h implementations |
| `src/platforms/x86/devices/Fdc765.luau` | Floppy disk controller |
| `src/platforms/x86/devices/AtaController.luau` | ATA/IDE controller |
| `src/platforms/x86/devices/Pit8254.luau` | Programmable Interval Timer |
| `src/platforms/x86/devices/I8042Controller.luau` | Keyboard controller |
| `src/platforms/x86/Cpu8086.luau` | 8086 CPU implementation |
| `src/platforms/x86/Cpu80386.luau` | 80386 CPU implementation |
| `src/platforms/x86/PcSystem.luau` | Main system runtime |

## Future Fixes

Once the exact failure point is identified through diagnostics, implement fixes in the following priority:

1. Fix keyboard `peekChar()` to return nil when buffer empty
2. Verify IRET properly restores Interrupt Flag (IF)
3. Calibrate PIT timer to fire at correct rate (~18.2 Hz)
4. Verify string operations handle Direction Flag correctly
5. Verify A20 line masking in linear address calculation