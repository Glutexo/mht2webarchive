import Foundation
import MHTWebArchiveCore

public enum MHT2WebArchiveApp {
    public static func run(
        arguments: [String],
        standardInput: FileHandle = .standardInput,
        standardOutput: FileHandle = .standardOutput,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        do {
            let options = try CLIOptions.parse(arguments: arguments)
            switch options.mode {
            case .stream(let inputURL, let output):
                try runStream(
                    inputURL: inputURL,
                    output: output,
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    standardError: standardError
                )
            case .batch(let jobs, let outputDirectory):
                try runBatch(jobs: jobs, outputDirectory: outputDirectory, standardError: standardError)
            }
            return 0
        } catch let error as CLIError {
            standardError.write(Data("Error: \(error.localizedDescription)\n\n".utf8))
            standardError.write(Data(CLIOptions.usage.utf8))
            return 2
        } catch {
            standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func runStream(
        inputURL: URL?,
        output: CLIOptions.StreamOutput,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) throws {
        let result: ConvertedArchive
        let outputURL: URL?
        switch output {
        case .file(let url):
            outputURL = url
        case .stdout:
            outputURL = nil
        }

        if let inputURL {
            result = try MHTConverter.convertFile(at: inputURL, outputURL: outputURL)
        } else {
            let stdinData = standardInput.readDataToEndOfFile()
            guard !stdinData.isEmpty else {
                throw CLIError.invalidArgument("Standard input is empty.")
            }
            result = try MHTConverter.convert(data: stdinData, outputURL: outputURL)
        }

        if case .stdout = output {
            standardOutput.write(result.data)
        } else {
            try result.data.write(to: result.suggestedOutputURL, options: .atomic)
            standardError.write(Data("Wrote \(result.suggestedOutputURL.path)\n".utf8))
        }
    }

    private static func runBatch(jobs: [BatchJob], outputDirectory: URL, standardError: FileHandle) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for job in jobs {
            let outputURL = outputDirectory
                .appendingPathComponent(job.outputName)
                .appendingPathExtension("webarchive")
            let result = try MHTConverter.convertFile(at: job.inputURL, outputURL: outputURL)
            try result.data.write(to: outputURL, options: .atomic)
            standardError.write(Data("Wrote \(outputURL.path)\n".utf8))
        }
    }
}

public struct CLIOptions {
    public enum StreamOutput {
        case file(URL?)
        case stdout
    }

    public enum Mode {
        case stream(inputURL: URL?, output: StreamOutput)
        case batch(jobs: [BatchJob], outputDirectory: URL)
    }

    public let mode: Mode

    public static let usage = """
    Usage:
      mht2webarchive <input.mht> [-o output.webarchive]
      mht2webarchive - [-o -]
      mht2webarchive --batch <input...> --output-dir <directory>

    Notes:
      - Use `-` as the input path to read from stdin.
      - Use `-o -` to write the generated `.webarchive` bytes to stdout.
      - `--batch` accepts files and directories. Directories are scanned recursively for `.mht` and `.mhtml`.
    """

    public static func parse(arguments: [String]) throws -> CLIOptions {
        guard !arguments.isEmpty else {
            throw CLIError.usage
        }

        var batchMode = false
        var outputPath: String?
        var outputDirectoryPath: String?
        var rawInputs: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                throw CLIError.usage
            case "-o", "--output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("Missing value for \(argument).")
                }
                outputPath = arguments[index]
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("Missing value for \(argument).")
                }
                outputDirectoryPath = arguments[index]
            case "--batch":
                batchMode = true
            default:
                if argument.hasPrefix("-"), argument != "-" {
                    throw CLIError.invalidArgument("Unknown option \(argument).")
                }
                rawInputs.append(argument)
            }
            index += 1
        }

        if batchMode {
            if rawInputs.isEmpty {
                throw CLIError.invalidArgument("Batch mode requires at least one input file or directory.")
            }
            if outputDirectoryPath == nil {
                throw CLIError.invalidArgument("Batch mode requires `--output-dir`.")
            }
            if outputPath != nil {
                throw CLIError.invalidArgument("Use `--output-dir` instead of `-o` in batch mode.")
            }

            let jobs = try BatchInputCollector.collect(from: rawInputs)
            if jobs.isEmpty {
                throw CLIError.invalidArgument("No `.mht` or `.mhtml` files were found for batch conversion.")
            }

            return CLIOptions(
                mode: .batch(
                    jobs: jobs,
                    outputDirectory: URL(fileURLWithPath: outputDirectoryPath!)
                )
            )
        }

        guard rawInputs.count == 1 else {
            throw CLIError.invalidArgument("Provide exactly one input, or use `--batch` for multiple inputs.")
        }
        if outputDirectoryPath != nil {
            throw CLIError.invalidArgument("`--output-dir` can only be used with `--batch`.")
        }

        let inputToken = rawInputs[0]
        let inputURL = inputToken == "-" ? nil : URL(fileURLWithPath: inputToken)
        let output: StreamOutput = if outputPath == "-" {
            .stdout
        } else {
            .file(outputPath.map { URL(fileURLWithPath: $0) })
        }

        if inputToken == "-", let outputPath, outputPath != "-" {
            let parent = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
            if parent.path.isEmpty == false {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
        }

        return CLIOptions(mode: .stream(inputURL: inputURL, output: output))
    }
}

public struct BatchJob: Equatable {
    public let inputURL: URL
    public let outputName: String

    public init(inputURL: URL, outputName: String) {
        self.inputURL = inputURL
        self.outputName = outputName
    }
}

public enum BatchInputCollector {
    public static func collect(from rawInputs: [String]) throws -> [BatchJob] {
        let fileManager = FileManager.default
        var jobs: [BatchJob] = []
        var usedNames = Set<String>()

        for rawInput in rawInputs {
            let inputURL = URL(fileURLWithPath: rawInput)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
                throw CLIError.invalidArgument("Input path does not exist: \(rawInput)")
            }

            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(
                    at: inputURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )

                while let item = enumerator?.nextObject() as? URL {
                    guard isConvertibleFile(item) else { continue }
                    let baseName = item.deletingPathExtension().lastPathComponent
                    jobs.append(BatchJob(inputURL: item, outputName: uniqueName(for: baseName, usedNames: &usedNames)))
                }
            } else {
                guard isConvertibleFile(inputURL) else {
                    throw CLIError.invalidArgument("Unsupported batch input: \(rawInput)")
                }
                let baseName = inputURL.deletingPathExtension().lastPathComponent
                jobs.append(BatchJob(inputURL: inputURL, outputName: uniqueName(for: baseName, usedNames: &usedNames)))
            }
        }

        return jobs.sorted { $0.inputURL.path < $1.inputURL.path }
    }

    private static func isConvertibleFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mht" || ext == "mhtml"
    }

    private static func uniqueName(for baseName: String, usedNames: inout Set<String>) -> String {
        let sanitized = baseName.isEmpty ? "archive" : baseName
        if usedNames.insert(sanitized).inserted {
            return sanitized
        }

        var suffix = 2
        while true {
            let candidate = "\(sanitized)-\(suffix)"
            if usedNames.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
    }
}

public enum CLIError: LocalizedError {
    case usage
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .usage:
            return "Missing required arguments."
        case .invalidArgument(let message):
            return message
        }
    }
}
