# Machina

[![Language](https://img.shields.io/badge/language-Luau-00A2FF?style=flat-square)](https://luau-lang.org/)
[![Runtime](https://img.shields.io/badge/runtime-host--neutral-4B5563?style=flat-square)]()
[![Status](https://img.shields.io/badge/status-active-brightgreen?style=flat-square)]()

Machina is a host-neutral IBM PC-compatible emulator core implemented in Luau.

It currently targets a BIOS-era 80386/486-class machine and is designed to be embedded by downstream hosts instead of owning the browser, Roblox, or platform runtime itself.

---

## Refactor roadmap (QEMU-style architecture, Luau-friendly)

This plan moves Machina toward a structure inspired by mature emulators (QEMU/Bochs/PCem style separation), while keeping runtime compatibility with Roblox, Lune, and web hosts.

### Primary goals

1. **Accuracy where it matters**: deterministic CPU/memory/device behavior for FreeDOS first, then Windows 3.11/95 milestones.
2. **Usability and maintainability**: clear module boundaries, stable APIs, and predictable file naming.
3. **Performance discipline**: profile-driven improvements without sacrificing correctness.

### Guiding architecture principles

- **Machine composition over monoliths**: machine = CPU + buses + memory map + chipset + devices.
- **Target/platform separation**: x86 implementation isolated from host glue.
- **Backend abstraction**: block, display, input, timer backends injected by host.
- **Deterministic stepping model**: explicit cycles/ticks/event queue for reproducible boots.
- **Testability by layer**: unit tests for components, integration tests for boot flow.

### Proposed module layout

```text
src/
  core/
    scheduler/
    tracing/
    config/
    runtime/
  target/
    x86/
      cpu/
      decode/
      mmu/
      interrupt/
      machine/
      chipset/
      devices/
      firmware/
  backends/
    block/
    display/
    input/
    time/
  validation/
    unit/
    integration/
    boot/
```

### Naming and API normalization plan

Use consistent technical naming to remove ambiguity:

- **`PcSystem` → `X86Machine`** (top-level machine orchestrator)
- **`Cpu80386`/`Cpu8086` → `X86Cpu` + mode/state submodules**
- **`PhysicalMemory` → `MemorySpace`**
- **`SystemBus` → `IoBus`**
- **`BiosInterrupts` → `BiosIntDispatcher`**
- **`BootController` → `BootManager`**
- **`HardwareDiagnostics` → `PowerOnSelfTest`**

Additional naming rules:

- file names use **PascalCase.luau** for modules exporting objects/classes,
- helper/internal modules use **camelCase.luau**,
- folders are domain-first (`cpu/`, `chipset/`, `devices/`, `firmware/`),
- no mixed role files (each file should own one subsystem concern).

### Implemented baseline in this repository

The repository now includes an initial emulator-centric API layer to support ongoing refactors without breaking existing x86 internals:

- `src/Machina.luau` — top-level package API (`createEmulator`, `availableTargets`, `packageManifest`)
- `src/core/EmulatorBuilder.luau` — target registry and target construction
- `src/core/ConfigMerge.luau` — reusable deep merge for machine presets + overrides
- `src/targets/x86/i486/I486Configuration.luau` — i486 preset profile
- `src/targets/x86/i486/I486Emulator.luau` — i486 machine wrapper backed by current `PcSystem`
- `src/packaging/PackageManifest.luau` — packaging metadata entrypoint for host integrations

This provides a QEMU-style direction (target + machine wrappers + packaging metadata) while preserving runtime compatibility with existing components.

### Phase-by-phase execution

#### Phase 0 — Baseline and freeze (short)

- Lock current FreeDOS boot behavior as baseline.
- Add deterministic snapshot capture of boot stage transitions.
- Define performance budget (target cycles/sec on Lune and Roblox).

#### Phase 1 — Structural split

- Introduce `target/x86/` tree while keeping compatibility shims.
- Move CPU, bus, memory, and device models into isolated modules.
- Keep old paths as forwarding requires until migration is complete.

#### Phase 2 — CPU core cleanup

- Separate decode, execution, flags, and exceptions.
- Add explicit execution context object (`CpuContext`) passed to opcode handlers.
- Build an opcode conformance table for 8086→386 subset needed by FreeDOS.

#### Phase 3 — Memory and I/O model

- Replace ad-hoc access with region-based mapping (`MemoryRegion`).
- Centralize I/O dispatch with port registration and callbacks.
- Add instrumentation hooks for memory/IO tracing.

#### Phase 4 — Device/chipset boundaries

- Model PIC/PIT/RTC/FDC/ATA with consistent device interface:
  - `reset()`, `readPort()`, `writePort()`, `tick(cycles)`, `getState()`.
- Move BIOS services behind dispatcher abstraction.
- Standardize DMA/IRQ signaling paths.

#### Phase 5 — Validation and tooling

- Keep the global validation entrypoint and add layered suites:
  - component validation,
  - boot path validation,
  - trace consistency validation.
- Add golden trace comparisons for critical FreeDOS bootstrap windows.

#### Phase 6 — Pentium-era prep (post-FreeDOS stability)

- Start i486/Pentium feature-gated extensions (paging improvements, CPUID, etc.).
- Add optional accelerated execution paths only after correctness gates pass.
- Expand boot matrix to Windows 3.11 and Windows 95 milestones.

### Milestone gates

- **M1**: FreeDOS boots to stable command prompt with deterministic boot record.
- **M2**: Global validation passes consistently on Lune and Roblox host harness.
- **M3**: CPU opcode coverage reaches required 386 subset for DOS + HIMEM/EMM scenarios.
- **M4**: Windows 3.11 setup boot sequence reaches installer UI.
- **M5**: Windows 95 protected-mode bootstrap begins reliably.

### Risk controls

- Keep a migration compatibility layer during renames.
- Require each refactor PR to include:
  - before/after validation output,
  - changed subsystem scope,
  - rollback notes.
- Avoid performance tuning before deterministic correctness is proven.

---

## Emulator API quickstart

```luau
local Machina = require("@src/Machina")

local emulator = Machina.createEmulator({
    target = "x86-i486-pc",
    config = {
        X86 = {
            TRACE = { ENABLED = true, CPU_STATE = true },
        },
    },
})

emulator:setFramePresenter(function(frame)
    -- host-specific frame handling
end)

emulator:powerOn()
```

## Local toolchain (Rokit)

Machina uses [Rokit](https://github.com/rojo-rbx/rokit) to pin developer tooling.

1. Install Rokit.
2. Install tools declared in `rokit.toml`.
3. Run tools through Rokit shims.

Example commands:

```bash
rokit install
rokit run selene --version
rokit run stylua --version
rokit run luau-lsp --help
rokit run lune --version
```

## Validation workflow

A single global validation script replaces fragmented ad-hoc checks.

```bash
rokit run lune run lune/validation/global_validation.luau
```

This script runs:

- Boot validation (FreeDOS reaches `RUNNING`)
- Trace validation (trace-enabled boot still reaches `RUNNING`)
- Hardware diagnostics validation (boot diagnostics suite passes)

## Linting and formatting

```bash
rokit run selene src lune tools
rokit run stylua --check src lune tools
```
