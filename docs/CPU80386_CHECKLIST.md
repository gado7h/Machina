# CPU80386 Checklist

## Purpose

This checklist tracks the `80386` CPU behaviors Machina treats as in scope for the current baseline x86 target.

## In Scope

- real-mode reset at `F000:FFF0`
- BIOS-era `16`-bit boot execution
- operand-size and address-size behavior used by the active guest validations
- protected-mode entry through `LGDT`, `LIDT`, `LMSW`, and far transfer into a code segment
- protected-mode interrupt and exception dispatch through the IDT
- far control transfers used by the machine target:
  - immediate and memory far `CALL`
  - immediate and memory far `JMP`
  - `RETF`
  - `IRET`
- descriptor validation and architectural faults for the implemented control-transfer paths
- `LTR` and `32`-bit TSS loading needed for interrupt-driven privilege transitions
- TSS-backed stack switching for interrupt gates that move from ring `3` to ring `0`
- `IRET` return from ring `0` back to ring `3`

## Out Of Scope

- paging
- virtual-8086 mode
- hardware task switching
- task gates that actually switch tasks
- full user-mode ABI support beyond the validation harness

## Acceptance Notes

Phase acceptance for CPU fidelity should be backed by:

- `CpuProtectedModeValidation`
- `CpuExceptionValidation`
- `PrivilegeTransitionValidation`

These validations are run through `HardwareDiagnostics.runGuestCPUValidations()` and `HardwareDiagnostics.runReviewSuite()`.
