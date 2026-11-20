import Foundation
import GRDB
import Testing
@testable import NyaEHCore

@Suite("External library import")
struct ExternalLibraryImportServiceTests {
    @Test("imports ExHentai Manga Manager metadata conservatively")
    func importsExhentaiMangaManagerMetadataConservatively() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let hash = SyntheticImportFixture.bookA
        let book = try context.books.insert(
            sampleBook(
                title: "Scanned Title",
                hash: hash,
                filepath: "/tmp/synthetic-alpha.zip",
                tags: "[]"
            )
        )

        let result = try context.importService.importExhentaiMangaManager(from: context.fixtureURL)

        #expect(FileManager.default.fileExists(atPath: result.backupURL.path))
        #expect(result.metadataImported >= 1)
        #expect(result.booksUpdated >= 1)

        let bookID = try #require(book.databaseID)
        let fetchedBook = try context.books.fetch(id: bookID)
        let updated = try #require(fetchedBook)
        #expect(updated.title == "Scanned Title")
        #expect(updated.status == .correct)
        #expect(updated.rating == 4.16)
        #expect(updated.pages == 28)
        #expect(updated.category == "Doujinshi")
        #expect(updated.url == SyntheticImportFixture.url)
        #expect(updated.tags.contains("artist:fixture artist"))
        #expect(updated.tags.contains("group:fixture group"))
        #expect(updated.tags.contains("other:fixture tag"))
        #expect(updated.languageCode == "unknown")
        #expect(!updated.isTranslated)

        let fetchedMetadata = try context.metadata.fetch(hash: hash)
        let metadata = try #require(fetchedMetadata)
        #expect(metadata.galleryID == 900_000_001)
        #expect(metadata.galleryToken == "fixture-token")
        #expect(metadata.tags.contains("artist:fixture artist"))
    }

    @Test("preserves existing NyaEH metadata fields")
    func preservesExistingNyaEHMetadataFields() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let hash = SyntheticImportFixture.bookB
        let book = try context.books.insert(
            LibraryBook(
                title: "Scanned",
                hash: hash,
                filepath: "/tmp/existing.cbz",
                type: .archive,
                status: .correct,
                rating: 1.25,
                tags: #"["artist:local"]"#,
                titleJpn: "Local Japanese",
                pages: 12,
                category: "Local Category",
                url: "https://example.test/local"
            )
        )

        _ = try context.importService.importExhentaiMangaManager(from: context.fixtureURL)

        let bookID = try #require(book.databaseID)
        let fetchedBook = try context.books.fetch(id: bookID)
        let updated = try #require(fetchedBook)
        #expect(updated.rating == 1.25)
        #expect(updated.tags == #"["artist:local"]"#)
        #expect(updated.titleJpn == "Local Japanese")
        #expect(updated.pages == 12)
        #expect(updated.category == "Local Category")
        #expect(updated.url == "https://example.test/local")
    }

    @Test("skips duplicated source and target hashes")
    func skipsDuplicatedSourceAndTargetHashes() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let sourceDuplicateHash = SyntheticImportFixture.duplicate
        let targetDuplicateHash = SyntheticImportFixture.bookA

        let sourceDuplicateBook = try context.books.insert(
            sampleBook(hash: sourceDuplicateHash, filepath: "/tmp/source-duplicate.cbz", tags: "[]")
        )
        let targetDuplicateFirst = try context.books.insert(
            sampleBook(hash: targetDuplicateHash, filepath: "/tmp/target-duplicate-1.cbz", tags: "[]")
        )
        _ = try context.books.insert(
            sampleBook(hash: targetDuplicateHash, filepath: "/tmp/target-duplicate-2.cbz", tags: "[]")
        )

        let result = try context.importService.importExhentaiMangaManager(from: context.fixtureURL)

        #expect(result.skippedDuplicateSourceHashes >= 1)
        #expect(result.skippedDuplicateTargetHashes >= 1)
        #expect(result.skippedUnmatchedBooks > 0)

        let sourceDuplicateBookID = try #require(sourceDuplicateBook.databaseID)
        let fetchedSkippedSource = try context.books.fetch(id: sourceDuplicateBookID)
        let skippedSource = try #require(fetchedSkippedSource)
        #expect(skippedSource.status == .unscanned)
        #expect(skippedSource.tags == "[]")

        let targetDuplicateFirstID = try #require(targetDuplicateFirst.databaseID)
        let fetchedSkippedTarget = try context.books.fetch(id: targetDuplicateFirstID)
        let skippedTarget = try #require(fetchedSkippedTarget)
        #expect(skippedTarget.status == .unscanned)
        #expect(skippedTarget.tags == "[]")
    }

    @Test("imports collections by hash and preserves source order")
    func importsCollectionsByHashAndPreservesSourceOrder() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let firstHash = SyntheticImportFixture.bookB
        let secondHash = SyntheticImportFixture.bookC
        let first = try context.books.insert(sampleBook(title: "First", hash: firstHash, filepath: "/tmp/first.cbz", tags: "[]"))
        let second = try context.books.insert(sampleBook(title: "Second", hash: secondHash, filepath: "/tmp/second.cbz", tags: "[]"))

        let result = try context.importService.importExhentaiMangaManager(from: context.fixtureURL)

        #expect(result.collectionsCreated >= 1)
        #expect(result.collectionMembersImported >= 2)

        let collections = try context.collections.fetchAll()
        let collection = try #require(collections.first { $0.name == SyntheticImportFixture.collectionTitle })
        let collectionID = try #require(collection.databaseID)
        let members = try context.books.fetchByCollectionID(collectionID)
        #expect(members.map(\.databaseID).prefix(2) == [first.databaseID, second.databaseID])
        #expect(members[0].collectionOrder == 0)
        #expect(members[1].collectionOrder == 1)
        #expect(members[0].hiddenBook)
        #expect(members[1].hiddenBook)
    }

    @Test("external membership applies to a complete version group and skips an occupied group")
    func importsLogicalSeriesMembers() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let first = try context.books.insert(sampleBook(title: "First",
            hash: SyntheticImportFixture.bookB, filepath: "/tmp/grouped-first.cbz", tags: "[]"))
        let alternate = try context.books.insert(sampleBook(title: "Alternate",
            hash: "local-alternate", filepath: "/tmp/grouped-alt.cbz", tags: "[]"))
        let firstID = try #require(first.databaseID)
        let alternateID = try #require(alternate.databaseID)
        _ = try context.versionGroups.createVersionGroup(bookIDs: [alternateID, firstID])

        let result = try context.importService.importExhentaiMangaManager(from: context.fixtureURL)
        let imported = try #require(context.collections.fetchAll().first { $0.name == SyntheticImportFixture.collectionTitle }?.databaseID)
        let versions = try context.books.fetchByCollectionID(imported)
        #expect(Set(versions.compactMap(\.databaseID)) == [firstID, alternateID])
        #expect(versions.allSatisfy { $0.collectionOrder == 0 && $0.hiddenBook })

        let protected = try #require(context.collections.insert(BookCollection(name: "Local")).databaseID)
        try context.collections.addBookAndVersions(bookID: alternateID, to: protected)
        let secondImport = try context.importService.importExhentaiMangaManager(from: context.fixtureURL)
        #expect(secondImport.skippedCollectionMembers > result.skippedCollectionMembers)
        #expect(try context.books.fetchByCollectionID(imported).isEmpty)
        #expect(try context.books.fetchByCollectionID(protected).count == 2)
    }

    private func sampleBook(
        title: String = "Scanned Book",
        hash: String,
        filepath: String,
        tags: String
    ) -> LibraryBook {
        LibraryBook(
            title: title,
            hash: hash,
            filepath: filepath,
            type: .archive,
            fileCount: 1,
            bundleSize: 10,
            mtime: 1,
            status: .unscanned,
            date: 1,
            tags: tags
        )
    }

    private func makeContext() throws -> ImportRepositoryContext {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appDataURL = directory.appendingPathComponent("AppData", isDirectory: true)
        try FileManager.default.createDirectory(at: appDataURL, withIntermediateDirectories: true)
        let fixtureURL = directory.appendingPathComponent("Import", isDirectory: true)
        try SyntheticImportFixture.make(at: fixtureURL)
        let databaseURL = directory.appendingPathComponent("NyaEH.sqlite")
        let database = try DatabaseManager(path: databaseURL.path)
        return ImportRepositoryContext(
            directory: directory,
            fixtureURL: fixtureURL,
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            metadata: SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue),
            tags: SQLiteTagRepository(dbQueue: database.dbQueue),
            collections: SQLiteCollectionRepository(dbQueue: database.dbQueue),
            versionGroups: SQLiteVersionGroupRepository(dbQueue: database.dbQueue),
            importService: ExternalLibraryImportService(
                dbQueue: database.dbQueue,
                databasePath: database.path,
                appDataURL: appDataURL
            )
        )
    }
}

private struct ImportRepositoryContext {
    let directory: URL
    let fixtureURL: URL
    let books: SQLiteLibraryBookRepository
    let metadata: SQLiteGalleryMetadataRepository
    let tags: SQLiteTagRepository
    let collections: SQLiteCollectionRepository
    let versionGroups: SQLiteVersionGroupRepository
    let importService: ExternalLibraryImportService
}
