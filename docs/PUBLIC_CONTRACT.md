# Public Contract

Machina is consumed through stable `src/...` module IDs and versioned bundle artifacts, not through repo-local source layout details.

## Stable Module IDs

- `src/Config`
- `src/platform/...`
- `src/platforms/...`

These IDs are the public contract for Luau consumers and package manifests.

## Stable Entry Points

- `src/Config`
- `src/platforms/x86/PcSystem`
- `src/platform/Contracts`

## Host Boundary

Shared Machina source and published packages must not reference:

- `script.Parent`
- `game:GetService(...)`
- `Instance.new(...)`
- host remotes, persistence, or UI code

Host repos are responsible for adapting Machina to their runtime.

## Published Packages

Tagged workflows publish package archives for:

- `machina-luau`
- `machina-roblox`

Each package includes a `package-manifest.json` with package metadata, stable entrypoints, and a `modules` map keyed by `src/...` IDs.
