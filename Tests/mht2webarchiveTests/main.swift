import Foundation
import WebKit
@testable import MHTWebArchiveCLI
@testable import MHTWebArchiveCore

@main
struct IntegrationTestRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("converter creates webarchive", testConverterCreatesWebArchive),
            ("converter handles fixture mht with blink binary and cid resources", testFixtureMHTConversion),
            ("single file mode writes requested output", testSingleFileMode),
            ("stdin to file mode works", testStdinToFileMode),
            ("stdin to stdout mode works", testStdoutMode),
            ("batch mode recurses and disambiguates names", testBatchMode),
            ("batch mode validates output directory", testBatchRequiresOutputDirectory),
        ]

        var failures: [String] = []
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
                fputs("FAIL \(name): \(error.localizedDescription)\n", stderr)
            }
        }

        if failures.isEmpty {
            print("All integration tests passed.")
            exit(0)
        }

        fputs("\n\(failures.count) test(s) failed.\n", stderr)
        exit(1)
    }

    private static func testConverterCreatesWebArchive() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/example.mht")
        let result = try MHTConverter.convert(data: sampleMHTData(), sourceURL: sourceURL)

        try expect(result.suggestedOutputURL.path == "/tmp/example.webarchive", "expected default output path")
        try expect(result.mainResourceURL.absoluteString == "https://example.com/index.html", "expected main resource URL")

        let archive = try loadArchive(from: result.data)
        let mainResource = try unwrap(archive.mainResource, "expected main resource")
        try expect(mainResource.url?.absoluteString == "https://example.com/index.html", "expected HTML main resource")

        let resources = (archive.subresources as? [WebResource]) ?? []
        try expect(resources.count == 1, "expected one subresource")
        try expect(resources.first?.url?.absoluteString == "https://example.com/styles/site.css", "expected resolved CSS URL")
    }

    private static func testSingleFileMode() throws {
        try withTemporaryDirectory { directory in
            let inputURL = directory.appendingPathComponent("page.mht")
            let outputURL = directory.appendingPathComponent("page.webarchive")
            try sampleMHTData().write(to: inputURL)

            let stderrPipe = Pipe()
            let exitCode = MHT2WebArchiveApp.run(
                arguments: [inputURL.path, "-o", outputURL.path],
                standardError: stderrPipe.fileHandleForWriting
            )
            stderrPipe.fileHandleForWriting.closeFile()

            try expect(exitCode == 0, "single file mode should exit successfully")
            try expect(FileManager.default.fileExists(atPath: outputURL.path), "single file output should exist")

            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            try expect(stderr.contains(outputURL.path), "stderr should mention output path")

            let archive = try loadArchive(at: outputURL)
            let mainResource = try unwrap(archive.mainResource, "expected main resource in output archive")
            try expect(mainResource.url?.absoluteString == "https://example.com/index.html", "expected output archive HTML URL")
        }
    }

    private static func testFixtureMHTConversion() throws {
        let fixtureURL = fixtureFileURL()
        let result = try MHTConverter.convert(data: try Data(contentsOf: fixtureURL), sourceURL: fixtureURL)
        let archive = try loadArchive(from: result.data)
        let mainResource = try unwrap(archive.mainResource, "expected main resource")
        try expect(
            mainResource.url?.absoluteString == "https://www.noahpinion.blog/p/how-japan-has-changed-in-the-last?utm_campaign=email-post&r=27g416&utm_source=substack&utm_medium=email",
            "expected fixture main resource URL"
        )

        let resources = (archive.subresources as? [WebResource]) ?? []
        try expect(resources.count > 20, "expected many subresources from the fixture MHT")
        try expect(resources.contains(where: { $0.url?.absoluteString.hasPrefix("cid:css-") == true }), "expected cid stylesheet resources")
        try expect(resources.contains(where: { $0.mimeType == "image/webp" }), "expected webp image resources")

        let mainHTML = try unwrap(String(data: mainResource.data, encoding: .utf8), "expected fixture HTML body")
        try expect(
            !mainHTML.contains("https://substackcdn.com/image/fetch/$s_!zhs4!,w_848,c_limit,f_webp,q_auto:good,fl_progressive:steep/"),
            "expected missing hero image variant URLs to be rewritten"
        )
        try expect(
            mainHTML.contains("https://substackcdn.com/image/fetch/$s_!zhs4!,w_1456,c_limit,f_webp,q_auto:good,fl_progressive:steep/"),
            "expected embedded hero image variant URL to remain available"
        )
        try expect(
            !mainHTML.contains("<source type=\"image/webp\" srcset=\"https://substackcdn.com/image/fetch/$s_!zhs4!"),
            "expected hero picture source set to be removed for Safari compatibility"
        )
        try expect(
            mainHTML.contains("<img src=\"https://substackcdn.com/image/fetch/$s_!zhs4!,w_1456,c_limit,f_auto,q_auto:good,fl_progressive:steep/"),
            "expected hero image element to use Safari-friendly fallback"
        )
    }

    private static func testStdinToFileMode() throws {
        try withTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("stdin.webarchive")
            let stdinPipe = Pipe()
            stdinPipe.fileHandleForWriting.write(sampleMHTData())
            stdinPipe.fileHandleForWriting.closeFile()

            let stderrPipe = Pipe()
            let exitCode = MHT2WebArchiveApp.run(
                arguments: ["-", "-o", outputURL.path],
                standardInput: stdinPipe.fileHandleForReading,
                standardError: stderrPipe.fileHandleForWriting
            )
            stderrPipe.fileHandleForWriting.closeFile()

            try expect(exitCode == 0, "stdin to file should exit successfully")
            try expect(FileManager.default.fileExists(atPath: outputURL.path), "stdin to file output should exist")
        }
    }

    private static func testStdoutMode() throws {
        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.write(sampleMHTData())
        stdinPipe.fileHandleForWriting.closeFile()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let exitCode = MHT2WebArchiveApp.run(
            arguments: ["-", "-o", "-"],
            standardInput: stdinPipe.fileHandleForReading,
            standardOutput: stdoutPipe.fileHandleForWriting,
            standardError: stderrPipe.fileHandleForWriting
        )
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        try expect(exitCode == 0, "stdout mode should exit successfully")

        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try expect(stderr.isEmpty, "stdout mode should not write progress messages to stderr")

        let archive = try loadArchive(from: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        let mainResource = try unwrap(archive.mainResource, "expected main resource in stdout archive")
        try expect(mainResource.url?.absoluteString == "https://example.com/index.html", "expected stdout archive HTML URL")
    }

    private static func testBatchMode() throws {
        try withTemporaryDirectory { directory in
            let inputDirectory = directory.appendingPathComponent("input")
            let nestedDirectory = inputDirectory.appendingPathComponent("nested")
            let outputDirectory = directory.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

            try sampleMHTData(title: "One").write(to: inputDirectory.appendingPathComponent("page.mht"))
            try sampleMHTData(title: "Two").write(to: inputDirectory.appendingPathComponent("second.mhtml"))
            try sampleMHTData(title: "Nested").write(to: nestedDirectory.appendingPathComponent("page.mht"))

            let stderrPipe = Pipe()
            let exitCode = MHT2WebArchiveApp.run(
                arguments: ["--batch", inputDirectory.path, "--output-dir", outputDirectory.path],
                standardError: stderrPipe.fileHandleForWriting
            )
            stderrPipe.fileHandleForWriting.closeFile()

            try expect(exitCode == 0, "batch mode should exit successfully")
            try expect(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("page.webarchive").path), "expected first batch output")
            try expect(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("page-2.webarchive").path), "expected duplicate-safe batch output")
            try expect(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("second.webarchive").path), "expected mhtml batch output")
        }
    }

    private static func testBatchRequiresOutputDirectory() throws {
        let stderrPipe = Pipe()
        let exitCode = MHT2WebArchiveApp.run(
            arguments: ["--batch", "/tmp"],
            standardError: stderrPipe.fileHandleForWriting
        )
        stderrPipe.fileHandleForWriting.closeFile()

        try expect(exitCode == 2, "invalid batch invocation should return usage exit code")
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try expect(stderr.contains("Batch mode requires `--output-dir`."), "expected batch validation error")
    }
}

private func sampleMHTData(title: String = "Hello") -> Data {
    Data(
        """
        From: <Saved by tests>
        Subject: \(title)
        MIME-Version: 1.0
        Content-Type: multipart/related;
         type="text/html";
         boundary="----=_NextPart_000_0000";
         start="<main@example>"
        Snapshot-Content-Location: https://example.com/index.html

        ------=_NextPart_000_0000
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable
        Content-Location: https://example.com/index.html
        Content-ID: <main@example>

        <html><head><link rel=3D"stylesheet" href=3D"styles/site.css"></head><body>\(title)</body></html>
        ------=_NextPart_000_0000
        Content-Type: text/css; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable
        Content-Location: styles/site.css

        body { color: #123456; }
        ------=_NextPart_000_0000--
        """.utf8
    )
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func fixtureFileURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("noah-smith-japan-changes.mht")
}

private func loadArchive(at url: URL) throws -> WebArchive {
    try loadArchive(from: Data(contentsOf: url))
}

private func loadArchive(from data: Data) throws -> WebArchive {
    try unwrap(WebArchive(data: data), "expected valid webarchive data")
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw TestFailure(message)
    }
    return value
}

private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw TestFailure(message)
    }
}

private struct TestFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        self.errorDescription = message
    }
}
