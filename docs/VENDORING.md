# Vendoring

Host repos should vendor tagged Machina bundle artifacts, not depend on Machina source layout or repo-local `dist/**` output.

## Recommended Flow

1. Create or locate a tagged Machina workflow run.
2. Download the uploaded `machina-bundles-<version>` artifact from that run.
3. Use the artifact contents:
   - `machina-roblox-<version>.tar.gz` for `machina-roblox`
   - `machina-luau-<version>.tar.gz` for `machina-web`
   - `machina-release-metadata-<version>.json` for checksum verification
4. Verify the archive SHA-256 against the metadata file.
5. Extract the chosen package into `vendor/machina`.
6. Record the imported Machina version in the vendored directory.
7. Treat vendored files as read-only except during version updates.

## Supported Update Path

Host repos should own their own import/update scripts to verify and extract a downloaded bundle artifact.

- `machina-roblox` should script imports of the `machina-roblox` archive from the downloaded artifact directory.
- `machina-web` should script imports of the `machina-luau` archive from the downloaded artifact directory.

This repository publishes the archives and metadata, but it does not ship downstream starter templates or import scripts anymore. Manual copy/paste is intentionally undocumented.

## Host Repo Ownership

`machina-roblox` owns:

- Rojo config
- Roblox host scripts
- UI and presentation
- remotes, persistence, and runtime adapters

`machina-web` owns:

- browser loader/embedder
- UI shell
- platform adapters
- deployment and packaging

## Related Contracts

- `docs/WEB_HOST_CONTRACT.md` documents the web-host expectations.
- `docs/ROBLOX_HOST_CONTRACT.md` documents the Roblox-host expectations.
