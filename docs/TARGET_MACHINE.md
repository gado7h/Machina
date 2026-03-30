# Machina Target Machine

## Purpose

This document locks the active emulator target for Machina and defines the acceptance bar for hardware fidelity.

The goal is not "generic PC-like behavior." The goal is a narrow, BIOS-era IBM PC compatible machine that guest software can program through the expected registers, memory layout, and interrupt paths.

This document is the authoritative scope for emulator work. If a change does not help this target, it should be treated as out of scope unless the target is revised explicitly.

## Locked Target

Machina targets a baseline BIOS-era `80386` PC with:

- `80386`-class CPU
- BIOS boot flow
- dual `8259A` PIC interrupt controller
- `8254` PIT
- one `1.44 MB` floppy drive at `A:`
- primary-channel ATA disk
- `8042` keyboard controller
- RTC/CMOS
- COM1 UART
- baseline IBM VGA-compatible display adapter

The intended software environment is a narrow, early-PC-compatible machine suitable for BIOS boot, real-mode bring-up, protected-mode transition, and eventually small real kernels and Linux-oriented experiments.

## Scope Boundaries

### In Scope

- real-mode reset at `F000:FFF0`
- BIOS interrupt-driven boot
- low memory layout below `1 MiB`
- port-mapped ISA-era peripherals
- text mode and standard VGA graphics programming
- protected-mode `80386` execution
- TSS-backed ring transitions for interrupt and IRET flows used by the validation harness
- timing behavior that is stable enough for real guest software to poll and use

### Explicitly Out of Scope

- PCI
- ACPI
- APIC / IOAPIC
- VBE / SVGA / accelerated graphics
- modern chipsets and buses
- cycle-perfect analog VGA timing
- exact board-vendor quirks outside the locked baseline target
- full hardware task switching / TSS task switching

## What "Faithful" Means

For this project, a subsystem is considered faithful when it is:

- register-correct
- memory-layout-correct
- interrupt-correct
- timing-correct enough for real software

Machina is **not** targeting cycle-perfect analog hardware recreation. The acceptance bar is software-visible correctness for the locked target machine, not transistor-accurate reconstruction.

## Validation Contract

Guest-visible validation evidence is defined in [docs/VALIDATION.md](./VALIDATION.md).

`HardwareDiagnostics.runReviewSuite()` is the canonical review entry point for this target. It combines:

- base device smoke diagnostics
- reset vector validation
- BIOS boot validation
- interrupt integration validation
- protected-mode CPU validation
- exception validation
- privilege-transition validation

`HardwareDiagnostics.runCompatibilitySuite()` is the stricter compatibility gate for this target. It extends the review suite with:

- floppy-path guest boot validation
- ATA-path guest boot validation
- BIOS floppy-geometry validation
- machine-profile / CMOS / equipment-word validation

### Register-Correct

The guest sees the correct register surfaces, register indexes, read/write behavior, reset defaults, and side effects that software for the target machine expects.

### Memory-Layout-Correct

The guest sees the correct address ranges, ROM/RAM/video placement, aperture behavior, and device-visible memory aliasing/window behavior expected by the target machine.

### Interrupt-Correct

Interrupt delivery, masking, vector routing, acknowledgement, and end-of-interrupt behavior must match the target contract closely enough that real software can install handlers and rely on them.

### Timing-Correct Enough

Timing does not have to be cycle-perfect, but it must be stable and software-visible in the right ways:

- retrace polling must behave plausibly
- PIT-generated timing must be usable by real code
- keyboard/data-ready status must not be random
- storage completion state must not violate the guest-visible protocol

## Baseline Machine Contract

### CPU

- `80386`-class execution target
- starts in real mode
- supports transition into protected mode
- uses x86 segment:offset addressing in real mode
- exposes descriptor-table and control-register behavior needed for protected-mode bring-up

### Boot

- BIOS ROM mapped at `0xF0000-0xFFFFF`
- reset vector at `F000:FFF0`
- boot sector loaded to `0000:7C00`
- BIOS-owned device services during early boot

### Memory Layout

Current baseline layout:

- low RAM: `0x00000000-0x0009FFFF`
- VGA aperture: `0x000A0000-0x000BFFFF`
- BIOS ROM: `0x000F0000-0x000FFFFF`

This layout is the expected guest-visible machine map unless a later target revision changes it explicitly.

### Interrupt Layout

Baseline PIC vector bases:

- master PIC base: `0x08`
- slave PIC base: `0x70`

Baseline IRQ intent:

- IRQ0: PIT
- IRQ1: keyboard
- IRQ4: COM1
- IRQ8: RTC
- IRQ6: floppy controller
- IRQ14: primary ATA

### Disk Model

- one `1.44 MB` floppy drive `A:` with BIOS-visible CMOS/BDA equipment reporting
- BIOS-era primary ATA channel
- default boot order: `floppy`, then `ata`
- boot drive defaults to `0x00` when the locked profile includes a present floppy drive
- CHS-facing BIOS boot path is acceptable for the target
- guest-visible ATA task-file behavior should match primary-channel expectations

### Display Model

- baseline IBM VGA-compatible register and memory model
- text mode through `0xB8000`
- graphics aperture through `0xA0000-0xBFFFF`
- no dedicated VGA IRQ in the target contract

## Subsystem Coverage Checklist

Each subsystem below has:

- a scope checklist
- a pass/fail acceptance list

Passing a subsystem means the required items are implemented and verified against guest-visible behavior.

### CPU80386

#### Coverage Checklist

- real-mode reset semantics
- `16`-bit instruction decode needed for BIOS boot
- protected-mode entry
- GDT loading and descriptor use
- IDT loading and interrupt dispatch
- operand-size behavior
- address-size behavior
- stack behavior in real and protected mode
- control-register behavior needed for the target
- fault/exception behavior for the implemented instruction set
- protected-mode interrupt and IRET control flow used by the validation harness
- TSS-backed stack switching for the privilege-transition validation path

#### Pass / Fail Acceptance

Pass when:

- BIOS boot code runs from reset vector without host shortcuts
- protected-mode test images can enter protected mode, run, and return/interrupt correctly
- real-mode and protected-mode interrupt handlers execute through CPU state changes that match the target contract
- privilege-sensitive gate and IRET control flow behaves as expected for the locked target
- implemented opcodes behave correctly for width, flags, and addressing mode

Fail when:

- protected-mode execution still depends on host-side shortcuts instead of CPU state transitions
- address-size or operand-size prefixes produce incorrect guest-visible execution
- interrupts or exceptions bypass the modeled CPU contract
- privilege-sensitive control flow silently falls back to host-only behavior

### BIOS

#### Coverage Checklist

- reset entry path
- boot-device loading
- `INT 10h` baseline video services needed by the target
- `INT 13h` disk services needed by the target
- `INT 16h` keyboard services needed by the target
- `INT 1Ah` clock/time services needed by the target
- basic boot handoff to guest code

#### Pass / Fail Acceptance

Pass when:

- a guest boot sector can boot through BIOS services alone
- BIOS video, disk, keyboard, and time services behave consistently with the locked target
- boot handoff uses guest-visible CPU and memory state only

Fail when:

- BIOS behavior secretly depends on host-only shortcuts
- guest-visible register results differ from expected BIOS call conventions

### Memory / ROM Layout

#### Coverage Checklist

- RAM placement
- ROM placement
- VGA aperture placement
- read-only ROM behavior
- unmapped access fault behavior
- little-endian memory helpers where exposed through CPU behavior

#### Pass / Fail Acceptance

Pass when:

- guest software sees the expected address layout
- ROM cannot be modified through normal guest writes
- device windows respond only inside their mapped ranges

Fail when:

- mapped regions alias incorrectly
- ROM mutates under guest writes
- device apertures do not match the locked machine map

### PIC8259

#### Coverage Checklist

- master/slave initialization flow
- IMR, IRR, ISR behavior
- specific and non-specific EOI
- IRQ cascade behavior
- correct vector generation
- masking and priority behavior appropriate to the target

#### Pass / Fail Acceptance

Pass when:

- guest software can initialize the PIC with standard command words
- IRQ delivery reaches the expected vectors
- masking and EOI behavior matches software expectations

Fail when:

- IRQ routing ignores PIC state
- EOI/masking behavior is effectively stubbed

### PIT8254

#### Coverage Checklist

- control-word programming
- channel `0` timer behavior
- reload/divisor behavior
- latch/read sequencing expected by software
- IRQ0 generation through PIC

#### Pass / Fail Acceptance

Pass when:

- guest code can program PIT channel `0` and observe usable periodic timing
- IRQ0 arrives through the PIC path
- status/data reads behave consistently enough for polling software

Fail when:

- PIT control writes are ignored
- timer interrupts do not reflect programmed state

### ATA

#### Coverage Checklist

- primary task-file register surface
- sector read path
- drive/head selection
- status/error signaling
- busy/data-ready semantics
- IRQ14 signaling where appropriate for the target
- BIOS boot read compatibility

#### Pass / Fail Acceptance

Pass when:

- BIOS and guest software can read sectors through standard ATA-facing behavior for the locked target
- task-file register reads and writes affect controller state correctly

Fail when:

- disk access works only through host shortcuts
- status/data protocol is inconsistent with programmed ATA state

### 8042 Keyboard Controller

#### Coverage Checklist

- status register behavior
- data port behavior
- controller command responses
- keyboard ACK/self-test responses used by the target
- scan-code delivery
- BIOS keyboard compatibility
- IRQ1 delivery through PIC

#### Pass / Fail Acceptance

Pass when:

- guest software can poll or interrupt on keyboard input
- BIOS keyboard services work through the modeled controller path
- make/break behavior is stable enough for real software

Fail when:

- guest-visible keyboard state bypasses the 8042 contract
- IRQ1 does not reflect controller state

### VGA

#### Coverage Checklist

- CRTC, sequencer, graphics controller, attribute controller, DAC, and status ports
- text mode `03h`
- planar graphics modes
- chained `13h` behavior
- plane `2` font upload and text rendering
- cursor behavior
- palette/DAC sequencing
- retrace/display-enable polling behavior

#### Pass / Fail Acceptance

Pass when:

- guest software can program VGA registers directly and observe the expected rendering mode
- BIOS video services act only as register programmers/convenience helpers, not as a separate truth model
- bundled guest validation images and manual compatibility checks behave correctly for the locked baseline VGA target

Fail when:

- rendering mode depends on host-side presets instead of guest-programmed register state
- font upload, planar writes, or DAC sequencing differ materially from the target contract

### System Integration

#### Coverage Checklist

- CPU <-> PIC interrupt path
- PIT -> PIC -> CPU path
- keyboard -> PIC -> CPU path
- ATA -> PIC -> CPU path
- VGA memory/register visibility through the memory and I/O maps
- BIOS boot flow from reset to boot sector to guest code

#### Pass / Fail Acceptance

Pass when:

- the machine boots through reset, BIOS, and boot sector using only guest-visible hardware paths
- interrupts reach the CPU through the modeled controller chain
- device programming through ports and memory maps affects the visible machine state correctly

Fail when:

- boot or runtime still depends on host shortcuts that bypass hardware state
- device behavior is individually correct but not integrated through the real machine wiring

## Definition of Done for the Target

The target machine is considered locked and implemented well enough for the current phase when:

- the active platform still matches this document
- every in-scope subsystem has an explicit pass/fail acceptance list
- future work is evaluated against this machine contract instead of a vague "PC-like" goal
- compatibility claims are made against this narrow target, not against modern PC hardware

## Change Control

Changes to the locked target should be rare and explicit.

If Machina ever expands beyond this baseline machine, update this document first and state whether the project is:

- revising the target machine, or
- adding a separate machine profile

Do not silently widen scope from "baseline BIOS-era `80386` PC" to "general modern PC emulator."
