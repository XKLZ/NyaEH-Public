import Foundation
import Testing
import ZIPFoundation
@testable import NyaEHCore

@Suite("Archive webinfo gallery URLs")
struct ArchiveWebInfoReaderTests {
    @Test("reads root webinfo before nested copies in zip and cbz")
    func readsRootBeforeNestedCopies() throws {
        for ext in ["zip", "cbz"] {
            let root = try temporaryRoot()
            let archiveURL = root.appendingPathComponent("sample.\(ext)")
            try makeArchive(at: archiveURL, entries: [
                "nested/webinfo.txt": Data("https://e-hentai.org/g/2/nested/\n".utf8),
                "webinfo.txt": Data("https://exhentai.org/g/1/root/\n".utf8),
                "001.jpg": Data("page".utf8)
            ])
            let reader = ArchiveWebInfoReader()
            #expect(try reader.galleryURL(in: archiveURL, securityScopedRootURL: root)?.absoluteString == "https://exhentai.org/g/1/root/")
            #expect(try reader.galleryURLWithSystemUnzip(in: archiveURL)?.absoluteString == "https://exhentai.org/g/1/root/")
        }
    }

    @Test("uses deterministically selected nested webinfo")
    func readsNestedWebInfo() throws {
        let root = try temporaryRoot()
        let archiveURL = root.appendingPathComponent("nested.cbz")
        try makeArchive(at: archiveURL, entries: [
            "z/webinfo.txt": Data("https://e-hentai.org/g/2/second/".utf8),
            "a/WebInfo.TXT": Data("https://e-hentai.org/g/1/first/".utf8)
        ])
        #expect(try ArchiveWebInfoReader().galleryURL(in: archiveURL, securityScopedRootURL: root)?.absoluteString == "https://e-hentai.org/g/1/first/")
    }

    @Test("missing invalid and oversized webinfo are ignored")
    func ignoresUnusableWebInfo() throws {
        let root = try temporaryRoot()
        let reader = ArchiveWebInfoReader()
        let cases: [Data?] = [
            nil,
            Data("https://example.com/g/1/token/".utf8),
            Data("http://e-hentai.org/g/1/token/".utf8),
            Data("https://e-hentai.org/g/1/token/\nhttps://e-hentai.org/g/2/token/".utf8),
            Data(repeating: 65, count: 4_097)
        ]
        for (index, webInfo) in cases.enumerated() {
            let archiveURL = root.appendingPathComponent("case-\(index).zip")
            var entries = ["001.jpg": Data("page".utf8)]
            if let webInfo { entries["webinfo.txt"] = webInfo }
            try makeArchive(at: archiveURL, entries: entries)
            #expect(try reader.galleryURL(in: archiveURL, securityScopedRootURL: root) == nil)
            #expect(try reader.galleryURLWithSystemUnzip(in: archiveURL) == nil)
        }
    }

    @Test("rejects archive paths outside the granted library root")
    func rejectsOutsideRoot() throws {
        let root = try temporaryRoot()
        let otherRoot = try temporaryRoot()
        let archiveURL = otherRoot.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: [
            "webinfo.txt": Data("https://e-hentai.org/g/1/token/".utf8)
        ])
        #expect(throws: NyaEHError.self) {
            try ArchiveWebInfoReader().galleryURL(in: archiveURL, securityScopedRootURL: root)
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = TestRunResources.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeArchive(at url: URL, entries: [String: Data]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }
}
