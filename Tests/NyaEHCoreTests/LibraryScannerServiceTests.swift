import CryptoKit
import AppKit
import Foundation
import Testing
import ZIPFoundation
@testable import NyaEHCore

@Suite("Library scanner", .serialized)
struct LibraryScannerServiceTests {
    @Test("scans zip archives into library books")
    func scansZipArchivesIntoLibraryBooks() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(
            at: archiveURL,
            entries: [
                "001.jpg": Data("page-1".utf8),
                "002.png": Data("page-2".utf8),
                "notes.txt": Data("ignore".utf8)
            ]
        )

        let result = try context.scanner.scan(rootURL: context.root)
        let books = try context.repository.fetchAll()

        #expect(result.scanned == 1)
        #expect(result.inserted == 1)
        #expect(books.count == 1)
        #expect(books[0].title == "sample")
        #expect(books[0].type == .archive)
        #expect(books[0].fileCount == 2)
        #expect(books[0].hash == sha1Hex(Data("page-1".utf8)))
        #expect(books[0].bundleSize != nil)
        #expect(books[0].status == .unscanned)
        #expect(books[0].exist)
    }

    @Test("scan reads root info json language as initial metadata hint")
    func scanReadsRootInfoJSONLanguage() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(
            at: archiveURL,
            entries: [
                "info.json": infoJSON(language: "Japanese"),
                "001.jpg": Data("page-1".utf8)
            ]
        )

        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(book.status == .unscanned)
        #expect(book.languageCode == "japanese")
        #expect(book.tags == #"["language:japanese"]"#)
    }

    @Test("scan falls back to info json language tag array")
    func scanFallsBackToInfoJSONLanguageTagArray() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(
            at: archiveURL,
            entries: [
                "nested/info.json": infoJSON(language: nil, tagLanguages: ["japanese"]),
                "001.jpg": Data("page-1".utf8)
            ]
        )

        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(book.languageCode == "japanese")
        #expect(book.tags == #"["language:japanese"]"#)
    }

    @Test("scan ignores invalid info json language values")
    func scanIgnoresInvalidInfoJSONLanguageValues() throws {
        let context = try makeContext()
        let invalidArchiveURL = context.root.appendingPathComponent("invalid.zip")
        let unknownArchiveURL = context.root.appendingPathComponent("unknown.zip")
        let missingArchiveURL = context.root.appendingPathComponent("missing.zip")
        try makeArchive(
            at: invalidArchiveURL,
            entries: [
                "info.json": Data(#"{"gallery_info":{"language":"bad:value"}}"#.utf8),
                "001.jpg": Data("page-invalid".utf8)
            ]
        )
        try makeArchive(
            at: unknownArchiveURL,
            entries: [
                "info.json": infoJSON(language: "unknown"),
                "001.jpg": Data("page-unknown".utf8)
            ]
        )
        try makeArchive(
            at: missingArchiveURL,
            entries: [
                "info.json": Data("{".utf8),
                "001.jpg": Data("page-missing".utf8)
            ]
        )

        _ = try context.scanner.scan(rootURL: context.root)
        let books = try context.repository.fetchAll()

        #expect(books.count == 3)
        #expect(books.allSatisfy { $0.languageCode == "unknown" })
        #expect(books.allSatisfy { $0.tags == "[]" })
    }

    @Test("rescanning updates the existing filepath")
    func rescanningUpdatesExistingFilepath() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.cbz")
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("page-1".utf8)])

        _ = try context.scanner.scan(rootURL: context.root)
        try makeArchive(
            at: archiveURL,
            entries: [
                "001.jpg": Data("page-1".utf8),
                "002.webp": Data("page-2".utf8)
            ]
        )

        let result = try context.scanner.scan(rootURL: context.root)
        let books = try context.repository.fetchAll()

        #expect(result.inserted == 0)
        #expect(result.updated == 1)
        #expect(books.count == 1)
        #expect(books[0].fileCount == 2)
        #expect(books[0].hash == sha1Hex(Data("page-1".utf8)))
    }

    @Test("missing source files are marked but not deleted")
    func missingSourceFilesAreMarked() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("page-1".utf8)])

        _ = try context.scanner.scan(rootURL: context.root)
        try FileManager.default.removeItem(at: archiveURL)

        let result = try context.scanner.scan(rootURL: context.root)
        let books = try context.repository.fetchAll()

        #expect(result.missing == 1)
        #expect(books.count == 1)
        #expect(books[0].status == .missing)
        #expect(!books[0].exist)
    }

    @Test("image file count ignores non-image entries")
    func imageFileCountIgnoresNonImageEntries() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(
            at: archiveURL,
            entries: [
                "001.jpg": Data("page-1".utf8),
                "002.jpeg": Data("page-2".utf8),
                "003.png": Data("page-3".utf8),
                "004.webp": Data("page-4".utf8),
                "005.gif": Data("page-5".utf8),
                "006.bmp": Data("page-6".utf8),
                "007.avif": Data("page-7".utf8),
                "metadata.json": Data("ignore".utf8)
            ]
        )

        let count = try context.scanner.imageFileCount(in: archiveURL)

        #expect(count == 7)
    }

    @Test("hash uses the eighth sorted image when available")
    func hashUsesEighthSortedImageWhenAvailable() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(
            at: archiveURL,
            entries: [
                "010.jpg": Data("page-10".utf8),
                "002.jpg": Data("page-2".utf8),
                "008.jpg": Data("page-8".utf8),
                "001.jpg": Data("page-1".utf8),
                "004.jpg": Data("page-4".utf8),
                "007.jpg": Data("page-7".utf8),
                "003.jpg": Data("page-3".utf8),
                "006.jpg": Data("page-6".utf8),
                "005.jpg": Data("page-5".utf8),
                "notes.txt": Data("ignore".utf8)
            ]
        )

        let result = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(result.inserted == 1)
        #expect(book.fileCount == 9)
        #expect(book.hash == sha1Hex(Data("page-8".utf8)))
    }

    @Test("scan caches first sorted image as jpeg cover")
    func scanCachesFirstSortedImageAsJPEGCover() throws {
        let context = try makeContext()
        let coverData = try makeJPEGData(color: .red)
        let representativeData = try makeJPEGData(color: .blue)
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(
            at: archiveURL,
            entries: [
                "008.jpg": representativeData,
                "001.jpg": coverData,
                "002.jpg": try makeJPEGData(color: .green),
                "003.jpg": try makeJPEGData(color: .yellow),
                "004.jpg": try makeJPEGData(color: .cyan),
                "005.jpg": try makeJPEGData(color: .magenta),
                "006.jpg": try makeJPEGData(color: .orange),
                "007.jpg": try makeJPEGData(color: .purple)
            ]
        )

        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)
        let coverPath = try #require(book.coverPath)
        let coverHash = try #require(book.coverHash)

        #expect(book.hash == sha1Hex(representativeData))
        #expect(coverHash == sha1Hex(coverData))
        #expect(FileManager.default.fileExists(atPath: coverPath))
        #expect(URL(fileURLWithPath: coverPath).pathExtension == "jpg")
    }

    @Test("hash uses the first sorted image when fewer than eight images exist")
    func hashUsesFirstSortedImageWhenFewerThanEightImagesExist() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(
            at: archiveURL,
            entries: [
                "003.jpg": Data("page-3".utf8),
                "001.jpg": Data("page-1".utf8),
                "002.jpg": Data("page-2".utf8)
            ]
        )

        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(book.hash == sha1Hex(Data("page-1".utf8)))
    }

    @Test("unchanged archive with existing cover cache skips archive read")
    func unchangedArchiveWithExistingCoverCacheSkipsArchiveRead() throws {
        let reader = CountingArchiveReader(
            inspection: ArchiveInspection(
                imageCount: 1,
                representativeImageSHA1: "hash-1",
                coverImageData: try makeJPEGData(color: .red)
            )
        )
        let context = try makeContext(archiveReader: reader)
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try Data("archive".utf8).write(to: archiveURL)

        _ = try context.scanner.scan(rootURL: context.root)
        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(reader.readCount == 1)
        #expect(book.hash == "hash-1")
        #expect(book.coverPath != nil)
    }

    @Test("missing cover cache triggers archive read on rescan")
    func missingCoverCacheTriggersArchiveReadOnRescan() throws {
        let reader = CountingArchiveReader(
            inspection: ArchiveInspection(
                imageCount: 1,
                representativeImageSHA1: "hash-1",
                coverImageData: try makeJPEGData(color: .red)
            )
        )
        let context = try makeContext(archiveReader: reader)
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try Data("archive".utf8).write(to: archiveURL)

        _ = try context.scanner.scan(rootURL: context.root)
        let firstBook = try #require(context.repository.fetchAll().first)
        let coverPath = try #require(firstBook.coverPath)
        try FileManager.default.removeItem(atPath: coverPath)

        _ = try context.scanner.scan(rootURL: context.root)
        let updatedBook = try #require(context.repository.fetchAll().first)

        #expect(reader.readCount == 2)
        #expect(updatedBook.coverPath != nil)
        #expect(FileManager.default.fileExists(atPath: try #require(updatedBook.coverPath)))
    }

    @Test("single book rescan forces archive read and rebuilds missing cover cache")
    func singleBookRescanForcesArchiveReadAndRebuildsCoverCache() throws {
        let reader = CountingArchiveReader(
            inspection: ArchiveInspection(
                imageCount: 1,
                representativeImageSHA1: "hash-1",
                coverImageData: try makeJPEGData(color: .red)
            )
        )
        let context = try makeContext(archiveReader: reader)
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try Data("archive".utf8).write(to: archiveURL)

        _ = try context.scanner.scan(rootURL: context.root)
        let firstBook = try #require(context.repository.fetchAll().first)
        let coverPath = try #require(firstBook.coverPath)
        try FileManager.default.removeItem(atPath: coverPath)

        let updatedBook = try context.scanner.rescanBook(firstBook)

        #expect(reader.readCount == 2)
        #expect(updatedBook.hash == "hash-1")
        #expect(FileManager.default.fileExists(atPath: try #require(updatedBook.coverPath)))
    }

    @Test("single book rescan clears stale metadata when representative hash changes")
    func singleBookRescanClearsMetadataAfterContentChange() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("old".utf8)])
        _ = try context.scanner.scan(rootURL: context.root)

        var book = try #require(context.repository.fetchAll().first)
        book.title = "Remote Title"
        book.tags = #"["female:schoolgirl"]"#
        book.status = .correct
        book.mark = true
        book.readCount = 7
        book.category = "Doujinshi"
        book = try context.repository.update(book)

        try makeArchive(
            at: archiveURL,
            entries: [
                "001.jpg": Data("new-cover".utf8),
                "002.jpg": Data("new-page".utf8)
            ]
        )

        let updatedBook = try context.scanner.rescanBook(book)

        #expect(updatedBook.hash == sha1Hex(Data("new-cover".utf8)))
        #expect(updatedBook.fileCount == 2)
        #expect(updatedBook.title == "sample")
        #expect(updatedBook.tags == #"["language:unknown"]"#)
        #expect(updatedBook.status == .unscanned)
        #expect(updatedBook.mark)
        #expect(updatedBook.readCount == 7)
        #expect(updatedBook.category == nil)
    }

    @Test("single book rescan preserves metadata when representative hash is unchanged")
    func singleBookRescanPreservesMetadataForUnchangedHash() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("same".utf8)])
        _ = try context.scanner.scan(rootURL: context.root)

        var book = try #require(context.repository.fetchAll().first)
        book.title = "Remote Title"
        book.tags = #"["female:schoolgirl"]"#
        book.status = .correct
        book.category = "Doujinshi"
        book = try context.repository.update(book)

        let updatedBook = try context.scanner.rescanBook(book)

        #expect(updatedBook.hash == sha1Hex(Data("same".utf8)))
        #expect(updatedBook.title == "Remote Title")
        #expect(updatedBook.tags == #"["female:schoolgirl"]"#)
        #expect(updatedBook.status == .correct)
        #expect(updatedBook.category == "Doujinshi")
    }

    @Test("rescan supplements only unscanned books with unknown language")
    func rescanSupplementsOnlyUnscannedBooksWithUnknownLanguage() throws {
        let context = try makeContext()
        let unscannedURL = context.root.appendingPathComponent("unscanned.zip")
        let correctURL = context.root.appendingPathComponent("correct.zip")
        let knownURL = context.root.appendingPathComponent("known.zip")
        let unscannedPath = scannerFilepath(for: unscannedURL)
        let correctPath = scannerFilepath(for: correctURL)
        let knownPath = scannerFilepath(for: knownURL)
        try makeArchive(
            at: unscannedURL,
            entries: [
                "info.json": infoJSON(language: "japanese"),
                "001.jpg": Data("page-unscanned".utf8)
            ]
        )
        try makeArchive(
            at: correctURL,
            entries: [
                "info.json": infoJSON(language: "japanese"),
                "001.jpg": Data("page-correct".utf8)
            ]
        )
        try makeArchive(
            at: knownURL,
            entries: [
                "info.json": infoJSON(language: "japanese"),
                "001.jpg": Data("page-known".utf8)
            ]
        )
        _ = try context.repository.insert(
            existingBook(
                title: "Unscanned",
                filepath: unscannedPath,
                hash: sha1Hex(Data("page-unscanned".utf8))
            )
        )
        _ = try context.repository.insert(
            existingBook(
                title: "Correct",
                filepath: correctPath,
                hash: sha1Hex(Data("page-correct".utf8)),
                status: .correct,
                tags: #"["female:schoolgirl"]"#
            )
        )
        _ = try context.repository.insert(
            existingBook(
                title: "Known",
                filepath: knownPath,
                hash: sha1Hex(Data("page-known".utf8)),
                languageCode: "chinese",
                tags: #"["language:chinese"]"#
            )
        )

        _ = try context.scanner.scan(rootURL: context.root)
        let books = try context.repository.fetchAll()
        let updatedUnscanned = try #require(books.first { $0.filepath == unscannedPath })
        let updatedCorrect = try #require(books.first { $0.filepath == correctPath })
        let updatedKnown = try #require(books.first { $0.filepath == knownPath })

        #expect(updatedUnscanned.languageCode == "japanese")
        #expect(updatedUnscanned.tags == #"["language:japanese"]"#)
        #expect(updatedCorrect.languageCode == "unknown")
        #expect(updatedCorrect.tags == #"["female:schoolgirl"]"#)
        #expect(updatedKnown.languageCode == "chinese")
        #expect(updatedKnown.tags == #"["language:chinese"]"#)
    }

    @Test("single book rescan marks missing source and throws")
    func singleBookRescanMarksMissingSourceAndThrows() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("page-1".utf8)])
        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        try FileManager.default.removeItem(at: archiveURL)

        #expect(throws: NyaEHError.self) {
            _ = try context.scanner.rescanBook(book)
        }
        let bookID = try #require(book.databaseID)
        let fetchedBook = try context.repository.fetch(id: bookID)
        let updatedBook = try #require(fetchedBook)
        #expect(updatedBook.status == .missing)
        #expect(!updatedBook.exist)
    }

    @Test("service rescan removes old unshared cover cache")
    func serviceRescanRemovesOldUnsharedCoverCache() throws {
        let coverCache = SequencedCoverCache(covers: [
            CachedCover(path: "/tmp/nyaeh-old-cover.jpg", hash: "old-cover"),
            CachedCover(path: "/tmp/nyaeh-new-cover.jpg", hash: "new-cover")
        ])
        let context = try makeContext(coverCache: coverCache)
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": try makeJPEGData(color: .red)])
        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        let service = BookLibraryService(
            bookRepository: context.repository,
            metadataRepository: context.metadataRepository,
            coverCache: coverCache
        )
        _ = try service.rescanCover(for: book)

        #expect(coverCache.removedPaths == ["/tmp/nyaeh-old-cover.jpg"])
    }

    @Test("service rescan preserves shared old cover cache")
    func serviceRescanPreservesSharedOldCoverCache() throws {
        let coverCache = SequencedCoverCache(covers: [
            CachedCover(path: "/tmp/nyaeh-shared-cover.jpg", hash: "shared-cover"),
            CachedCover(path: "/tmp/nyaeh-new-cover.jpg", hash: "new-cover")
        ])
        let context = try makeContext(coverCache: coverCache)
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": try makeJPEGData(color: .red)])
        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)
        var shared = LibraryBook(
            title: "Shared",
            coverPath: "/tmp/nyaeh-shared-cover.jpg",
            hash: "shared-hash",
            filepath: context.root.appendingPathComponent("shared.zip").path,
            type: .archive
        )
        shared.coverHash = "shared-cover"
        _ = try context.repository.insert(shared)

        let service = BookLibraryService(
            bookRepository: context.repository,
            metadataRepository: context.metadataRepository,
            coverCache: coverCache
        )
        _ = try service.rescanCover(for: book)

        #expect(coverCache.removedPaths.isEmpty)
    }

    @MainActor
    @Test("store rescan refreshes selected book")
    func storeRescanRefreshesSelectedBook() throws {
        let coverCache = SequencedCoverCache(covers: [
            CachedCover(path: "/tmp/nyaeh-old-cover.jpg", hash: "old-cover"),
            CachedCover(path: "/tmp/nyaeh-new-cover.jpg", hash: "new-cover")
        ])
        let context = try makeContext(coverCache: coverCache)
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("old".utf8)])
        _ = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("new".utf8)])
        let service = BookLibraryService(
            bookRepository: context.repository,
            metadataRepository: context.metadataRepository,
            coverCache: coverCache
        )
        let store = CatalogStore(service: service)
        store.refresh()
        store.selectedBookID = book.id

        store.rescanCover(for: book, localizer: AppLocalizer(language: .en))

        #expect(store.selectedBookID == book.id)
        #expect(store.book(id: book.id)?.hash == sha1Hex(Data("new".utf8)))
        #expect(store.coverRescanMessage == AppLocalizer(language: .en).string(.coverRescanSucceeded))
        #expect(store.loadError == nil)
    }

    @MainActor
    @Test("store scan runs asynchronously and updates state on completion")
    func storeScanRunsAsynchronouslyAndUpdatesStateOnCompletion() async throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("page-1".utf8)])
        let service = BookLibraryService(
            bookRepository: context.repository,
            metadataRepository: context.metadataRepository,
            coverCache: CoverCacheService(rootDirectory: context.root.appendingPathComponent("StoreCovers", isDirectory: true))
        )
        let store = CatalogStore(service: service)
        var completedResult: LibraryScanResult?

        store.scanLibrary(rootURL: context.root, localizer: AppLocalizer(language: .en)) { result in
            completedResult = result
        }

        #expect(store.isScanning)
        await waitForScan(store)

        #expect(!store.isScanning)
        #expect(completedResult?.inserted == 1)
        #expect(store.scanSummary == "Scanned 1 file(s), added 1, updated 0, missing 0, broken 0.")
        #expect(store.books.count == 1)
        #expect(store.loadError == nil)
    }

    @Test("service rescan requires database id")
    func serviceRescanRequiresDatabaseID() throws {
        let context = try makeContext()
        let service = BookLibraryService(
            bookRepository: context.repository,
            metadataRepository: context.metadataRepository
        )
        #expect(throws: NyaEHError.self) {
            _ = try service.rescanCover(
                for: LibraryBook(title: "Unsaved", hash: "hash", filepath: "/tmp/unsaved.zip")
            )
        }
    }

    @Test("changed archive triggers archive read on rescan")
    func changedArchiveTriggersArchiveReadOnRescan() throws {
        let reader = SequencedArchiveReader(inspections: [
            ArchiveInspection(
                imageCount: 1,
                representativeImageSHA1: "hash-1",
                coverImageData: try makeJPEGData(color: .red)
            ),
            ArchiveInspection(
                imageCount: 1,
                representativeImageSHA1: "hash-2",
                coverImageData: try makeJPEGData(color: .blue)
            )
        ])
        let context = try makeContext(archiveReader: reader)
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try Data("archive".utf8).write(to: archiveURL)

        _ = try context.scanner.scan(rootURL: context.root)
        try Data("archive changed".utf8).write(to: archiveURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: archiveURL.path
        )
        let result = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(reader.readCount == 2)
        #expect(result.updated == 1)
        #expect(book.hash == "hash-2")
    }

    @Test("system unzip fallback reads archive when primary reader fails")
    func systemUnzipFallbackReadsArchiveWhenPrimaryReaderFails() throws {
        let context = try makeContext(
            archiveReader: HybridArchiveReader(
                primary: FailingArchiveReader(),
                fallback: SystemZipArchiveReader()
            )
        )
        let archiveURL = context.root.appendingPathComponent("fallback.zip")
        try makeArchive(
            at: archiveURL,
            entries: [
                "010.jpg": Data("page-10".utf8),
                "002.jpg": Data("page-2".utf8),
                "008.jpg": Data("page-8".utf8),
                "001.jpg": Data("page-1".utf8),
                "004.jpg": Data("page-4".utf8),
                "007.jpg": Data("page-7".utf8),
                "003.jpg": Data("page-3".utf8),
                "006.jpg": Data("page-6".utf8),
                "005.jpg": Data("page-5".utf8),
                "info.json": infoJSON(language: "japanese"),
                "notes.txt": Data("ignore".utf8)
            ]
        )

        let result = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(result.inserted == 1)
        #expect(result.broken == 0)
        #expect(book.fileCount == 9)
        #expect(book.hash == sha1Hex(Data("page-8".utf8)))
        #expect(book.languageCode == "japanese")
    }

    @Test("archives without images are marked broken with fallback hash")
    func archivesWithoutImagesAreMarkedBrokenWithFallbackHash() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["notes.txt": Data("ignore".utf8)])

        let result = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(result.broken == 1)
        #expect(book.status == .broken)
        #expect(book.hash == "broken:\(book.filepath)")
    }

    @Test("one broken archive does not stop other archives")
    func oneBrokenArchiveDoesNotStopOtherArchives() throws {
        let context = try makeContext()
        let brokenURL = context.root.appendingPathComponent("broken.zip")
        let validURL = context.root.appendingPathComponent("valid.zip")
        try Data("not a zip archive".utf8).write(to: brokenURL)
        try makeArchive(at: validURL, entries: ["001.jpg": Data("page-1".utf8)])

        let result = try context.scanner.scan(rootURL: context.root)
        let books = try context.repository.fetchAll()
        let brokenBook = try #require(books.first { URL(fileURLWithPath: $0.filepath).lastPathComponent == "broken.zip" })
        let validBook = try #require(books.first { URL(fileURLWithPath: $0.filepath).lastPathComponent == "valid.zip" })

        #expect(result.scanned == 2)
        #expect(result.inserted == 1)
        #expect(result.broken == 1)
        #expect(books.count == 2)
        #expect(brokenBook.status == .broken)
        #expect(brokenBook.hash.hasPrefix("broken:"))
        #expect(validBook.status == .unscanned)
        #expect(validBook.hash == sha1Hex(Data("page-1".utf8)))
    }

    @Test("rescanning updates representative image hash")
    func rescanningUpdatesRepresentativeImageHash() throws {
        let context = try makeContext()
        let archiveURL = context.root.appendingPathComponent("sample.zip")
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("old".utf8)])

        _ = try context.scanner.scan(rootURL: context.root)
        try makeArchive(at: archiveURL, entries: ["001.jpg": Data("new".utf8)])

        let result = try context.scanner.scan(rootURL: context.root)
        let book = try #require(context.repository.fetchAll().first)

        #expect(result.updated == 1)
        #expect(book.hash == sha1Hex(Data("new".utf8)))
    }

    @Test("unique SHA1 move inherits business data and database identity")
    func uniqueHashMoveInheritsBusinessData() throws {
        let reader = CountingArchiveReader(inspection: .init(
            imageCount: 1,
            representativeImageSHA1: "move-hash",
            coverImageData: try makeJPEGData(color: .blue)
        ))
        let context = try makeContext(archiveReader: reader)
        let oldURL = context.root.appendingPathComponent("old.zip")
        let newURL = context.root.appendingPathComponent("new.zip")
        try Data("archive".utf8).write(to: oldURL)
        _ = try context.scanner.scan(rootURL: context.root)

        var original = try #require(context.repository.fetchAll().first)
        let originalID = try #require(original.databaseID)
        original.title = "Remote Metadata Title"
        original.mark = true
        original.readCount = 8
        _ = try context.repository.update(original)
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        let result = try context.scanner.scan(rootURL: context.root)
        let moved = try #require(context.repository.fetchAll().first)
        #expect(result.inserted == 0)
        #expect(result.updated == 1)
        #expect(moved.databaseID == originalID)
        #expect(moved.filepath == scannerFilepath(for: newURL))
        #expect(moved.title == "Remote Metadata Title")
        #expect(moved.mark)
        #expect(moved.readCount == 8)
        #expect(moved.exist)
    }

    @Test("duplicate SHA1 missing records are not merged automatically")
    func duplicateHashMoveIsConservative() throws {
        let reader = CountingArchiveReader(inspection: .init(
            imageCount: 1,
            representativeImageSHA1: "duplicate-hash",
            coverImageData: nil
        ))
        let context = try makeContext(archiveReader: reader)
        var first = existingBook(title: "First", filepath: "/tmp/old-first.zip", status: .missing)
        first.hash = "duplicate-hash"
        first.exist = false
        _ = try context.repository.insert(first)
        var second = existingBook(title: "Second", filepath: "/tmp/old-second.zip", status: .missing)
        second.hash = "duplicate-hash"
        second.exist = false
        _ = try context.repository.insert(second)
        try Data("new archive".utf8).write(to: context.root.appendingPathComponent("new.zip"))

        let result = try context.scanner.scan(rootURL: context.root)
        let books = try context.repository.fetchAll()
        #expect(result.inserted == 1)
        #expect(books.count == 3)
        #expect(books.filter { $0.hash == "duplicate-hash" }.count == 3)
    }

    @Test("cancelled scan commits no partial database changes")
    func cancelledScanCommitsNothing() throws {
        let context = try makeContext()
        try makeArchive(
            at: context.root.appendingPathComponent("cancel.zip"),
            entries: ["001.jpg": Data("page".utf8)]
        )

        #expect(throws: CancellationError.self) {
            _ = try context.scanner.scan(rootURL: context.root, isCancelled: { true })
        }
        #expect(try context.repository.fetchAll().isEmpty)
    }

    @Test("archive inspection uses at most three workers and commits in path order")
    func concurrentInspectionIsBoundedAndDeterministic() throws {
        let reader = ConcurrentProbeArchiveReader()
        let context = try makeContext(
            archiveReader: reader,
            maxConcurrentArchiveInspections: 3
        )
        for name in ["06", "02", "04", "01", "05", "03"] {
            try Data(name.utf8).write(to: context.root.appendingPathComponent("\(name).zip"))
        }

        let result = try context.scanner.scan(rootURL: context.root)
        let committedTitles = try context.repository.fetchAll()
            .sorted { ($0.databaseID ?? 0) < ($1.databaseID ?? 0) }
            .map(\.title)

        #expect(result.inserted == 6)
        #expect(reader.maximumActiveCount > 1)
        #expect(reader.maximumActiveCount <= 3)
        #expect(committedTitles == ["01", "02", "03", "04", "05", "06"])
    }

    private func makeContext(
        archiveReader: any ArchiveReading = HybridArchiveReader(),
        coverCache: (any CoverCaching)? = nil,
        maxConcurrentArchiveInspections: Int = 1
    ) throws -> ScannerContext {
        let root = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: root.appendingPathComponent("NyaEH.sqlite").path)
        let repository = SQLiteLibraryBookRepository(dbQueue: database.dbQueue)
        let resolvedCoverCache = coverCache ?? CoverCacheService(rootDirectory: root.appendingPathComponent("Covers", isDirectory: true))
        let metadataRepository = SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue)
        return ScannerContext(
            root: root,
            repository: repository,
            metadataRepository: metadataRepository,
            scanner: LibraryScannerService(
                repository: repository,
                archiveReader: archiveReader,
                coverCache: resolvedCoverCache,
                maxConcurrentArchiveInspections: maxConcurrentArchiveInspections
            )
        )
    }

    private func makeArchive(at url: URL, entries: [String: Data]) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

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

    private func infoJSON(language: String?, tagLanguages: [String] = []) -> Data {
        var galleryInfo: [String: Any] = [
            "tags": ["language": tagLanguages]
        ]
        if let language {
            galleryInfo["language"] = language
        }
        let object = ["gallery_info": galleryInfo]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data
    }

    private func existingBook(
        title: String,
        filepath: String,
        hash: String = "old-\(UUID().uuidString)",
        status: BookStatus = .unscanned,
        languageCode: String = "unknown",
        tags: String = "[]"
    ) -> LibraryBook {
        LibraryBook(
            title: title,
            hash: hash,
            filepath: filepath,
            type: .archive,
            status: status,
            tags: tags,
            languageCode: languageCode
        )
    }

    private func scannerFilepath(for url: URL) -> String {
        let path = url.path
        return path.hasPrefix("/var/") ? "/private\(path)" : path
    }

    private func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func waitForScan(_ store: CatalogStore) async {
        for _ in 0..<100 {
            if !store.isScanning {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeJPEGData(color: NSColor) throws -> Data {
        let size = NSSize(width: 80, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        return try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
    }
}

private struct ScannerContext {
    let root: URL
    let repository: SQLiteLibraryBookRepository
    let metadataRepository: SQLiteGalleryMetadataRepository
    let scanner: LibraryScannerService
}

private struct FailingArchiveReader: ArchiveReading {
    func inspectArchive(at archiveURL: URL) throws -> ArchiveInspection {
        throw NyaEHError.unreadableArchive(archiveURL.path)
    }
}

private final class CountingArchiveReader: ArchiveReading {
    private let inspection: ArchiveInspection
    private(set) var readCount = 0

    init(inspection: ArchiveInspection) {
        self.inspection = inspection
    }

    func inspectArchive(at archiveURL: URL) throws -> ArchiveInspection {
        readCount += 1
        return inspection
    }
}

private final class SequencedArchiveReader: ArchiveReading {
    private let inspections: [ArchiveInspection]
    private(set) var readCount = 0

    init(inspections: [ArchiveInspection]) {
        self.inspections = inspections
    }

    func inspectArchive(at archiveURL: URL) throws -> ArchiveInspection {
        let index = min(readCount, inspections.count - 1)
        readCount += 1
        return inspections[index]
    }
}

private final class ConcurrentProbeArchiveReader: ArchiveReading, @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumActive = 0

    var maximumActiveCount: Int {
        lock.withLock { maximumActive }
    }

    func inspectArchive(at archiveURL: URL) throws -> ArchiveInspection {
        lock.withLock {
            activeCount += 1
            maximumActive = max(maximumActive, activeCount)
        }
        Thread.sleep(forTimeInterval: 0.03)
        lock.withLock { activeCount -= 1 }
        return ArchiveInspection(
            imageCount: 1,
            representativeImageSHA1: "hash-\(archiveURL.deletingPathExtension().lastPathComponent)",
            coverImageData: nil
        )
    }
}

private final class SequencedCoverCache: CoverCaching {
    private var covers: [CachedCover]
    private(set) var removedPaths: [String] = []

    init(covers: [CachedCover]) {
        self.covers = covers
    }

    func cacheCover(originalData: Data) throws -> CachedCover? {
        guard !covers.isEmpty else {
            return nil
        }
        return covers.removeFirst()
    }

    func cachedCoverExists(path: String?) -> Bool {
        path != nil
    }

    func removeCachedCover(path: String?) throws {
        guard let path else {
            return
        }
        removedPaths.append(path)
    }
}
