# mht2webarchive

Small macOS CLI that converts `MHT` / `MHTML` files into Safari-compatible `.webarchive` files.

## What It Converts

- `MHT` / `MHTML` is a MIME multipart snapshot format: one file contains the main HTML document plus embedded resources such as images, stylesheets, and other referenced assets.
- `.webarchive` is Apple's archived webpage format used by WebKit and Safari. It stores a main resource together with subresources in a structure Safari can reopen as a self-contained page.
- This tool converts between those models by parsing the multipart `MHT` payload, decoding each part, resolving archived resource URLs, and re-emitting the result as a `WebArchive` made of `WebResource` entries.
- In practice, the goal is format translation rather than visual re-authoring: preserve the captured page and its embedded assets closely enough that Safari can render the archive offline.

## Build

```bash
swift build
```

GitHub Actions must use an Xcode 16 / Swift 6 toolchain before building because the package manifest uses `// swift-tools-version: 6.0`.

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
- The converter aims for direct format translation: it decodes each archived MIME part and writes the HTML and subresources into the `.webarchive` without rewriting HTML or synthesizing fallback assets.
