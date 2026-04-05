import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

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

        rewriteHTMLSubstackImageReferences(in: &resolvedParts)

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
                let aliasResources = try makeAliasResources(for: part, primaryResource: resource)
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

    private static func makeAliasResources(for part: ResolvedPart, primaryResource: WebResource) throws -> [WebResource] {
        guard
            let resolvedURL = part.resolvedURL,
            part.mimeType.lowercased().hasPrefix("image/"),
            let host = resolvedURL.host?.lowercased(),
            host == "substackcdn.com"
        else {
            return []
        }

        let absoluteString = resolvedURL.absoluteString
        guard absoluteString.contains("/image/fetch/"), absoluteString.contains(",f_webp,") else {
            return []
        }

        let aliasURLString = absoluteString.replacingOccurrences(of: ",f_webp,", with: ",f_auto,")
        guard aliasURLString != absoluteString, let aliasURL = URL(string: aliasURLString) else {
            return []
        }

        let aliasPayload = transcodeImageDataIfNeeded(part.decodedBody, aliasURL: aliasURL)
        guard let aliasResource = WebResource(
            data: aliasPayload.data,
            url: aliasURL,
            mimeType: aliasPayload.mimeType,
            textEncodingName: part.charset,
            frameName: nil
        ) else {
            throw MHTConversionError.archiveCreationFailed
        }

        return [aliasResource]
    }

    private static func transcodeImageDataIfNeeded(_ data: Data, aliasURL: URL) -> (data: Data, mimeType: String) {
        let pathExtension = preferredAliasImageExtension(for: aliasURL)
        guard pathExtension == "jpg" || pathExtension == "jpeg" || pathExtension == "png" else {
            return (data, "image/webp")
        }

        let fetchedOriginalAsset = fetchOriginalAssetDataIfAvailable(for: aliasURL)
        if fetchedOriginalAsset.mimeType != "image/webp" {
            return fetchedOriginalAsset
        }

        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return (data, "image/webp")
        }
        let destinationData = NSMutableData()

        if pathExtension == "png" {
            guard
                let destination = CGImageDestinationCreateWithData(destinationData as CFMutableData, UTType.png.identifier as CFString, 1, nil)
            else {
                return (data, "image/webp")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                return (data, "image/webp")
            }
            return (destinationData as Data, "image/png")
        }

        guard
            let destination = CGImageDestinationCreateWithData(destinationData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return (data, "image/webp")
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return (data, "image/webp")
        }

        return (destinationData as Data, "image/jpeg")
    }

    private static func preferredAliasImageExtension(for aliasURL: URL) -> String {
        let absoluteString = aliasURL.absoluteString
        if let nestedRange = absoluteString.range(of: "/https%3A", options: .backwards) {
            let nestedEncodedURL = String(absoluteString[absoluteString.index(after: nestedRange.lowerBound)...])
            if
                let nestedDecodedURL = nestedEncodedURL.removingPercentEncoding,
                let nestedURL = URL(string: nestedDecodedURL)
            {
                let nestedExtension = nestedURL.pathExtension.lowercased()
                if !nestedExtension.isEmpty {
                    return nestedExtension
                }
            }
        }

        return aliasURL.pathExtension.lowercased()
    }

    private static func fetchOriginalAssetDataIfAvailable(for aliasURL: URL) -> (data: Data, mimeType: String) {
        guard let originalAssetURL = originalAssetURL(from: aliasURL) else {
            return (Data(), "image/webp")
        }

        do {
            let fetchedData = try Data(contentsOf: originalAssetURL)
            switch originalAssetURL.pathExtension.lowercased() {
            case "png":
                return (fetchedData, "image/png")
            case "jpg", "jpeg":
                return (fetchedData, "image/jpeg")
            default:
                return (Data(), "image/webp")
            }
        } catch {
            return (Data(), "image/webp")
        }
    }

    private static func originalAssetURL(from aliasURL: URL) -> URL? {
        let absoluteString = aliasURL.absoluteString
        guard let nestedRange = absoluteString.range(of: "/https%3A", options: .backwards) else {
            return nil
        }
        let nestedEncodedURL = String(absoluteString[absoluteString.index(after: nestedRange.lowerBound)...])
        guard let nestedDecodedURL = nestedEncodedURL.removingPercentEncoding else {
            return nil
        }
        return URL(string: nestedDecodedURL)
    }

    private static func rewriteHTMLSubstackImageReferences(in parts: inout [ResolvedPart]) {
        let resolvedURLs = parts.compactMap { $0.resolvedURL?.absoluteString }
        let availableVariants = parts.compactMap { part -> SubstackImageVariant? in
            guard let urlString = part.resolvedURL?.absoluteString else {
                return nil
            }
            return SubstackImageVariant(urlString: urlString)
        }
        let syntheticAliasVariants = availableVariants.compactMap { variant -> SubstackImageVariant? in
            guard variant.format == "f_webp" else {
                return nil
            }
            let aliasURL = variant.urlString.replacingOccurrences(of: ",f_webp,", with: ",f_auto,")
            guard aliasURL != variant.urlString else {
                return nil
            }
            return SubstackImageVariant(urlString: aliasURL)
        }
        let availableURLs = Set(resolvedURLs + syntheticAliasVariants.map(\.urlString))
        let allVariants = availableVariants + syntheticAliasVariants

        let preferredURLsByAsset = Dictionary(
            grouping: allVariants,
            by: \.assetKey
        ).compactMapValues { variants in
            variants.sorted(by: preferredVariantOrder).first?.urlString
        }

        guard !preferredURLsByAsset.isEmpty else {
            return
        }

        for index in parts.indices where parts[index].mimeType.lowercased() == "text/html" {
            guard let html = parts[index].decodedString else {
                continue
            }

            var rewrittenHTML = rewriteSubstackPictureBlocks(
                in: html,
                availableURLs: availableURLs,
                preferredURLsByAsset: preferredURLsByAsset
            )

            rewrittenHTML = rewriteSubstackImageURLs(
                in: rewrittenHTML,
                availableURLs: availableURLs,
                preferredURLsByAsset: preferredURLsByAsset
            )

            if rewrittenHTML != html {
                parts[index].decodedBody = Data(rewrittenHTML.utf8)
            }
        }
    }

    private static func rewriteSubstackImageURLs(
        in html: String,
        availableURLs: Set<String>,
        preferredURLsByAsset: [String: String]
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https://substackcdn\.com/image/fetch/[^"'\s<>)]+"#) else {
            return html
        }

        let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsrange)
        guard !matches.isEmpty else {
            return html
        }

        var rewrittenHTML = html
        for match in matches.reversed() {
            guard
                let range = Range(match.range, in: rewrittenHTML)
            else {
                continue
            }

            let urlString = String(rewrittenHTML[range])
            guard !availableURLs.contains(urlString) else {
                continue
            }

            let replacementURL = replacementSubstackImageURL(
                for: urlString,
                availableURLs: availableURLs,
                preferredURLsByAsset: preferredURLsByAsset
            )
            guard replacementURL != urlString else {
                continue
            }

            rewrittenHTML.replaceSubrange(range, with: replacementURL)
        }

        return rewrittenHTML
    }

    private static func rewriteSubstackPictureBlocks(
        in html: String,
        availableURLs: Set<String>,
        preferredURLsByAsset: [String: String]
    ) -> String {
        guard let pictureRegex = try? NSRegularExpression(pattern: #"<picture>.*?</picture>"#, options: [.dotMatchesLineSeparators]) else {
            return html
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = pictureRegex.matches(in: html, range: range)
        guard !matches.isEmpty else {
            return html
        }

        var rewrittenHTML = html
        for match in matches.reversed() {
            guard let pictureRange = Range(match.range, in: rewrittenHTML) else {
                continue
            }

            let pictureHTML = String(rewrittenHTML[pictureRange])
            guard pictureHTML.contains("https://substackcdn.com/image/fetch/") else {
                continue
            }

            let simplifiedPictureHTML = simplifySubstackPictureBlock(
                pictureHTML,
                availableURLs: availableURLs,
                preferredURLsByAsset: preferredURLsByAsset
            )

            guard simplifiedPictureHTML != pictureHTML else {
                continue
            }

            rewrittenHTML.replaceSubrange(pictureRange, with: simplifiedPictureHTML)
        }

        return rewrittenHTML
    }

    private static func simplifySubstackPictureBlock(
        _ pictureHTML: String,
        availableURLs: Set<String>,
        preferredURLsByAsset: [String: String]
    ) -> String {
        guard
            let imgRegex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#),
            let srcRegex = try? NSRegularExpression(pattern: #"src="([^"]+)""#),
            let sourceRegex = try? NSRegularExpression(pattern: #"<source\b[^>]*>"#)
        else {
            return pictureHTML
        }

        let pictureRange = NSRange(pictureHTML.startIndex..<pictureHTML.endIndex, in: pictureHTML)
        guard
            let imgMatch = imgRegex.firstMatch(in: pictureHTML, range: pictureRange),
            let imgRange = Range(imgMatch.range, in: pictureHTML)
        else {
            return pictureHTML
        }

        let imgTag = String(pictureHTML[imgRange])
        let imgTagRange = NSRange(imgTag.startIndex..<imgTag.endIndex, in: imgTag)
        guard
            let srcMatch = srcRegex.firstMatch(in: imgTag, range: imgTagRange),
            let srcCaptureRange = Range(srcMatch.range(at: 1), in: imgTag)
        else {
            return pictureHTML
        }

        let originalURL = String(imgTag[srcCaptureRange])
        guard originalURL.contains("https://substackcdn.com/image/fetch/") else {
            return pictureHTML
        }

        let rewrittenURL = preferredHTMLSubstackImageURL(
            for: originalURL,
            availableURLs: availableURLs,
            preferredURLsByAsset: preferredURLsByAsset
        )

        let rewrittenImgTag = imgTag.replacingCharacters(in: srcCaptureRange, with: rewrittenURL)
        var simplifiedPictureHTML = pictureHTML.replacingCharacters(in: imgRange, with: rewrittenImgTag)
        simplifiedPictureHTML = sourceRegex.stringByReplacingMatches(
            in: simplifiedPictureHTML,
            range: NSRange(simplifiedPictureHTML.startIndex..<simplifiedPictureHTML.endIndex, in: simplifiedPictureHTML),
            withTemplate: ""
        )

        return simplifiedPictureHTML
    }

    private static func replacementSubstackImageURL(
        for urlString: String,
        availableURLs: Set<String>,
        preferredURLsByAsset: [String: String]
    ) -> String {
        guard let variant = SubstackImageVariant(urlString: urlString) else {
            return urlString
        }

        if variant.format == "f_auto" {
            let autoAlias = urlString.replacingOccurrences(of: ",f_auto,", with: ",f_webp,")
            if availableURLs.contains(autoAlias) {
                return autoAlias
            }
        }

        return preferredURLsByAsset[variant.assetKey] ?? urlString
    }

    private static func preferredHTMLSubstackImageURL(
        for urlString: String,
        availableURLs: Set<String>,
        preferredURLsByAsset: [String: String]
    ) -> String {
        guard let variant = SubstackImageVariant(urlString: urlString) else {
            return urlString
        }

        let autoAlias = urlString.replacingOccurrences(of: ",f_webp,", with: ",f_auto,")
        if autoAlias != urlString, availableURLs.contains(autoAlias) {
            return autoAlias
        }

        if variant.format == "f_auto", availableURLs.contains(urlString) {
            return urlString
        }

        if let preferredURL = preferredURLsByAsset[variant.assetKey] {
            let preferredAutoAlias = preferredURL.replacingOccurrences(of: ",f_webp,", with: ",f_auto,")
            if preferredAutoAlias != preferredURL, availableURLs.contains(preferredAutoAlias) {
                return preferredAutoAlias
            }
            return preferredURL
        }

        return urlString
    }

    private static func preferredVariantOrder(_ lhs: SubstackImageVariant, _ rhs: SubstackImageVariant) -> Bool {
        if lhs.width != rhs.width {
            return lhs.width > rhs.width
        }

        let lhsRank = preferredFormatRank(lhs.format)
        let rhsRank = preferredFormatRank(rhs.format)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        return lhs.urlString < rhs.urlString
    }

    private static func preferredFormatRank(_ format: String?) -> Int {
        switch format {
        case "f_webp": return 0
        case "f_auto": return 1
        case "f_jpg": return 2
        case "f_png": return 3
        default: return 4
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

    var decodedString: String? {
        if let charset, let encoding = String.Encoding(ianaCharsetName: charset) {
            return String(data: decodedBody, encoding: encoding)
        }
        return String(data: decodedBody, encoding: .utf8) ?? String(data: decodedBody, encoding: .isoLatin1)
    }
}

struct SubstackImageVariant {
    let urlString: String
    let assetKey: String
    let format: String?
    let width: Int

    init?(urlString: String) {
        guard
            urlString.hasPrefix("https://substackcdn.com/image/fetch/"),
            let assetRange = urlString.range(of: "/https%3A", options: .backwards)
        else {
            return nil
        }

        self.urlString = urlString
        self.assetKey = String(urlString[assetRange.lowerBound...])

        let transformPrefix = urlString[..<assetRange.lowerBound]
        let transformComponents = transformPrefix.split(separator: ",")

        self.format = transformComponents.first(where: { $0.hasPrefix("f_") }).map(String.init)
        self.width = transformComponents
            .first(where: { $0.hasPrefix("w_") })
            .flatMap { Int($0.dropFirst(2)) } ?? 0
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

private extension String.Encoding {
    init?(ianaCharsetName: String) {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaCharsetName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        self.init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
