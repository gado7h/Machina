# Bundle Artifacts

Tagged Machina workflows upload one bundle artifact containing two supported package archives:

- `machina-luau-<version>.tar.gz`
- `machina-roblox-<version>.tar.gz`

Each tagged artifact also contains:

- `machina-release-metadata-<version>.json`
- `machina-release-checksums-<version>.txt`

## machina-luau

Contents:

- `package-manifest.json`
- `src/Config.luau`
- `src/platform/**`
- `src/platforms/**`

This is the host-neutral Luau package for `machina-web` and other non-Roblox Luau consumers.

## machina-roblox

Contents:

- `package-manifest.json`
- `init.luau`
- `src/Config.luau`
- `src/platform/**`
- `src/platforms/**`

The package preserves the public `src/...` tree, but its internal requires are rewritten into Roblox-compatible instance requires. `init.luau` exposes `requireById(...)` plus the documented entry modules.
