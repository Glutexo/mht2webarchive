import Foundation
import WebKit
import MHTWebArchiveImageCompatibility

public enum MHTConversionError: Error, LocalizedError {
    case invalidMHT(String)
    case missingBoundary
    case noParts
    case missingMainResource
    case unsupportedTransferEncoding(String)
    case archiveCreationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidMHT(let message):
            return "Invalid MHT: \(message)"
        case .missingBoundary:
            return "MHT message is multipart but missing a MIME boundary."
        case .noParts:
            return "MHT message does not contain any MIME parts."
        case .missingMainResource:
            return "Unable to determine the main HTML resource."
        case .unsupportedTransferEncoding(let encoding):
            return "Unsupported content-transfer-encoding: \(encoding)"
        case .archiveCreationFailed:
            return "Unable to construct a WebKit web archive from the MHT contents."
        }
    }
}

public struct ConvertedArchive {
    public let data: Data
    public let suggestedOutputURL: URL
    public let mainResourceURL: URL

    public init(data: Data, suggestedOutputURL: URL, mainResourceURL: URL) {
        self.data = data
        self.suggestedOutputURL = suggestedOutputURL
        self.mainResourceURL = mainResourceURL
    }
}

public enum MHTConverter {
    public static func convertFile(at inputURL: URL, outputURL: URL? = nil) throws -> ConvertedArchive {
        let sourceData = try Data(contentsOf: inputURL)
        let archive = try convert(data: sourceData, sourceURL: inputURL, outputURL: outputURL)
        return archive
    }

    public static func convert(data: Data, sourceURL: URL? = nil, outputURL: URL? = nil) throws -> ConvertedArchive {
        let message = try MIMEParser.parseMessage(data)
        let contentType = try ContentType(rawValue: message.headers["content-type"] ?? "")
        guard contentType.type.lowercased().hasPrefix("multipart/") else {
            throw MHTConversionError.invalidMHT("Top-level content type must be multipart/related.")
        }

        guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty else {
            throw MHTConversionError.missingBoundary
        }

        let parts = try MIMEParser.parseMultipartBody(message.body, boundary: boundary)
        guard !parts.isEmpty else {
            throw MHTConversionError.noParts
        }

        let baseURL = URL(string: message.headers["snapshot-content-location"] ?? "")
            ?? URL(string: message.headers["content-base"] ?? "")
            ?? sourceURL

        var resolvedParts = try parts.enumerated().map { index, part in
            try ResolvedPart(part: part, index: index, baseURL: baseURL)
        }

        applyImageCompatibility(to: &resolvedParts)

        let mainPart = try selectMainPart(from: resolvedParts, startHint: contentType.parameters["start"])
        let mainURL = mainPart.resolvedURL ?? sourceURL ?? URL(fileURLWithPath: "/")
        guard let mainResource = WebResource(
            data: mainPart.decodedBody,
            url: mainURL,
            mimeType: mainPart.mimeType,
            textEncodingName: mainPart.charset,
            frameName: nil
        ) else {
            throw MHTConversionError.archiveCreationFailed
        }

        let subresources = try resolvedParts
            .filter { $0.index != mainPart.index }
            .flatMap { part throws -> [WebResource] in
                guard let resource = WebResource(
                    data: part.decodedBody,
                    url: part.resolvedURL ?? fallbackResourceURL(from: mainURL, index: part.index, mimeType: part.mimeType),
                    mimeType: part.mimeType,
                    textEncodingName: part.charset,
                    frameName: nil
                ) else {
                    throw MHTConversionError.archiveCreationFailed
                }
                let aliasResources = try makeImageAliasResources(for: part)
                return [resource] + aliasResources
            }

        guard let archive = WebArchive(mainResource: mainResource, subresources: subresources, subframeArchives: nil) else {
            throw MHTConversionError.archiveCreationFailed
        }
        guard let archiveData = archive.data else {
            throw MHTConversionError.archiveCreationFailed
        }

        let suggestedOutputURL = outputURL ?? defaultOutputURL(for: sourceURL, mainURL: mainURL)
        return ConvertedArchive(data: archiveData, suggestedOutputURL: suggestedOutputURL, mainResourceURL: mainURL)
    }

    private static func selectMainPart(from parts: [ResolvedPart], startHint: String?) throws -> ResolvedPart {
        if let startHint {
            let normalized = normalizeIdentifier(startHint)
            if let part = parts.first(where: {
                $0.contentID.map(normalizeIdentifier) == normalized || $0.contentLocation == normalized
            }) {
                return part
            }
        }

        if let htmlPart = parts.first(where: { $0.mimeType.lowercased() == "text/html" }) {
            return htmlPart
        }

        guard let firstPart = parts.first else {
            throw MHTConversionError.missingMainResource
        }
        return firstPart
    }

    private static func defaultOutputURL(for sourceURL: URL?, mainURL: URL) -> URL {
        if let sourceURL {
            let base = sourceURL.deletingPathExtension()
            return base.appendingPathExtension("webarchive")
        }

        let lastComponent = mainURL.deletingPathExtension().lastPathComponent
        let name = lastComponent.isEmpty ? "archive" : lastComponent
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(name)
            .appendingPathExtension("webarchive")
    }

    private static func fallbackResourceURL(from mainURL: URL, index: Int, mimeType: String) -> URL {
        let ext = mimeTypeToExtension(mimeType)
        return mainURL
            .deletingLastPathComponent()
            .appendingPathComponent("resource-\(index)")
            .appendingPathExtension(ext)
    }

    private static func mimeTypeToExtension(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "text/css": return "css"
        case "application/javascript", "text/javascript": return "js"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/svg+xml": return "svg"
        default: return "bin"
        }
    }

    private static func applyImageCompatibility(to parts: inout [ResolvedPart]) {
        var compatibilityParts = parts.map { part in
            ImageCompatibilityPart(
                index: part.index,
                mimeType: part.mimeType,
                charset: part.charset,
                resolvedURL: part.resolvedURL,
                decodedBody: part.decodedBody
            )
        }
        ImageVariantSafariCompatibility.rewriteHTML(in: &compatibilityParts)
        for index in parts.indices {
            parts[index].decodedBody = compatibilityParts[index].decodedBody
        }
    }

    private static func makeImageAliasResources(for part: ResolvedPart) throws -> [WebResource] {
        let compatibilityPart = ImageCompatibilityPart(
            index: part.index,
            mimeType: part.mimeType,
            charset: part.charset,
            resolvedURL: part.resolvedURL,
            decodedBody: part.decodedBody
        )

        return try ImageVariantSafariCompatibility.aliasResources(for: compatibilityPart).map { alias in
            guard let resource = WebResource(
                data: alias.data,
                url: alias.url,
                mimeType: alias.mimeType,
                textEncodingName: alias.textEncodingName,
                frameName: nil
            ) else {
                throw MHTConversionError.archiveCreationFailed
            }
            return resource
        }
    }
}

struct MIMEMessage {
    let headers: [String: String]
    let body: Data
}

struct MIMEPart {
    let headers: [String: String]
    let body: Data
}

struct ContentType {
    let type: String
    let parameters: [String: String]

    init(rawValue: String) throws {
        let segments = rawValue.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = segments.first else {
            throw MHTConversionError.invalidMHT("Missing content type header.")
        }

        self.type = first.trimmingCharacters(in: .whitespacesAndNewlines)
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            parameters[key] = rawValue.unquoted
        }
        self.parameters = parameters
    }
}

struct ResolvedPart {
    let index: Int
    let mimeType: String
    let charset: String?
    let contentID: String?
    let contentLocation: String?
    let resolvedURL: URL?
    var decodedBody: Data

    init(part: MIMEPart, index: Int, baseURL: URL?) throws {
        self.index = index
        let contentType = try ContentType(rawValue: part.headers["content-type"] ?? "application/octet-stream")
        self.mimeType = contentType.type.isEmpty ? "application/octet-stream" : contentType.type
        self.charset = contentType.parameters["charset"]
        self.contentID = part.headers["content-id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contentLocation = part.headers["content-location"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resolvedURL = URLResolver.resolve(contentLocation: contentLocation, contentID: contentID, baseURL: baseURL)

        let transferEncoding = part.headers["content-transfer-encoding"]?.lowercased() ?? "binary"
        self.decodedBody = try TransferDecoder.decode(part.body, encoding: transferEncoding)
    }

}

enum MIMEParser {
    static func parseMessage(_ data: Data) throws -> MIMEMessage {
        let bytes = [UInt8](data)
        guard let bodyRange = headerBodyBoundary(in: bytes) else {
            throw MHTConversionError.invalidMHT("Missing header/body separator.")
        }

        let headerData = Data(bytes[0..<bodyRange.headerEnd])
        let bodyData = Data(bytes[bodyRange.bodyStart..<bytes.count])
        return MIMEMessage(
            headers: parseHeaders(headerData),
            body: bodyData
        )
    }

    static func parseMultipartBody(_ body: Data, boundary: String) throws -> [MIMEPart] {
        guard let bodyString = String(data: body, encoding: .isoLatin1) else {
            throw MHTConversionError.invalidMHT("Multipart body is not ISO-8859-1 decodable.")
        }

        let normalized = bodyString.replacingOccurrences(of: "\r\n", with: "\n")
        let marker = "--\(boundary)"
        let closingMarker = "--\(boundary)--"
        var parts: [MIMEPart] = []

        let sections = normalized.components(separatedBy: marker)
        for rawSection in sections.dropFirst() {
            if rawSection.hasPrefix("--") || rawSection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if rawSection.hasPrefix("--") || rawSection.contains(closingMarker) {
                    continue
                }
            }

            var section = rawSection
            if section.hasPrefix("\n") {
                section.removeFirst()
            }
            if section.hasSuffix("\n") {
                section.removeLast()
            }

            guard let sectionData = section.data(using: .isoLatin1) else { continue }
            let message = try parseMessage(sectionData)
            parts.append(MIMEPart(headers: message.headers, body: message.body))
        }

        return parts
    }

    private static func headerBodyBoundary(in bytes: [UInt8]) -> (headerEnd: Int, bodyStart: Int)? {
        if bytes.count >= 4 {
            for index in 0...(bytes.count - 4) where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
                return (index, index + 4)
            }
        }
        if bytes.count >= 2 {
            for index in 0...(bytes.count - 2) where bytes[index] == 10 && bytes[index + 1] == 10 {
                return (index, index + 2)
            }
        }
        return nil
    }

    private static func parseHeaders(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .isoLatin1) else { return [:] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let unfolded = normalized
            .components(separatedBy: "\n")
            .reduce(into: [String]()) { result, line in
                if line.hasPrefix(" ") || line.hasPrefix("\t"), var last = result.popLast() {
                    last += line.trimmingCharacters(in: .whitespaces)
                    result.append(last)
                } else {
                    result.append(line)
                }
            }

        var headers: [String: String] = [:]
        for line in unfolded {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }
}

enum TransferDecoder {
    static func decode(_ data: Data, encoding: String) throws -> Data {
        switch encoding {
        case "7bit", "8bit", "binary":
            return trimTrailingNewlines(from: data)
        case "base64":
            return try decodeBase64(data)
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            throw MHTConversionError.unsupportedTransferEncoding(encoding)
        }
    }

    private static func decodeBase64(_ data: Data) throws -> Data {
        let stripped = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let decoded = Data(base64Encoded: stripped) else {
            throw MHTConversionError.invalidMHT("Unable to decode base64 MIME part.")
        }
        return decoded
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 61 {
                if index + 1 < bytes.count, bytes[index + 1] == 13 {
                    index += min(3, bytes.count - index)
                    continue
                }
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexNibble(bytes[index + 1]),
                   let low = hexNibble(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
            }

            output.append(byte)
            index += 1
        }

        return trimTrailingNewlines(from: Data(output))
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static func trimTrailingNewlines(from data: Data) -> Data {
        var bytes = [UInt8](data)
        while let last = bytes.last, last == 10 || last == 13 {
            bytes.removeLast()
        }
        return Data(bytes)
    }
}

enum URLResolver {
    static func resolve(contentLocation: String?, contentID: String?, baseURL: URL?) -> URL? {
        if let contentLocation, !contentLocation.isEmpty {
            if let absolute = URL(string: contentLocation), absolute.scheme != nil {
                return absolute
            }
            if let baseURL {
                return URL(string: contentLocation, relativeTo: baseURL)?.absoluteURL
            }
        }

        if let contentID {
            let normalized = normalizeIdentifier(contentID)
            return URL(string: "cid:\(normalized)")
        }

        return nil
    }
}

private func normalizeIdentifier(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
}

private extension String {
    var unquoted: String {
        trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
