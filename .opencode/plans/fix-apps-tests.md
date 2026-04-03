# Fix: Apps failing across all hosts (emulator core issues)

## Problem
90% of bootOS apps fail across ALL hosts (Roblox, Lune, etc.). Three failure categories:
- **Graphics mode not detected** (fbird, bricks) — apps don't launch or stay in TEXT mode
- **Screen frozen** (invaders, cubicdoom, snake, tetranflix, mine, sokoban, counter, textmode, bootslide, heart) — apps launch but freeze
- **All black frames** (rogue, basic, textmode, atomchess, pi) — apps launch but don't render

## Current State
- **pillman** is the ONLY app that works (1/17)
- pillman immediately switches to MODE13 and runs continuously
- All other apps either stay in TEXT mode or freeze

## Root Cause Analysis

### Key Finding: Apps freeze at specific IPs in bootOS binary

From debug tracing:
- **fbird**: Shows "F-BIRD" title in TEXT mode, then freezes at IP=0x7C42
  - Code at 0x7C42: `MOV AX,0x0E20; STOSW; LODSW; CMP SI,0x0FA2; JNE -0x10` — teletype output loop
  - After Space key: progresses to nonSpace=268 then freezes again at 0x7C42
  - Never switches to graphics mode (stays biosMode=0x02)

- **counter**: Shows "$counter" then "*06" then returns to "$" — command executes but app exits immediately

- **pillman**: Immediately switches to MODE13, runs at IP ~0x7C56-0x7C75 continuously

### The Real Issue: INT 0x16 AH=00 spin loop

When INT 16h AH=00 (blocking keyboard read) has no key available:
1. `_repeatSoftwareInterrupt()` rewrites return IP on stack to point back to INT instruction
2. Handler returns, CPU re-executes INT 0x16
3. No key available → rewind again → infinite spin loop

This spin loop consumes ALL CPU steps. The app can't progress because it's stuck waiting for keyboard input that never arrives (or arrives but the app is in a tight spin loop).

### Why pillman works but others don't

pillman likely:
- Doesn't use blocking keyboard reads (INT 0x16 AH=00)
- Uses non-blocking reads (INT 0x16 AH=01) instead
- Or has a different initialization path that doesn't wait for input

Other apps likely:
- Use INT 0x16 AH=00 to wait for key press (e.g., "Press any key to start")
- Get stuck in the spin loop because no key is available
- Never reach their main game loop

### I8042 scancode processing issue

When IRQ1 fires:
1. INT 0x09 handler reads ONE scancode from port 0x60
2. Sends EOI to PIC
3. Returns
4. Remaining scancodes sit in I8042 buffer with no IRQ pending

This means multi-byte scan codes (like arrow keys with 0xE0 prefix) may not be fully processed.

## Fixes Applied So Far

1. **scanCodeForChar** — Built proper character-to-scancode map (was returning 0 for all chars)
2. **I8042 _readData** — Re-raise IRQ if buffer still has data after reading
3. **Keyboard.typeAll** — Added new function to inject all chars at once

## Remaining Fixes Needed

### Fix 1: INT 0x16 AH=00 should not spin-loop when no key available

**File:** `src/platforms/x86/BiosInterrupts.luau:647-662`

Current behavior: When no key available, rewrites return IP to retry INT 0x16 → infinite spin loop.

**Fix:** Instead of rewinding, return AL=0, AH=0 (no key) with Zero Flag set. This lets the guest OS handle the "no key" case properly. Real BIOS INT 0x16 AH=00 blocks, but in emulation we should return "no key" and let the guest's scheduler handle waiting.

However, this broke everything when tried before — bootOS relies on the blocking behavior. The issue is that bootOS's shell uses INT 0x16 AH=00 as a blocking read, and if we return "no key", the shell treats it as NUL and processes it as input.

**Better fix:** Check if there are pending scancodes in the I8042 buffer. If so, don't rewind — just return and let the next CPU step process the pending IRQ. The INT 0x09 handler will read the scancode and store it in the ASCII buffer. On the next INT 0x16 call, the key will be available.

### Fix 2: Ensure INT 0x09 processes all pending scancodes

The BIOS INT 0x09 handler (in the guest's IVT, which points to the ROM's DEFAULT_INT_HANDLER = just IRET) doesn't actually process scancodes. The scancode processing is done by the I8042's `_translateASCII()` which is called from `keyDown()`.

So the flow is:
1. `keyDown('F')` → scancode queued, ASCII 'f' stored in `_ascii` buffer
2. IRQ1 fires → INT 0x09 handler (IRET) does nothing
3. INT 0x16 AH=00 → reads 'f' from `_ascii` buffer → returns it

This should work! The ASCII buffer is populated by `keyDown()`, not by INT 0x09. So the issue must be elsewhere.

### Fix 3: Investigate why apps freeze at specific IPs

From debug output:
- fbird freezes at IP=0x7C42 which is a teletype output loop
- The loop draws text character by character using INT 0x10 AH=0E
- After drawing, it reads the PIT for timing
- Then it waits for keyboard input

The issue might be:
1. INT 0x10 AH=0E (teletype) is slow or broken
2. PIT timing is wrong
3. Keyboard input handling is broken

### Fix 4: Check INT 0x10 AH=0E (teletype) implementation

**File:** `src/platforms/x86/BiosInterrupts.luau:_teletype()`

If teletype is broken, apps can't draw their title screens and may hang.

### Fix 5: Check PIT interrupt delivery

The PIT should fire IRQ0 at ~18.2 Hz. If interrupts aren't delivered, apps that wait for timer ticks will hang.

## Next Steps

1. Add debug tracing to understand exactly what fbird is doing at IP=0x7C42
2. Check if INT 0x10 AH=0E is working correctly
3. Check if PIT interrupts are being delivered
4. Compare fbird's execution path with pillman's to find the divergence point
