import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageCompatibilityPart {
    public let index: Int
    public let mimeType: String
    public let charset: String?
    public let resolvedURL: URL?
    public var decodedBody: Data

    public init(index: Int, mimeType: String, charset: String?, resolvedURL: URL?, decodedBody: Data) {
        self.index = index
        self.mimeType = mimeType
        self.charset = charset
        self.resolvedURL = resolvedURL
        self.decodedBody = decodedBody
    }

    var decodedString: String? {
        if let charset, let encoding = String.Encoding(ianaCharsetName: charset) {
            return String(data: decodedBody, encoding: encoding)
        }
        return String(data: decodedBody, encoding: .utf8) ?? String(data: decodedBody, encoding: .isoLatin1)
    }
}

public struct ImageAliasResource {
    public let data: Data
    public let url: URL
    public let mimeType: String
    public let textEncodingName: String?

    public init(data: Data, url: URL, mimeType: String, textEncodingName: String?) {
        self.data = data
        self.url = url
        self.mimeType = mimeType
        self.textEncodingName = textEncodingName
    }
}

public enum ImageVariantSafariCompatibility {
    public static func rewriteHTML(in parts: inout [ImageCompatibilityPart]) {
        let resolvedURLs = parts.compactMap { $0.resolvedURL?.absoluteString }
        let availableVariants = parts.compactMap { part -> VariantURL? in
            guard let urlString = part.resolvedURL?.absoluteString else {
                return nil
            }
            return VariantURL(urlString: urlString)
        }
        let syntheticAliasVariants = availableVariants.compactMap { variant -> VariantURL? in
            guard variant.format == "f_webp" else {
                return nil
            }
            let aliasURL = variant.urlString.replacingOccurrences(of: ",f_webp,", with: ",f_auto,")
            guard aliasURL != variant.urlString else {
                return nil
            }
            return VariantURL(urlString: aliasURL)
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

            var rewrittenHTML = rewritePictureBlocks(
                in: html,
                availableURLs: availableURLs,
                preferredURLsByAsset: preferredURLsByAsset
            )

            rewrittenHTML = rewriteImageURLs(
                in: rewrittenHTML,
                availableURLs: availableURLs,
                preferredURLsByAsset: preferredURLsByAsset
            )

            if rewrittenHTML != html {
                parts[index].decodedBody = Data(rewrittenHTML.utf8)
            }
        }
    }

    public static func aliasResources(for part: ImageCompatibilityPart) -> [ImageAliasResource] {
        guard
            let resolvedURL = part.resolvedURL,
            part.mimeType.lowercased().hasPrefix("image/"),
            let variant = VariantURL(urlString: resolvedURL.absoluteString),
            variant.format == "f_webp"
        else {
            return []
        }

        let aliasURLString = variant.urlString.replacingOccurrences(of: ",f_webp,", with: ",f_auto,")
        guard aliasURLString != variant.urlString, let aliasURL = URL(string: aliasURLString) else {
            return []
        }

        let aliasPayload = transcodeImageDataIfNeeded(part.decodedBody, aliasURL: aliasURL)
        return [
            ImageAliasResource(
                data: aliasPayload.data,
                url: aliasURL,
                mimeType: aliasPayload.mimeType,
                textEncodingName: part.charset
            )
        ]
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
        if let variant = VariantURL(urlString: aliasURL.absoluteString) {
            return variant.originalAssetExtension
        }
        return aliasURL.pathExtension.lowercased()
    }

    private static func fetchOriginalAssetDataIfAvailable(for aliasURL: URL) -> (data: Data, mimeType: String) {
        guard let originalAssetURL = VariantURL(urlString: aliasURL.absoluteString)?.originalAssetURL else {
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

    private static func rewriteImageURLs(
        in html: String,
        availableURLs: Set<String>,
        preferredURLsByAsset: [String: String]
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^"'\s<>)]+"#) else {
            return html
        }

        let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsrange)
        guard !matches.isEmpty else {
            return html
        }

        var rewrittenHTML = html
        for match in matches.reversed() {
            guard let range = Range(match.range, in: rewrittenHTML) else {
                continue
            }

            let urlString = String(rewrittenHTML[range])
            guard !availableURLs.contains(urlString), let variant = VariantURL(urlString: urlString) else {
                continue
            }

            let replacementURL = replacementImageURL(
                for: variant,
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

    private static func rewritePictureBlocks(
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
            guard pictureHTML.contains("http://") || pictureHTML.contains("https://") else {
                continue
            }

            let simplifiedPictureHTML = simplifyPictureBlock(
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

    private static func simplifyPictureBlock(
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
        guard let variant = VariantURL(urlString: originalURL) else {
            return pictureHTML
        }

        let rewrittenURL = preferredHTMLImageURL(
            for: variant,
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

    private static func replacementImageURL(
        for variant: VariantURL,
        availableURLs: Set<String>,
        preferredURLsByAsset: [String: String]
    ) -> String {
        if variant.format == "f_auto" {
            let webPAlias = variant.urlString.replacingOccurrences(of: ",f_auto,", with: ",f_webp,")
            if availableURLs.contains(webPAlias) {
                return webPAlias
            }
        }

        return preferredURLsByAsset[variant.assetKey] ?? variant.urlString
    }

    private static func preferredHTMLImageURL(
        for variant: VariantURL,
        availableURLs: Set<String>,
        preferredURLsByAsset: [String: String]
    ) -> String {
        let autoAlias = variant.urlString.replacingOccurrences(of: ",f_webp,", with: ",f_auto,")
        if autoAlias != variant.urlString, availableURLs.contains(autoAlias) {
            return autoAlias
        }

        if variant.format == "f_auto", availableURLs.contains(variant.urlString) {
            return variant.urlString
        }

        if let preferredURL = preferredURLsByAsset[variant.assetKey] {
            let preferredAutoAlias = preferredURL.replacingOccurrences(of: ",f_webp,", with: ",f_auto,")
            if preferredAutoAlias != preferredURL, availableURLs.contains(preferredAutoAlias) {
                return preferredAutoAlias
            }
            return preferredURL
        }

        return variant.urlString
    }

    private static func preferredVariantOrder(_ lhs: VariantURL, _ rhs: VariantURL) -> Bool {
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

private struct VariantURL {
    let urlString: String
    let assetKey: String
    let format: String?
    let width: Int
    let originalAssetURL: URL?
    let originalAssetExtension: String

    init?(urlString: String) {
        guard
            let absoluteURL = URL(string: urlString),
            let scheme = absoluteURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let assetRange = urlString.range(of: "/https%3A", options: .backwards) ?? urlString.range(of: "/http%3A", options: .backwards)
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

        let nestedEncodedURL = String(urlString[urlString.index(after: assetRange.lowerBound)...])
        let nestedDecodedURL = nestedEncodedURL.removingPercentEncoding
        self.originalAssetURL = nestedDecodedURL.flatMap(URL.init(string:))
        self.originalAssetExtension = originalAssetURL?.pathExtension.lowercased() ?? absoluteURL.pathExtension.lowercased()
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
