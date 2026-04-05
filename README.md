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
