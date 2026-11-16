// 本文件处理拖入标签视觉配置界面的图片数据，隔离不同来源的文件读取细节。

import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

@MainActor
enum TagDropImageLoader {
    static let supportedTypeIdentifiers: [String] = [
        UTType.fileURL.identifier,
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.tiff.identifier,
        UTType.bmp.identifier,
        UTType.gif.identifier,
        UTType.image.identifier,
        UTType.url.identifier,
        UTType.utf8PlainText.identifier,
        UTType.text.identifier
    ]

    static func imageData(from providers: [NSItemProvider]) async throws -> Data {
        try await imageData(from: providers) { url in
            try await URLSession.shared.data(from: url)
        }
    }

    static func imageData(
        from providers: [NSItemProvider],
        fetchRemoteImageData: @escaping (URL) async throws -> (Data, URLResponse)
    ) async throws -> Data {
        for provider in providers {
            if let data = try? await localFileImageData(from: provider) {
                return data
            }
        }

        for provider in providers {
            if let data = try? await remoteImageData(from: provider, fetchRemoteImageData: fetchRemoteImageData) {
                return data
            }
        }

        for provider in providers {
            if let data = try? await directImageData(from: provider) {
                return data
            }
        }

        throw NyaEHError.tagVisualDropImageUnavailable
    }

    private static func localFileImageData(from provider: NSItemProvider) async throws -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
              let url = try await loadURL(from: provider, typeIdentifier: UTType.fileURL.identifier),
              url.isFileURL else {
            return nil
        }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        return NSImage(data: data) == nil ? nil : data
    }

    private static func directImageData(from provider: NSItemProvider) async throws -> Data? {
        for type in imageTypeIdentifiers where provider.hasItemConformingToTypeIdentifier(type) {
            if let data = try? await loadData(from: provider, typeIdentifier: type),
               NSImage(data: data) != nil {
                return data
            }
        }
        return nil
    }

    private static func remoteImageData(
        from provider: NSItemProvider,
        fetchRemoteImageData: (URL) async throws -> (Data, URLResponse)
    ) async throws -> Data? {
        guard let url = try await remoteURL(from: provider),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        let (data, response) = try await fetchRemoteImageData(url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            return nil
        }
        return NSImage(data: data) == nil ? nil : data
    }

    private static var imageTypeIdentifiers: [String] {
        [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.tiff.identifier,
            UTType.bmp.identifier,
            UTType.gif.identifier,
            UTType.image.identifier
        ]
    }

    private static var textTypeIdentifiers: [String] {
        [
            UTType.utf8PlainText.identifier,
            UTType.text.identifier
        ]
    }

    private static func remoteURL(from provider: NSItemProvider) async throws -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await loadURL(from: provider, typeIdentifier: UTType.url.identifier) {
            return url
        }

        for type in textTypeIdentifiers where provider.hasItemConformingToTypeIdentifier(type) {
            if let text = try? await loadText(from: provider, typeIdentifier: type),
               let url = firstHTTPURL(in: text) {
                return url
            }
        }

        return nil
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider, typeIdentifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url(from: item))
                }
            }
        }
    }

    private static func loadText(from provider: NSItemProvider, typeIdentifier: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: text(from: item))
                }
            }
        }
    }

    private nonisolated static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let data = item as? NSData {
            return URL(dataRepresentation: data as Data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        if let attributedString = item as? NSAttributedString {
            return URL(string: attributedString.string)
        }
        return nil
    }

    private nonisolated static func text(from item: NSSecureCoding?) -> String? {
        if let string = item as? String {
            return string
        }
        if let string = item as? NSString {
            return string as String
        }
        if let attributedString = item as? NSAttributedString {
            return attributedString.string
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        if let data = item as? NSData {
            return String(data: data as Data, encoding: .utf8)
        }
        return nil
    }

    private nonisolated static func firstHTTPURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector?.matches(in: text, options: [], range: range) ?? []
        return matches
            .compactMap(\.url)
            .first { url in
                guard let scheme = url.scheme?.lowercased() else {
                    return false
                }
                return scheme == "http" || scheme == "https"
            }
    }
}

@MainActor
enum TagPasteboardImageLoader {
    static let readablePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .html,
        .string
    ] + imagePasteboardTypes + promisePasteboardTypes

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "NyaEH",
        category: "TagImageDrop"
    )

    static func imageData(from pasteboard: NSPasteboard) async throws -> Data {
        try await imageData(from: pasteboard) { url in
            try await URLSession.shared.data(from: url)
        }
    }

    static func imageData(
        from pasteboard: NSPasteboard,
        fetchRemoteImageData: @escaping (URL) async throws -> (Data, URLResponse)
    ) async throws -> Data {
        if let data = try? await localFileImageData(from: pasteboard) {
            logPasteboardSuccess(pasteboard, source: "file")
            return data
        }

        if let data = directImageData(from: pasteboard) {
            logPasteboardSuccess(pasteboard, source: "data")
            return data
        }

        if let data = try? await remoteImageData(from: pasteboard, fetchRemoteImageData: fetchRemoteImageData) {
            logPasteboardSuccess(pasteboard, source: "url")
            return data
        }

        if let data = try? await promisedFileImageData(from: pasteboard) {
            logPasteboardSuccess(pasteboard, source: "promise")
            return data
        }

        logPasteboardFailure(pasteboard)
        throw NyaEHError.tagVisualDropImageUnavailable
    }

    static func imageURLs(inHTML html: String, baseURL: URL? = nil) -> [URL] {
        let imgPattern = #"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#
        let matches = regexMatches(pattern: imgPattern, in: html)
        let sources = matches.isEmpty ? [html] : matches

        var urls: [URL] = []
        for source in sources {
            if let url = URL(string: source, relativeTo: baseURL)?.absoluteURL,
               isHTTPURL(url) {
                urls.append(url)
            }
        }

        if urls.isEmpty {
            urls = firstHTTPURLs(in: html)
        }
        return urls
    }

    static func firstHTTPURLs(in text: String) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector?.matches(in: text, options: [], range: range) ?? []
        return matches
            .compactMap(\.url)
            .filter(isHTTPURL)
    }

    private static func localFileImageData(from pasteboard: NSPasteboard) async throws -> Data? {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        for url in fileURLs where url.isFileURL {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            if NSImage(data: data) != nil {
                return data
            }
        }
        return nil
    }

    private static func directImageData(from pasteboard: NSPasteboard) -> Data? {
        for type in imagePasteboardTypes {
            if let data = pasteboard.data(forType: type),
               NSImage(data: data) != nil {
                return data
            }
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for image in images {
                if let data = image.tiffRepresentation,
                   NSImage(data: data) != nil {
                    return data
                }
            }
        }
        return nil
    }

    private static func remoteImageData(
        from pasteboard: NSPasteboard,
        fetchRemoteImageData: (URL) async throws -> (Data, URLResponse)
    ) async throws -> Data? {
        for url in remoteURLs(from: pasteboard) {
            let (data, response) = try await fetchRemoteImageData(url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                continue
            }
            if NSImage(data: data) != nil {
                return data
            }
        }
        return nil
    }

    private static func remoteURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        let explicitPasteboardURL = pasteboardURL(from: pasteboard)

        for string in pasteboardStrings(from: pasteboard) {
            urls.append(contentsOf: imageURLs(inHTML: string, baseURL: explicitPasteboardURL))
        }

        for type in webURLPasteboardTypes {
            guard let text = pasteboardText(from: pasteboard, forType: type) else {
                continue
            }
            urls.append(contentsOf: firstHTTPURLs(in: text))
        }

        if let explicitPasteboardURL {
            urls.append(explicitPasteboardURL)
        }

        if let text = pasteboardText(from: pasteboard, forType: .string) {
            urls.append(contentsOf: firstHTTPURLs(in: text))
        }

        return uniquedURLs(urls)
    }

    private static func pasteboardStrings(from pasteboard: NSPasteboard) -> [String] {
        var values: [String] = []
        let types = uniquedPasteboardTypes(htmlPasteboardTypes + webURLPasteboardTypes + [.string] + (pasteboard.types ?? []))
        for type in types {
            if let string = pasteboardText(from: pasteboard, forType: type) {
                values.append(string)
            }
        }
        return values
    }

    private static func promisedFileImageData(from pasteboard: NSPasteboard) async throws -> Data? {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        guard !receivers.isEmpty else {
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NyaEH-DroppedImage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        for receiver in receivers {
            if let data = try await receivePromisedImageData(receiver: receiver, destinationDirectory: directory) {
                return data
            }
        }
        return nil
    }

    private static func receivePromisedImageData(
        receiver: NSFilePromiseReceiver,
        destinationDirectory: URL
    ) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            receiver.receivePromisedFiles(
                atDestination: destinationDirectory,
                options: [:],
                operationQueue: queue
            ) { fileURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                do {
                    let data = try Data(contentsOf: fileURL)
                    continuation.resume(returning: NSImage(data: data) == nil ? nil : data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static var htmlPasteboardTypes: [NSPasteboard.PasteboardType] {
        [
            .html,
            NSPasteboard.PasteboardType("public.html"),
            NSPasteboard.PasteboardType("Apple HTML pasteboard type")
        ]
    }

    private static var imagePasteboardTypes: [NSPasteboard.PasteboardType] {
        [
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.bmp.identifier),
            NSPasteboard.PasteboardType(UTType.image.identifier)
        ]
    }

    private static var promisePasteboardTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    private static var webURLPasteboardTypes: [NSPasteboard.PasteboardType] {
        [
            .URL,
            NSPasteboard.PasteboardType("public.url"),
            NSPasteboard.PasteboardType("public.url-name"),
            NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"),
            NSPasteboard.PasteboardType("WebURLPboardType")
        ]
    }

    private static func pasteboardURL(from pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.first(where: isHTTPURL)
    }

    private static func pasteboardText(from pasteboard: NSPasteboard, forType type: NSPasteboard.PasteboardType) -> String? {
        if let string = pasteboard.string(forType: type) {
            return string
        }
        if let data = pasteboard.data(forType: type),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let propertyList = pasteboard.propertyList(forType: type) {
            return strings(fromPropertyList: propertyList).joined(separator: "\n")
        }
        return nil
    }

    private static func strings(fromPropertyList propertyList: Any) -> [String] {
        if let string = propertyList as? String {
            return [string]
        }
        if let array = propertyList as? [Any] {
            return array.flatMap(strings(fromPropertyList:))
        }
        if let dictionary = propertyList as? [AnyHashable: Any] {
            return dictionary.values.flatMap(strings(fromPropertyList:))
        }
        return []
    }

    private static func regexMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { result in
            guard result.numberOfRanges > 1,
                  let matchRange = Range(result.range(at: 1), in: text) else {
                return nil
            }
            return String(text[matchRange])
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    private static func uniquedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let key = url.absoluteString
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(url)
        }
        return result
    }

    private static func uniquedPasteboardTypes(_ types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        var seen: Set<String> = []
        var result: [NSPasteboard.PasteboardType] = []
        for type in types {
            guard seen.insert(type.rawValue).inserted else {
                continue
            }
            result.append(type)
        }
        return result
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private static func logPasteboardSuccess(_ pasteboard: NSPasteboard, source: String) {
        logger.debug("pasteboard image drop source=\(source, privacy: .public) types=\(pasteboard.typesDescription, privacy: .public)")
    }

    private static func logPasteboardFailure(_ pasteboard: NSPasteboard) {
        logger.debug("pasteboard image drop failed types=\(pasteboard.typesDescription, privacy: .public)")
    }
}

private extension NSPasteboard {
    var typesDescription: String {
        types?.map(\.rawValue).joined(separator: ",") ?? "none"
    }
}
