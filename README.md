# Machina

[![Language](https://img.shields.io/badge/language-Luau-00A2FF?style=flat-square)](https://luau-lang.org/)
[![Runtime](https://img.shields.io/badge/runtime-host--neutral-4B5563?style=flat-square)]()
[![Status](https://img.shields.io/badge/status-active-brightgreen?style=flat-square)]()

Machina is a host-neutral IBM PC-compatible emulator core implemented in Luau.

It targets a BIOS-era 80386-class machine and is designed to be embedded by downstream hosts instead of owning the browser, Roblox, or platform runtime itself.

## Repository Layout

- `src/` contains the emulator core and published Luau modules.
- `docs/` contains the public package and host-consumption contracts.
- `lune/` contains local developer validation entry points.
- `tools/` contains repository build and release helpers.

## Local Development

Install the toolchain with `rokit install --no-trust-check`.

Core checks:

- `selene --allow-warnings src lune`
- `stylua --check src lune`

Developer validation:

- `lune run smoke`
- `lune run review`

The Lune validation commands are kept as developer workflows for now. They expose real emulator diagnostics and are available through the separate validation workflow, but they are not currently part of the blocking packaging or release path.

## Published Artifacts

Tagged workflows publish:

- `machina-luau-<version>.tar.gz`
- `machina-roblox-<version>.tar.gz`
- `machina-release-metadata-<version>.json`
- `machina-release-checksums-<version>.txt`

Consumer-facing details live in:

- `docs/PUBLIC_CONTRACT.md`
- `docs/VENDORING.md`
- `docs/WEB_HOST_CONTRACT.md`
- `docs/ROBLOX_HOST_CONTRACT.md`
