# AGENTS.md

## Project Overview
- This repository contains `mht2webarchive`, a small macOS Swift CLI that converts `MHT` / `MHTML` files into Safari-compatible `.webarchive` files.
- The package targets macOS 13+ and Swift 6.3.
- Primary package definition lives in `Package.swift`.

## Repository Layout
- `Sources/` contains the Swift library and CLI targets.
- `Tests/mht2webarchiveTests/` contains the integration-style executable test target.
- `README.md` documents supported usage and expected CLI behavior.

## Working Guidelines
- Keep changes narrow and consistent with the existing Swift Package Manager layout.
- Prefer fixing behavior in the relevant library or CLI target instead of adding ad hoc wrappers.
- Preserve the current product and target names unless a task explicitly requires renaming.
- Avoid introducing new dependencies unless there is a clear need.

## Build And Test
- Build with `swift build`.
- Run the integration test target with `swift run mht2webarchiveIntegrationTests`.
- When changing CLI behavior, update `README.md` examples if they become stale.

## Output And Fixtures
- Do not commit generated `.webarchive` outputs or temporary fixture artifacts.
- Reuse existing fixtures under `Tests/mht2webarchiveTests/Fixtures` when adding coverage.

## Agent Notes
- Check for nested `AGENTS.md` files before editing files in subdirectories.
- Favor `rg` for code search and keep file reads scoped to the relevant area.
