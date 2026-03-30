# Web Host Contract

`machina-luau` is the supported Machina package for `machina-web`, delivered inside the tagged Machina bundle artifact.

## Package Shape

The package contains:

- `package-manifest.json`
- `src/**`

The manifest contains:

- `format`
- `package`
- `version`
- `gitRef`
- `entrypoints`
- `modules`

`modules` maps canonical IDs such as `src/platforms/x86/PcSystem` to files inside the package tree.

## Loader Responsibilities

`machina-web` must provide:

- a Luau embedder/runtime
- a module loader keyed by canonical IDs
- module caching semantics
- platform adapters for timing, frame presentation, input, and optional persistence

Machina does not provide the browser runtime in this repo. `machina-web` should consume the published `machina-luau` archive from the tagged workflow artifact and add its own browser-specific loader and runtime wiring.
