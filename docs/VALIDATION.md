# Validation Guide

## Purpose

This document defines the guest-visible validation path for Machina's x86 target.

## Local Commands

Use the project-local Lune scripts for day-to-day validation:

- `lune run smoke` boots the default `bootOS` image, waits for `RUNNING`, and requires the boot record diagnostics to pass.
- `lune run review` runs `HardwareDiagnostics.runReviewSuite()` and prints the final `passedCount/totalCount` summary.

The goal is to keep the review story separate from the boot-time smoke story:

- `HardwareDiagnostics.run()` is boot-safe and stays focused on fast device smoke checks.
- `HardwareDiagnostics.runGuestRuntimeValidations()` runs the runtime guest images.
- `HardwareDiagnostics.runGuestCPUValidations()` runs the CPU-focused guest images.
- `HardwareDiagnostics.runReviewSuite()` is the canonical review entry point and combines base diagnostics plus runtime and CPU validations.
- `HardwareDiagnostics.runCompatibilitySuite()` is the stricter compatibility gate and combines the review suite plus media-specific compatibility images.

`protected_mode_smoke` remains smoke-only. It is useful for a quick sanity check, but it is not enough evidence to close a fidelity issue on its own.

## Required Evidence

A fidelity PR or issue close-out should include:

- a passing `HardwareDiagnostics.runReviewSuite()` result
- a passing `HardwareDiagnostics.runCompatibilitySuite()` result for media, geometry, or machine-profile work
- the final `passedCount/totalCount` summary
- the specific guest validation names and PASS strings listed below
- any remaining limitations documented explicitly, not left implicit

If a validation fails, the failure text should be treated as part of the evidence trail. Do not rely on smoke-only output to justify a hardware-fidelity claim.

## Guest Validation Images

| Image | Entry Point | Expected PASS String | Purpose |
| --- | --- | --- | --- |
| `ResetVectorValidation` | `runGuestRuntimeValidations` / `runReviewSuite` | `reset vector validation PASS` | Confirms the machine reaches the reset-vector boot path and can print through BIOS teletype. |
| `BiosBootValidation` | `runGuestRuntimeValidations` / `runReviewSuite` | `bios boot validation PASS` | Confirms BIOS boot handoff into a loaded boot image. |
| `InterruptIntegrationValidation` | `runGuestRuntimeValidations` / `runReviewSuite` | `interrupt integration validation PASS` | Confirms BIOS boot, PIC/PIT wiring, and IRQ-driven guest progress. |
| `CpuProtectedModeValidation` | `runGuestCPUValidations` / `runReviewSuite` | `cpu pm validation PASS` | Confirms protected-mode bring-up and a basic interrupt path in protected mode. |
| `CpuExceptionValidation` | `runGuestCPUValidations` / `runReviewSuite` | `cpu exception validation PASS` | Confirms a protected-mode exception path reaches the guest handler. |
| `PrivilegeTransitionValidation` | `runGuestCPUValidations` / `runReviewSuite` | `privilege transition validation PASS` | Confirms a ring-3 software `INT` enters a ring-0 interrupt gate through the loaded TSS stack and returns with `IRET`. |
| `CompatibilityFloppyBootValidation` | `runCompatibilitySuite` | `compat floppy boot PASS` | Confirms BIOS boot from floppy media through the modeled floppy path. |
| `CompatibilityAtaBootValidation` | `runCompatibilitySuite` | `compat ata boot PASS` | Confirms BIOS boot from ATA media through the modeled ATA path. |
| `CompatibilityFloppyGeometryValidation` | `runCompatibilitySuite` | `compat floppy geometry PASS` | Confirms `INT 13h AH=08h` reports the locked floppy geometry truthfully. |
| `CompatibilityMachineProfileValidation` | `runCompatibilitySuite` | `compat machine profile PASS` | Confirms `INT 11h`, `INT 12h`, and CMOS floppy reporting match the locked machine profile. |

## Interpretation Notes

- The runtime images are intended to prove that reset, BIOS, boot handoff, and interrupt delivery work through guest-visible hardware state.
- The CPU images are intended to prove that protected-mode entry, exceptions, and privilege-sensitive control transfers are not just smoke-tested locally.
- `PrivilegeTransitionValidation` is the evidence path for TSS-backed ring transitions on interrupt and `IRET`.
- Full hardware task switching remains out of scope; task gates and TSS task switches should fault architecturally instead of silently succeeding.

## Review Rule

Do not close a fidelity issue just because the emulator boots and the smoke test passes. The review gate is:

1. `HardwareDiagnostics.runReviewSuite()` passes.
2. `HardwareDiagnostics.runCompatibilitySuite()` passes for media, BIOS, CMOS, or machine-profile changes.
3. The PASS strings above are observed.
4. The limitations section in the target documentation still matches reality.

That keeps the review evidence tied to actual guest-visible behavior instead of host-side shortcuts.
