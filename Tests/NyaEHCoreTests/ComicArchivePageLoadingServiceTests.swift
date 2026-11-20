import AppKit
import Foundation
import Testing
import ZIPFoundation
@testable import NyaEHCore

@Suite("Comic archive page loading")
struct ComicArchivePageLoadingServiceTests {
    @Test("loads supported image entries in natural path order")
    func loadsSupportedImageEntriesInNaturalPathOrder() throws {
        let archiveURL = try temporaryArchiveURL()
        try makeArchive(
            at: archiveURL,
            entries: [
                "page-10.jpg": Data("ten".utf8),
                "page-2.png": Data("two".utf8),
                "page-1.webp": Data("one".utf8),
                "notes.txt": Data("ignore".utf8)
            ]
        )

        let batch = try ComicArchivePageLoadingService().loadPages(
            from: archiveURL,
            startIndex: 0,
            limit: 10
        )

        #expect(batch.totalCount == 3)
        #expect(batch.pages.map(\.path) == ["page-1.webp", "page-2.png", "page-10.jpg"])
        #expect(batch.pages.map(\.data) == [Data("one".utf8), Data("two".utf8), Data("ten".utf8)])
    }

    @Test("loads pages in bounded batches")
    func loadsPagesInBoundedBatches() throws {
        let archiveURL = try temporaryArchiveURL()
        try makeArchive(
            at: archiveURL,
            entries: [
                "001.jpg": Data("one".utf8),
                "002.jpg": Data("two".utf8),
                "003.jpg": Data("three".utf8)
            ]
        )

        let first = try ComicArchivePageLoadingService().loadPages(
            from: archiveURL,
            startIndex: 0,
            limit: 2
        )
        let second = try ComicArchivePageLoadingService().loadPages(
            from: archiveURL,
            startIndex: first.pages.count,
            limit: 2
        )

        #expect(first.totalCount == 3)
        #expect(first.pages.map(\.index) == [0, 1])
        #expect(first.pages.map(\.path) == ["001.jpg", "002.jpg"])
        #expect(second.totalCount == 3)
        #expect(second.pages.map(\.index) == [2])
        #expect(second.pages.map(\.path) == ["003.jpg"])
    }

    @Test("reader archive session reuses one page index and loads only requested pages")
    func readerArchiveSessionLoadsRequestedPages() async throws {
        let archiveURL = try temporaryArchiveURL()
        try makeArchive(
            at: archiveURL,
            entries: [
                "001.jpg": Data("one".utf8),
                "002.jpg": Data("two".utf8),
                "003.jpg": Data("three".utf8)
            ]
        )

        let session = try ReaderArchiveSession(archiveURL: archiveURL, securityScopedRootURL: nil)
        #expect(await session.pageCount() == 3)
        let first = try await session.load(indices: [0, 2])
        let second = try await session.load(indices: [1])
        #expect(first.pages.map(\.index) == [0, 2])
        #expect(second.pages.map(\.index) == [1])
        #expect(first.totalCount == 3)
        #expect(second.totalCount == 3)
    }

    @Test("reader archive session downsamples thumbnails and isolates damaged pages")
    func readerArchiveSessionLoadsBoundedThumbnails() async throws {
        let archiveURL = try temporaryArchiveURL()
        try makeArchive(
            at: archiveURL,
            entries: [
                "001.png": try pngData(width: 800, height: 400),
                "002.jpg": Data("not-an-image".utf8)
            ]
        )

        let session = try ReaderArchiveSession(archiveURL: archiveURL, securityScopedRootURL: nil)
        let batch = await session.loadThumbnails(indices: [0, 1], maximumPixelSize: 120)
        let validThumbnail = try #require(batch.thumbnails.first { $0.index == 0 })
        let damagedThumbnail = try #require(batch.thumbnails.first { $0.index == 1 })

        #expect(batch.totalCount == 2)
        #expect(validThumbnail.image != nil)
        #expect(validThumbnail.decodedCost > 0)
        #expect(max(validThumbnail.image?.size.width ?? 0, validThumbnail.image?.size.height ?? 0) <= 120)
        #expect(damagedThumbnail.image == nil)
        #expect(damagedThumbnail.decodedCost == 0)
    }

    @Test("zero limit loads all remaining pages")
    func zeroLimitLoadsAllRemainingPages() throws {
        let archiveURL = try temporaryArchiveURL()
        try makeArchive(
            at: archiveURL,
            entries: [
                "001.jpg": Data("one".utf8),
                "002.jpg": Data("two".utf8),
                "003.jpg": Data("three".utf8)
            ]
        )

        let batch = try ComicArchivePageLoadingService().loadPages(
            from: archiveURL,
            startIndex: 1,
            limit: 0
        )

        #expect(batch.totalCount == 3)
        #expect(batch.pages.map(\.index) == [1, 2])
        #expect(batch.pages.map(\.path) == ["002.jpg", "003.jpg"])
    }

    @Test("empty archives report no supported images")
    func emptyArchivesReportNoSupportedImages() throws {
        let archiveURL = try temporaryArchiveURL()
        try makeArchive(at: archiveURL, entries: ["notes.txt": Data("ignore".utf8)])

        do {
            _ = try ComicArchivePageLoadingService().loadPages(
                from: archiveURL,
                startIndex: 0,
                limit: 100
            )
            Issue.record("Expected archiveContainsNoImages")
        } catch NyaEHError.archiveContainsNoImages {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("broken archives surface a readable failure")
    func brokenArchivesSurfaceReadableFailure() throws {
        let archiveURL = try temporaryArchiveURL()
        try Data("not a zip archive".utf8).write(to: archiveURL)

        #expect(throws: (any Error).self) {
            _ = try ComicArchivePageLoadingService().loadPages(
                from: archiveURL,
                startIndex: 0,
                limit: 100
            )
        }
    }

    @Test("missing archives include the missing path in the error")
    func missingArchivesIncludeTheMissingPathInTheError() throws {
        let archiveURL = try temporaryArchiveURL()

        do {
            _ = try ComicArchivePageLoadingService().loadPages(
                from: archiveURL,
                startIndex: 0,
                limit: 100
            )
            Issue.record("Expected unreadableArchive")
        } catch NyaEHError.unreadableArchive(let path) {
            #expect(path == archiveURL.path)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func temporaryArchiveURL() throws -> URL {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sample.zip")
    }

    private func makeArchive(at url: URL, entries: [String: Data]) throws {
        let archive = try Archive(url: url, accessMode: .create)

        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let representation = NSBitmapImageRep(cgImage: image)
        return try #require(representation.representation(using: .png, properties: [:]))
    }
}
