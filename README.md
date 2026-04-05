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
- The base MHT parsing and resource resolution logic is general-purpose and applies to any multipart MHT / MHTML input.

## Safari Image Compatibility

- The converter contains an additional compatibility layer for Safari rendering issues observed in Substack-generated MHT files.
- This part is intentionally vendor-specific, not fully general:
  - It detects `substackcdn.com/image/fetch/...` image URLs.
  - It rewrites HTML image references when the MHT only embeds a subset of Substack CDN variants.
  - It simplifies certain Substack `<picture>` blocks to a more reliable `<img>` fallback for Safari.
  - It emits `f_auto` alias resources alongside embedded `f_webp` resources.
  - When possible, it fetches the original encoded asset URL from the Substack CDN URL and stores a real JPEG/PNG fallback in the archive.
- Inference: these Safari workarounds are tailored to the URL structure and variant behavior used by Substack's CDN, so they should be considered targeted heuristics rather than a generic CDN abstraction.
- If similar issues appear for another publisher or CDN, the general converter should still work, but the Safari-specific fallback logic may need a separate compatibility rule for that provider.
