// 智能导入从源压缩包读取可选的画廊网址；不把提示写入书籍元数据。

import Foundation
import ZIPFoundation

struct ArchiveWebInfoReader: Sendable {
    private static let maximumBytes = 4_096

    func galleryURL(in archiveURL: URL, securityScopedRootURL: URL) throws -> URL? {
        try Task.checkCancellation()
        let granted = securityScopedRootURL.startAccessingSecurityScopedResource()
        defer { if granted { securityScopedRootURL.stopAccessingSecurityScopedResource() } }

        let root = securityScopedRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = archiveURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw NyaEHError.unreadableArchive("Archive is outside the selected library folder.")
        }

        do {
            return try galleryURLWithZIPFoundation(in: archiveURL)
        } catch {
            return try galleryURLWithSystemUnzip(in: archiveURL)
        }
    }

    private func galleryURLWithZIPFoundation(in archiveURL: URL) throws -> URL? {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard let entry = Self.selectedPath(archive.map(\.path)).flatMap({ path in archive.first { $0.path == path } }) else {
            return nil
        }
        guard entry.uncompressedSize <= Self.maximumBytes else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard data.count + chunk.count <= Self.maximumBytes else {
                throw WebInfoTooLarge()
            }
            data.append(chunk)
        }
        return Self.parse(data)
    }

    func galleryURLWithSystemUnzip(in archiveURL: URL) throws -> URL? {
        let paths = try Self.run("/usr/bin/zipinfo", ["-1", archiveURL.path], maximumBytes: 1_048_576)
        guard let listing = String(data: paths, encoding: .utf8),
              let path = Self.selectedPath(listing.split(whereSeparator: \.isNewline).map(String.init)) else {
            return nil
        }
        let data = try Self.run("/usr/bin/unzip", ["-p", archiveURL.path, path], maximumBytes: Self.maximumBytes)
        return Self.parse(data)
    }

    private static func selectedPath(_ paths: [String]) -> String? {
        let matches = paths.filter {
            $0.split(separator: "/").last?.lowercased() == "webinfo.txt"
        }
        return matches.first { $0.lowercased() == "webinfo.txt" }
            ?? matches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
    }

    static func parse(_ data: Data) -> URL? {
        guard data.count <= maximumBytes, let content = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline),
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.pathComponents.filter({ $0 != "/" }).count == 3,
              GalleryMetadataFetchService.isSupportedGalleryURL(url) else { return nil }
        return url
    }

    private static func run(_ executable: String, _ arguments: [String], maximumBytes: Int) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readData(ofLength: maximumBytes + 1)
        if data.count > maximumBytes {
            process.terminate()
            process.waitUntilExit()
            return Data()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NyaEHError.unreadableArchive("Unable to read webinfo.txt from archive.")
        }
        return data
    }
}

private struct WebInfoTooLarge: Error {}
