# mht2webarchive

Small macOS CLI that converts `MHT` / `MHTML` files into Safari-compatible `.webarchive` files.

## Build

```bash
swift build
```

## Test

```bash
swift run mht2webarchiveIntegrationTests
```

## Run

```bash
swift run mht2webarchive input.mht
swift run mht2webarchive input.mht -o output.webarchive
cat input.mht | swift run mht2webarchive - -o output.webarchive
cat input.mht | swift run mht2webarchive - -o - > output.webarchive
swift run mht2webarchive --batch inbox/ more.mhtml --output-dir converted
```

## Notes

- Targets macOS and uses WebKit's `WebArchive` / `WebResource` types to emit the archive.
- Supports common transfer encodings: `base64`, `quoted-printable`, `7bit`, `8bit`, and `binary`.
- Resolves relative `Content-Location` values against the snapshot URL when present.
- Batch mode accepts both individual files and directories, and scans directories recursively for `.mht` and `.mhtml`.
- The base MHT parsing and resource resolution logic is provider-agnostic but heuristic, and applies broadly to multipart `MHT` / `MHTML` input.

## Safari Image Compatibility

- The converter contains an additional compatibility layer for Safari image rendering issues in archives that embed only some URL variants of the same asset.
- This part is provider-agnostic but heuristic, not a generic media abstraction:
  - It groups related image URLs into asset variants and prefers the best archived match when HTML references a missing variant.
  - It rewrites certain `<picture>` blocks to a more reliable `<img>` fallback for Safari.
  - It emits `f_auto` alias resources alongside embedded `f_webp` resources when the archived URL pattern supports that mapping.
  - When possible, it derives an original asset URL and stores a JPEG/PNG fallback in the archive instead of leaving Safari with only WebP data.
- Inference: these Safari workarounds are intended to improve resilience across providers, but they still rely on URL-pattern heuristics rather than explicit provider metadata.
- If similar issues appear for another archive format or image URL scheme, the general converter should still work, but the Safari-specific fallback logic may need additional heuristics.
