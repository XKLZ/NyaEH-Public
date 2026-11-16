import AppKit
import Foundation
import GRDB
import Testing
import UniformTypeIdentifiers
@testable import NyaEHCore

@Suite("SQLite book repositories")
struct SQLiteLibraryBookRepositoryTests {
    @Test("inserts and fetches library books")
    func insertsAndFetchesLibraryBooks() throws {
        let context = try makeContext()
        let inserted = try context.books.insert(sampleBook())

        #expect(inserted.databaseID != nil)

        let books = try context.books.fetchAll()
        #expect(books.count == 1)
        #expect(books[0].title == "Sample Book")
        #expect(books[0].filepath == "/tmp/sample.cbz")
        #expect(books[0].hash == "sha1-sample")
        #expect(books[0].languageCode == "unknown")
        #expect(!books[0].isTranslated)
        #expect(!books[0].isFullColor)
        #expect(books[0].censorship == "unknown")
        #expect(!books[0].hasExtraneousAds)
        #expect(books[0].lastReadAt == nil)
    }

    @Test("enforces unique filepaths")
    func enforcesUniqueFilepaths() throws {
        let context = try makeContext()
        _ = try context.books.insert(sampleBook())

        #expect(throws: Error.self) {
            _ = try context.books.insert(sampleBook(title: "Duplicate"))
        }
    }

    @Test("updates local management fields")
    func updatesLocalManagementFields() throws {
        let context = try makeContext()
        var book = try context.books.insert(sampleBook())

        book.mark = true
        book.hiddenBook = true
        book.readCount = 3
        book.lastReadAt = 1_775_657_600_000
        book.status = .broken
        let updated = try context.books.update(book)

        #expect(updated.mark)
        #expect(updated.hiddenBook)
        #expect(updated.readCount == 3)
        #expect(updated.lastReadAt == 1_775_657_600_000)
        #expect(updated.status == .broken)

        let fetched = try context.books.fetch(id: updated.databaseID!)!
        #expect(fetched.mark)
        #expect(fetched.hiddenBook)
        #expect(fetched.readCount == 3)
        #expect(fetched.lastReadAt == 1_775_657_600_000)
        #expect(fetched.status == .broken)
    }

    @Test("increments read count atomically")
    func incrementsReadCountAtomically() throws {
        let context = try makeContext()
        let inserted = try context.books.insert(sampleBook())
        let bookID = try #require(inserted.databaseID)
        let originalUpdatedAt = inserted.updatedAt

        let firstReadResult = try context.books.incrementReadCount(bookID: bookID)
        let firstRead = try #require(firstReadResult)
        #expect(firstRead.readCount == 1)
        #expect(firstRead.lastReadAt != nil)
        #expect(firstRead.updatedAt >= originalUpdatedAt)
        let firstLastReadAt = try #require(firstRead.lastReadAt)

        let secondReadResult = try context.books.incrementReadCount(bookID: bookID)
        let secondRead = try #require(secondReadResult)
        #expect(secondRead.readCount == 2)
        let secondLastReadAt = try #require(secondRead.lastReadAt)
        #expect(secondLastReadAt >= firstLastReadAt)

        let fetchedResult = try context.books.fetch(id: bookID)
        let fetched = try #require(fetchedResult)
        #expect(fetched.readCount == 2)
        #expect(fetched.lastReadAt == secondRead.lastReadAt)
    }

    @Test("reading progress persists, clamps pages, and resets")
    func readingProgressPersistsAndResets() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        let completedAt = Timestamp.nowMilliseconds()

        let saved = try context.readingStates.save(.init(
            bookID: bookID,
            currentPageIndex: 99,
            totalPages: 10,
            updatedAt: 0,
            completedAt: completedAt
        ))
        #expect(saved.currentPageIndex == 9)
        #expect(saved.completedAt == completedAt)
        #expect(try context.readingStates.fetch(bookID: bookID) == saved)

        try context.readingStates.reset(bookID: bookID)
        #expect(try context.readingStates.fetch(bookID: bookID) == nil)
    }

    @Test("new databases include library sort indexes")
    func newDatabasesIncludeLibrarySortIndexes() throws {
        let context = try makeContext()

        let indexes = try context.database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }

        #expect(indexes.contains("idx_library_books_date_title"))
        #expect(indexes.contains("idx_library_books_hash_date"))
        #expect(indexes.contains("idx_library_books_last_read_at"))
        #expect(indexes.contains("idx_library_books_visible_posted"))
        #expect(indexes.contains("idx_library_books_visible_added"))
        #expect(indexes.contains("idx_library_books_visible_title"))
        #expect(indexes.contains("idx_library_books_search_entity"))
        #expect(indexes.contains("idx_library_books_search_posted"))
        #expect(indexes.contains("idx_library_books_search_added"))
        #expect(indexes.contains("idx_library_books_search_title"))
        #expect(indexes.contains("idx_library_books_search_status_posted"))
        #expect(indexes.contains("idx_library_books_search_mark_posted"))
    }

    @Test("visible search default ordering uses expression index without temporary sort")
    func visibleSearchDefaultOrderingUsesExpressionIndex() throws {
        let context = try makeContext()
        _ = try context.books.insert(sampleBook(title: "B", filepath: "/tmp/visible-b.cbz"))
        _ = try context.books.insert(sampleBook(title: "A", filepath: "/tmp/visible-a.cbz"))

        let plan = try context.database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id, title
                    FROM library_books
                    WHERE hidden_book = 0 AND is_user_hidden = 0
                    ORDER BY COALESCE(posted, date) DESC,
                             title COLLATE NOCASE ASC,
                             id ASC
                    LIMIT 30
                    """
            ).map { $0["detail"] as String }
        }.joined(separator: "\n")

        #expect(plan.contains("idx_library_books_visible_posted"))
        #expect(!plan.localizedCaseInsensitiveContains("USE TEMP B-TREE"))
    }

    @Test("entity search ordering uses the user-visible expression index")
    func entitySearchOrderingUsesExpressionIndex() throws {
        let context = try makeContext()
        _ = try context.books.insert(sampleBook(title: "B", filepath: "/tmp/entity-b.cbz"))
        _ = try context.books.insert(sampleBook(title: "A", filepath: "/tmp/entity-a.cbz"))

        let plan = try context.database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id, title
                    FROM library_books
                    WHERE is_user_hidden = 0
                    ORDER BY COALESCE(posted, date) DESC,
                             title COLLATE NOCASE ASC,
                             id ASC
                    LIMIT 30
                    """
            ).map { $0["detail"] as String }
        }.joined(separator: "\n")

        #expect(plan.contains("idx_library_books_search_posted"))
        #expect(!plan.localizedCaseInsensitiveContains("USE TEMP B-TREE"))
    }

    @Test("library date title ordering uses index without temporary sort")
    func libraryDateTitleOrderingUsesIndexWithoutTemporarySort() throws {
        let context = try makeContext()
        _ = try context.books.insert(sampleBook(title: "B", filepath: "/tmp/b.cbz"))
        _ = try context.books.insert(sampleBook(title: "A", filepath: "/tmp/a.cbz"))

        let plan = try context.database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id, title, date
                    FROM library_books
                    ORDER BY date DESC, title COLLATE NOCASE ASC
                    """
            )
            .map { row in row["detail"] as String }
        }.joined(separator: "\n")

        #expect(plan.contains("idx_library_books_date_title"))
        #expect(!plan.localizedCaseInsensitiveContains("USE TEMP B-TREE"))
    }

    @Test("database maintenance checks report clean temporary database")
    func databaseMaintenanceChecksReportCleanTemporaryDatabase() throws {
        let context = try makeContext()
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            databaseManager: context.database,
            coverCache: nil
        )

        #expect(try service.databaseIntegrityCheck() == ["ok"])
        #expect(try service.databaseForeignKeyCheck().isEmpty)
        try service.vacuumDatabase()
    }

    @Test("empty markMissingExcept marks all books missing by design")
    func emptyMarkMissingExceptMarksAllBooksMissingByDesign() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/empty-mark-first.cbz"))
        let second = try context.books.insert(sampleBook(title: "Second", filepath: "/tmp/empty-mark-second.cbz"))

        try context.books.markMissingExcept(filepaths: [])

        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let updatedFirst = try #require(try context.books.fetch(id: firstID))
        let updatedSecond = try #require(try context.books.fetch(id: secondID))
        #expect(updatedFirst.status == .missing)
        #expect(!updatedFirst.exist)
        #expect(updatedSecond.status == .missing)
        #expect(!updatedSecond.exist)
    }

    @Test("deleting a book cascades indexes and removes empty recommendation parents")
    func deletingBookCascadesIndexesAndRemovesEmptyRecommendationParents() throws {
        let context = try makeContext()
        let book = try context.books.insert(
            sampleBook(
                title: "Delete Me",
                filepath: "/tmp/delete-cascade.cbz",
                tags: #"["parody:source","character:hero"]"#
            )
        )
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(forBookID: bookID, tagsJSON: book.tags)
        try context.versionLabels.replaceLabels(["原始"], bookID: bookID)

        try context.database.dbQueue.write { db in
            guard let parodyTagID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tags WHERE raw_value = 'parody:source'"
            ) else {
                throw NyaEHError.databaseInvariantViolation("Expected parody tag for delete cascade test.")
            }
            guard let characterTagID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tags WHERE raw_value = 'character:hero'"
            ) else {
                throw NyaEHError.databaseInvariantViolation("Expected character tag for delete cascade test.")
            }
            try db.execute(
                sql: """
                    INSERT INTO book_work_character_links (
                        book_id, parody_tag_id, character_tag_id, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [bookID, parodyTagID, characterTagID, 1, 1]
            )

            try db.execute(sql: "INSERT INTO version_recommendation_batches (id, created_at, completed_at) VALUES (1, 1, 1)")
            try db.execute(
                sql: """
                    INSERT INTO version_recommendations (
                        id, batch_id, kind, score, reasons, fingerprint, status, created_at, updated_at
                    )
                    VALUES (1, 1, 'createGroup', 10, '[]', 'version-delete-cascade', 'pending', 1, 1)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO version_recommendation_members (recommendation_id, book_id, position)
                    VALUES (1, ?, 0)
                    """,
                arguments: [bookID]
            )

            try db.execute(sql: "INSERT INTO collection_recommendation_batches (id, created_at, completed_at) VALUES (1, 1, 1)")
            try db.execute(
                sql: """
                    INSERT INTO collection_recommendations (
                        id, batch_id, kind, score, reasons, fingerprint, status, created_at, updated_at
                    )
                    VALUES (1, 1, 'createCollection', 10, '[]', 'collection-delete-cascade', 'pending', 1, 1)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO collection_recommendation_members (recommendation_id, book_id, position)
                    VALUES (1, ?, 0)
                    """,
                arguments: [bookID]
            )
        }

        try context.books.delete(id: bookID)

        let counts = try context.database.dbQueue.read { db in
            (
                bookTags: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_tags WHERE book_id = ?", arguments: [bookID]) ?? -1,
                versionLabels: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_version_labels WHERE book_id = ?", arguments: [bookID]) ?? -1,
                workCharacterLinks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_work_character_links WHERE book_id = ?", arguments: [bookID]) ?? -1,
                versionRecommendations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM version_recommendations WHERE id = 1") ?? -1,
                collectionRecommendations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_recommendations WHERE id = 1") ?? -1
            )
        }
        #expect(counts.bookTags == 0)
        #expect(counts.versionLabels == 0)
        #expect(counts.workCharacterLinks == 0)
        #expect(counts.versionRecommendations == 0)
        #expect(counts.collectionRecommendations == 0)
    }

    @Test("library service deletes cover vector cache after database delete")
    func libraryServiceDeletesCoverVectorCacheAfterDatabaseDelete() throws {
        let context = try makeContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.cbz")
        try Data("archive".utf8).write(to: sourceURL)
        let book = try context.books.insert(sampleBook(filepath: sourceURL.path))
        let bookID = try #require(book.databaseID)
        let coverVectors = SpyCoverVectorRepository()
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            coverVectorRepository: coverVectors,
            coverCache: nil
        )

        try service.deleteBookAndSourceFile(book)

        #expect(try context.books.fetch(id: bookID) == nil)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(coverVectors.deletedBookIDs == [bookID])
    }

    @Test("cover image search returns visible existing books within the distance threshold")
    func coverImageSearchReturnsVisibleExistingBooksWithinThreshold() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(
            title: "Nearest",
            hash: "sha1-cover-search-nearest",
            filepath: "/tmp/cover-search-nearest.cbz"
        ))
        let second = try context.books.insert(sampleBook(
            title: "Second",
            hash: "sha1-cover-search-second",
            filepath: "/tmp/cover-search-second.cbz"
        ))
        var hidden = try context.books.insert(sampleBook(
            title: "Hidden",
            hash: "sha1-cover-search-hidden",
            filepath: "/tmp/cover-search-hidden.cbz"
        ))
        hidden.isUserHidden = true
        hidden = try context.books.update(hidden)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vectors = try SQLiteCoverVectorRepository(
            path: directory.appendingPathComponent("CoverVectors.sqlite").path
        )
        try vectors.upsertVector(testCoverVector(bookID: try #require(first.databaseID), values: [0, 0, 0, 0]))
        try vectors.upsertVector(testCoverVector(bookID: try #require(second.databaseID), values: [2, 0, 0, 0]))
        try vectors.upsertVector(testCoverVector(bookID: try #require(hidden.databaseID), values: [0.1, 0, 0, 0]))

        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            coverVectorRepository: vectors,
            coverFeatureQueryGenerator: FakeCoverFeatureQueryGenerator(values: [0, 0, 0, 0]),
            coverCache: nil
        )

        let matches = try service.searchByCoverImage(data: Data([1]))

        #expect(matches.map(\.book.title) == ["Nearest", "Second"])
        #expect(matches.map(\.distance) == [0, 4])
    }

    @MainActor
    @Test("store publishes cover image results in similarity order")
    func storePublishesCoverImageResultsInSimilarityOrder() async throws {
        let context = try makeContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queryURL = directory.appendingPathComponent("query.jpg")
        try Data([1, 2, 3]).write(to: queryURL)

        var firstBook = sampleBook(
            title: "Nearest",
            hash: "sha1-store-cover-nearest",
            filepath: "/tmp/store-cover-nearest.cbz"
        )
        firstBook.coverPath = "/tmp/store-cover-nearest.jpg"
        firstBook.coverHash = "cover-nearest"
        let first = try context.books.insert(firstBook)

        var secondBook = sampleBook(
            title: "Second",
            hash: "sha1-store-cover-second",
            filepath: "/tmp/store-cover-second.cbz"
        )
        secondBook.coverPath = "/tmp/store-cover-second.jpg"
        secondBook.coverHash = "cover-second"
        let second = try context.books.insert(secondBook)

        let vectors = try SQLiteCoverVectorRepository(
            path: directory.appendingPathComponent("CoverVectors.sqlite").path
        )
        try vectors.upsertVector(CoverFeatureVector(
            bookID: try #require(first.databaseID),
            coverHash: "cover-nearest",
            visionRevision: 1,
            elementType: 1,
            elementCount: 4,
            featureData: [Float(0), 0, 0, 0].withUnsafeBufferPointer { Data(buffer: $0) }
        ))
        try vectors.upsertVector(CoverFeatureVector(
            bookID: try #require(second.databaseID),
            coverHash: "cover-second",
            visionRevision: 1,
            elementType: 1,
            elementCount: 4,
            featureData: [Float(3), 0, 0, 0].withUnsafeBufferPointer { Data(buffer: $0) }
        ))

        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                coverVectorRepository: vectors,
                coverFeatureQueryGenerator: FakeCoverFeatureQueryGenerator(values: [0, 0, 0, 0]),
                coverCache: nil
            )
        )
        store.refresh()
        store.advancedSearchScope = .hidden
        store.advancedSearchPage = 4

        store.searchByCoverImage(at: queryURL, localizer: AppLocalizer(language: .zhHans))
        #expect(store.isCoverImageSearchActive)
        #expect(store.advancedSearchPage == 1)
        #expect(!AdvancedSearchInteractionPolicy.shouldSubmitOrdinarySearch(
            isCoverImageSearchActive: store.isCoverImageSearchActive
        ))
        for _ in 0..<100 where store.isCoverImageSearchLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.isCoverImageSearchActive)
        #expect(!store.isCoverImageSearchLoading)
        #expect(store.advancedSearchResults.map(\.title) == ["Nearest", "Second"])
        #expect(store.advancedSearchHits.map(\.similarityDistance) == [0, 9])
        #expect(store.advancedSearchTotalCount == 2)

        store.searchByCoverImage(
            data: Data([4, 5, 6]),
            fileName: "first-drop.png",
            localizer: AppLocalizer(language: .zhHans)
        )
        store.searchByCoverImage(
            data: Data([7, 8, 9]),
            fileName: "latest-drop.png",
            localizer: AppLocalizer(language: .zhHans)
        )
        #expect(store.coverImageSearchFileName == "latest-drop.png")
        for _ in 0..<100 where store.isCoverImageSearchLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.coverImageSearchFileName == "latest-drop.png")
        #expect(store.advancedSearchResults.map(\.title) == ["Nearest", "Second"])
    }

    @Test("inserts and fetches gallery metadata by hash")
    func insertsAndFetchesGalleryMetadata() throws {
        let context = try makeContext()
        let metadata = try context.metadata.upsert(
            GalleryMetadata(
                hash: "sha1-sample",
                galleryID: 123,
                galleryToken: "token",
                title: "Remote Title",
                status: .correct,
                rating: 4.5,
                tags: "[\"language:chinese\"]",
                pages: 42,
                posted: 1_700_000_000,
                filesize: 123_456,
                category: "Doujinshi",
                url: "https://e-hentai.org/g/123/token/"
            )
        )

        #expect(metadata.hash == "sha1-sample")

        let fetched = try context.metadata.fetch(hash: "sha1-sample")
        #expect(fetched?.galleryID == 123)
        #expect(fetched?.galleryToken == "token")
        #expect(fetched?.status == .correct)
    }

    @Test("migrates existing v2 database to tag indexing schema")
    func migratesExistingV2DatabaseToTagIndexingSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("NyaEH.sqlite")

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.execute(sql: legacyV2SchemaSQL)
            try db.execute(
                sql: """
                    INSERT INTO grdb_migrations (identifier)
                    VALUES ('v1_initial_library'), ('v2_book_library_schema')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO library_books (
                        title, hash, filepath, type, status, date, tags, exist, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "Legacy Book",
                    "legacy-hash",
                    "/tmp/legacy.zip",
                    BookType.archive.rawValue,
                    BookStatus.unscanned.rawValue,
                    1_775_657_594_420,
                    #"["language:chinese"]"#,
                    1,
                    1_775_657_594_420,
                    1_775_657_594_420
                ]
            )
        }

        let database = try DatabaseManager(path: databaseURL.path)
        let repository = SQLiteLibraryBookRepository(dbQueue: database.dbQueue)
        let books = try repository.fetchAll()

        #expect(books.count == 1)
        #expect(books[0].title == "Legacy Book")
        #expect(books[0].languageCode == "unknown")
        #expect(!books[0].isTranslated)

        try database.dbQueue.read { db in
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            #expect(migrations.contains("v3_tag_indexing"))
            #expect(migrations.contains("v18_search_entity_indexes"))
            #expect(try db.tableExists("tags"))
            #expect(try db.tableExists("book_tags"))
            #expect(try db.tableExists("tag_translations"))
            #expect(try db.tableExists("followed_tags"))
            let columns = try db.columns(in: "library_books").map(\.name)
            #expect(columns.contains("language_code"))
            #expect(columns.contains("is_translated"))
            #expect(columns.contains("is_full_color"))
            #expect(columns.contains("censorship"))
            #expect(columns.contains("has_extraneous_ads"))
            #expect(columns.contains("collection_id"))
            #expect(columns.contains("collection_order"))
            #expect(columns.contains("version_group_id"))
            #expect(columns.contains("is_primary_version"))
            #expect(columns.contains("version_label"))
            #expect(columns.contains("is_user_hidden"))
            #expect(try db.tableExists("book_reading_state"))
            #expect(try db.tableExists("book_collections"))
            #expect(try db.tableExists("book_version_groups"))
            #expect(try db.tableExists("version_label_suggestions"))
            #expect(try db.tableExists("book_version_labels"))
            #expect(try db.tableExists("version_recommendation_batches"))
            #expect(try db.tableExists("version_recommendations"))
            #expect(try db.tableExists("version_recommendation_members"))
            #expect(try db.tableExists("collection_recommendation_batches"))
            #expect(try db.tableExists("collection_recommendations"))
            #expect(try db.tableExists("collection_recommendation_members"))
            #expect(try db.tableExists("import_pipeline_batches"))
            #expect(try db.tableExists("import_pipeline_items"))
            #expect(try db.tableExists("tag_visual_profiles"))
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
            #expect(indexes.contains("idx_library_books_date_title"))
            #expect(indexes.contains("idx_library_books_hash_date"))
            let visualColumns = try db.columns(in: "tag_visual_profiles").map(\.name)
            #expect(visualColumns.contains("background_asset_path"))
            #expect(visualColumns.contains("background_scale"))
            #expect(visualColumns.contains("background_offset_x"))
            #expect(visualColumns.contains("background_offset_y"))
        }

        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        let backupPackages = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("preMigration-") }
        let package = try #require(backupPackages.first)
        let manifest = try JSONDecoder().decode(
            LibraryBackupManifest.self,
            from: Data(contentsOf: package.appendingPathComponent(LibraryBackupService.manifestFilename))
        )
        #expect(manifest.kind == .preMigration)
        #expect(manifest.schemaVersion == 2)
        #expect(FileManager.default.fileExists(
            atPath: package.appendingPathComponent(LibraryBackupService.databaseFilename).path
        ))
    }

    @Test("collection membership hides grouped books and display shows collection")
    @MainActor
    func collectionMembershipHidesGroupedBooksAndDisplayShowsCollection() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/first.cbz"))
        let second = try context.books.insert(sampleBook(title: "Second", filepath: "/tmp/second.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let collection = try service.createCollection(name: "Series")

        try service.addBook(first, to: collection)

        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let fetchedHidden = try context.books.fetch(id: firstID)
        let fetchedVisible = try context.books.fetch(id: secondID)
        let hidden = try #require(fetchedHidden)
        let visible = try #require(fetchedVisible)
        #expect(hidden.hiddenBook)
        #expect(hidden.collectionID == collection.databaseID)
        #expect(!visible.hiddenBook)

        let store = CatalogStore(service: service)
        store.refresh()
        #expect(store.displayItems.contains { if case .collection = $0 { true } else { false } })
        #expect(store.displayItems.contains { if case .book(let book) = $0 { book.id == second.id } else { false } })
        #expect(!store.displayItems.contains { if case .book(let book) = $0 { book.id == first.id } else { false } })
    }

    @Test("version group hides secondary versions and promotes replacement primary")
    func versionGroupHidesSecondaryVersionsAndPromotesReplacementPrimary() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "Japanese", filepath: "/tmp/jp.cbz"))
        let second = try context.books.insert(sampleBook(title: "Chinese", filepath: "/tmp/zh.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [first])

        try service.addBook(second, toVersionGroup: group)

        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let fetchedPrimary = try context.books.fetch(id: firstID)
        let fetchedSecondary = try context.books.fetch(id: secondID)
        let primary = try #require(fetchedPrimary)
        let secondary = try #require(fetchedSecondary)
        #expect(primary.isPrimaryVersion)
        #expect(!primary.hiddenBook)
        #expect(!secondary.isPrimaryVersion)
        #expect(secondary.hiddenBook)

        try service.removeBookFromVersionGroup(primary)

        let fetchedPromoted = try context.books.fetch(id: secondID)
        let promoted = try #require(fetchedPromoted)
        #expect(promoted.versionGroupID == nil)
        #expect(promoted.isPrimaryVersion)
        #expect(!promoted.hiddenBook)
        #expect(try context.versionGroups.fetchAll().isEmpty)
    }

    @Test("version group synchronizes marked state")
    func versionGroupSynchronizesMarkedState() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/primary.cbz"))
        let second = try context.books.insert(sampleBook(title: "Secondary", filepath: "/tmp/secondary.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [first])
        try service.addBook(second, toVersionGroup: group)

        _ = try service.setMarked(true, for: second)

        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        #expect(try context.books.fetch(id: firstID)?.mark == true)
        #expect(try context.books.fetch(id: secondID)?.mark == true)
    }

    @Test("manual version group creation promotes marked member to whole group")
    func manualVersionGroupCreationPromotesMarkedMemberToWholeGroup() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/marked-create-a.cbz"))
        var markedInput = sampleBook(title: "Secondary", filepath: "/tmp/marked-create-b.cbz")
        markedInput.mark = true
        let second = try context.books.insert(markedInput)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )

        _ = try service.createVersionGroup(with: [first, second])

        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        #expect(try context.books.fetch(id: firstID)?.mark == true)
        #expect(try context.books.fetch(id: secondID)?.mark == true)
    }

    @Test("manual version group add promotes marked candidate to whole group")
    func manualVersionGroupAddPromotesMarkedCandidateToWholeGroup() throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/marked-add-a.cbz"))
        var markedInput = sampleBook(title: "Secondary", filepath: "/tmp/marked-add-b.cbz")
        markedInput.mark = true
        let secondary = try context.books.insert(markedInput)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [primary])

        try service.addBook(secondary, toVersionGroup: group)

        let primaryID = try #require(primary.databaseID)
        let secondaryID = try #require(secondary.databaseID)
        #expect(try context.books.fetch(id: primaryID)?.mark == true)
        #expect(try context.books.fetch(id: secondaryID)?.mark == true)
    }

    @Test("accepting create recommendation promotes marked member to whole group")
    func acceptingCreateRecommendationPromotesMarkedMemberToWholeGroup() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "Story", filepath: "/tmp/marked-rec-create-a.cbz"))
        var markedInput = sampleBook(title: "Story Chinese", filepath: "/tmp/marked-rec-create-b.cbz")
        markedInput.mark = true
        let second = try context.books.insert(markedInput)
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        try context.versionRecommendations.replacePending(with: [
            VersionRecommendationCandidate(
                kind: .createGroup,
                targetVersionGroupID: nil,
                bookIDs: [firstID, secondID],
                score: 100,
                reasons: ["title"],
                fingerprint: "marked-create"
            )
        ])
        let recommendation = try #require(try context.versionRecommendations.fetchPending(
            kind: .createGroup,
            targetVersionGroupID: nil
        ).first)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels,
            versionRecommendationRepository: context.versionRecommendations
        )

        _ = try service.acceptCreateVersionGroupRecommendation(recommendation, books: [first, second])

        #expect(try context.books.fetch(id: firstID)?.mark == true)
        #expect(try context.books.fetch(id: secondID)?.mark == true)
    }

    @Test("accepting add recommendation synchronizes marked state in both directions")
    func acceptingAddRecommendationSynchronizesMarkedStateInBothDirections() throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/marked-rec-add-a.cbz"))
        var markedInput = sampleBook(title: "Candidate", filepath: "/tmp/marked-rec-add-b.cbz")
        markedInput.mark = true
        let candidate = try context.books.insert(markedInput)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels,
            versionRecommendationRepository: context.versionRecommendations
        )
        let group = try service.createVersionGroup(with: [primary])
        let groupID = try #require(group.databaseID)
        let candidateID = try #require(candidate.databaseID)
        try context.versionRecommendations.replacePending(with: [
            VersionRecommendationCandidate(
                kind: .addToGroup,
                targetVersionGroupID: groupID,
                bookIDs: [candidateID],
                score: 100,
                reasons: ["cover"],
                fingerprint: "marked-add"
            )
        ])
        let recommendation = try #require(try context.versionRecommendations.fetchPending(
            kind: .addToGroup,
            targetVersionGroupID: groupID
        ).first)

        try service.acceptAddToVersionGroupRecommendation(recommendation, book: candidate, group: group)

        let primaryID = try #require(primary.databaseID)
        #expect(try context.books.fetch(id: primaryID)?.mark == true)
        #expect(try context.books.fetch(id: candidateID)?.mark == true)
    }

    @Test("repairing version group marked state uses marked-first synchronization")
    func repairingVersionGroupMarkedStateUsesMarkedFirstSynchronization() throws {
        let context = try makeContext()
        var markedInput = sampleBook(title: "Marked", filepath: "/tmp/marked-repair-a.cbz")
        markedInput.mark = true
        let marked = try context.books.insert(markedInput)
        let unmarked = try context.books.insert(sampleBook(title: "Unmarked", filepath: "/tmp/marked-repair-b.cbz"))
        let untouchedA = try context.books.insert(sampleBook(title: "Untouched A", filepath: "/tmp/marked-repair-c.cbz"))
        let untouchedB = try context.books.insert(sampleBook(title: "Untouched B", filepath: "/tmp/marked-repair-d.cbz"))
        let groupA = try context.versionGroups.insert(BookVersionGroup())
        let groupB = try context.versionGroups.insert(BookVersionGroup())
        let groupAID = try #require(groupA.databaseID)
        let groupBID = try #require(groupB.databaseID)
        let markedID = try #require(marked.databaseID)
        let unmarkedID = try #require(unmarked.databaseID)
        let untouchedAID = try #require(untouchedA.databaseID)
        let untouchedBID = try #require(untouchedB.databaseID)
        try context.database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE library_books SET version_group_id = ?, is_primary_version = 1 WHERE id = ?",
                arguments: [groupAID, markedID]
            )
            try db.execute(
                sql: "UPDATE library_books SET version_group_id = ?, is_primary_version = 0, hidden_book = 1 WHERE id = ?",
                arguments: [groupAID, unmarkedID]
            )
            try db.execute(
                sql: "UPDATE library_books SET version_group_id = ?, is_primary_version = 1 WHERE id = ?",
                arguments: [groupBID, untouchedAID]
            )
            try db.execute(
                sql: "UPDATE library_books SET version_group_id = ?, is_primary_version = 0, hidden_book = 1 WHERE id = ?",
                arguments: [groupBID, untouchedBID]
            )
        }
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )

        let result = try service.repairVersionGroupMarkedState()

        #expect(result == VersionGroupMarkedRepairResult(
            checkedVersionGroups: 2,
            repairedVersionGroups: 1,
            updatedBooks: 1
        ))
        #expect(try context.books.fetch(id: markedID)?.mark == true)
        #expect(try context.books.fetch(id: unmarkedID)?.mark == true)
        #expect(try context.books.fetch(id: untouchedAID)?.mark == false)
        #expect(try context.books.fetch(id: untouchedBID)?.mark == false)
    }

    @Test("version label suggestions upsert and keep history")
    func versionLabelSuggestionsUpsertAndKeepHistory() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/primary.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels
        )

        try service.setVersionLabel(" 中文翻译版 ", for: book)
        let bookID = try #require(book.databaseID)
        var saved = try #require(try context.books.fetch(id: bookID))
        #expect(saved.versionLabel == "中文翻译版")
        #expect(try service.loadVersionLabels(for: saved) == ["中文翻译版"])
        var suggestions = try context.versionLabelSuggestions.fetchAll()
        #expect(suggestions.map(\.label) == ["中文翻译版"])
        #expect(suggestions[0].usageCount == 1)

        try service.setVersionLabel("中文翻译版", for: saved)
        suggestions = try context.versionLabelSuggestions.fetchAll()
        #expect(suggestions.count == 1)
        #expect(suggestions[0].usageCount == 2)

        try service.setVersionLabel("", for: saved)
        saved = try #require(try context.books.fetch(id: bookID))
        #expect(saved.versionLabel == nil)
        #expect(try service.loadVersionLabels(for: saved).isEmpty)
        suggestions = try context.versionLabelSuggestions.fetchAll()
        #expect(suggestions.map(\.label) == ["中文翻译版"])
    }

    @Test("version labels support multiple values and compatibility text")
    func versionLabelsSupportMultipleValuesAndCompatibilityText() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/multi-label.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels
        )

        try service.setVersionLabels([" 翻译 ", "彩色", "翻译"], for: book)
        let bookID = try #require(book.databaseID)
        let saved = try #require(try context.books.fetch(id: bookID))
        #expect(saved.versionLabel == "翻译 / 彩色")
        #expect(try service.loadVersionLabels(for: saved) == ["翻译", "彩色"])
        #expect(try context.versionLabelSuggestions.fetchAll().map(\.label) == ["彩色", "翻译"])
    }

    @Test("version label classifier combines metadata tags and titles")
    func versionLabelClassifierCombinesMetadataTagsAndTitles() {
        var book = sampleBook(
            title: "[Chinese] 全彩無修正 Shared Story",
            filepath: "/tmp/classified.cbz",
            tags: #"["language:translated","other:full color","other:uncensored"]"#
        )
        book.languageCode = "chinese"
        #expect(VersionLabelClassifier.labels(for: book) == ["翻译", "彩色", "无修"])

        let original = sampleBook(title: "Shared Story", filepath: "/tmp/original.cbz")
        #expect(VersionLabelClassifier.labels(for: original) == ["原始"])
    }

    @Test("version label suggestions filter and sort in store")
    @MainActor
    func versionLabelSuggestionsFilterAndSortInStore() throws {
        let context = try makeContext()
        _ = try context.versionLabelSuggestions.upsert(label: "特别版")
        _ = try context.versionLabelSuggestions.upsert(label: "中文翻译版")
        _ = try context.versionLabelSuggestions.upsert(label: "中文翻译版")
        _ = try context.versionLabelSuggestions.upsert(label: "日文原版")
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions
        )
        let store = CatalogStore(service: service)
        store.refresh()

        #expect(store.versionLabelSuggestions(matching: "中").map(\.label) == ["中文翻译版"])
        #expect(store.versionLabelSuggestions(matching: "版").map(\.label) == ["中文翻译版", "日文原版", "特别版"])
    }

    @Test("version recommendations create groups and preserve dismissed decisions")
    @MainActor
    func versionRecommendationsCreateGroupsAndPreserveDismissedDecisions() async throws {
        let context = try makeContext()
        var japanese = sampleBook(
            title: "[Circle A] Shared Story",
            filepath: "/tmp/shared-jp.cbz",
            tags: #"["artist:maker","group:circle a","parody:source"]"#
        )
        japanese.category = "Doujinshi"
        var chinese = sampleBook(
            title: "[Chinese] Shared Story",
            hash: "sha1-shared-zh",
            filepath: "/tmp/shared-zh.cbz",
            tags: #"["artist:maker","group:circle a","parody:source","language:chinese"]"#
        )
        chinese.category = "Doujinshi"
        _ = try context.books.insert(japanese)
        _ = try context.books.insert(chinese)

        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels,
            versionRecommendationRepository: context.versionRecommendations
        )
        let store = CatalogStore(service: service)
        store.refresh()
        store.refreshVersionRecommendations()
        #expect(store.isRefreshingVersionRecommendations)
        await store.waitForVersionRecommendationRefresh()
        #expect(!store.isRefreshingVersionRecommendations)
        #expect(store.versionRecommendationRefreshProgress.fractionCompleted == 1)
        #expect(store.versionRecommendationMessage == VersionRecommendationRefreshProgressPhases.default.completed)

        #expect(store.createVersionGroupRecommendations.count == 1)
        #expect(store.createVersionGroupRecommendations[0].books.count == 2)

        store.dismissVersionRecommendation(store.createVersionGroupRecommendations[0])
        await store.waitForOrganizationMutations()
        store.refreshVersionRecommendations()
        await store.waitForVersionRecommendationRefresh()
        #expect(store.createVersionGroupRecommendations.isEmpty)
    }

    @Test("accepting version recommendations updates version groups")
    @MainActor
    func acceptingVersionRecommendationsUpdatesVersionGroups() async throws {
        let context = try makeContext()
        var primary = sampleBook(
            title: "[Circle A] Shared Story",
            filepath: "/tmp/primary.cbz",
            tags: #"["artist:maker","group:circle a"]"#
        )
        primary.category = "Doujinshi"
        var candidate = sampleBook(
            title: "(Digital) Shared Story",
            hash: "sha1-candidate",
            filepath: "/tmp/candidate.cbz",
            tags: #"["artist:maker","group:circle a","language:chinese"]"#
        )
        candidate.category = "Doujinshi"
        let savedPrimary = try context.books.insert(primary)
        let savedCandidate = try context.books.insert(candidate)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels,
            versionRecommendationRepository: context.versionRecommendations
        )
        let group = try service.createVersionGroup(with: [savedPrimary])

        let store = CatalogStore(service: service)
        store.refresh()
        store.selectedVersionGroupID = group.id
        store.refreshVersionRecommendations()
        await store.waitForVersionRecommendationRefresh()

        #expect(store.addToSelectedVersionGroupRecommendations.map(\.books).flatMap { $0 }.map(\.id) == [savedCandidate.id])

        store.acceptAddToSelectedVersionGroupRecommendation(store.addToSelectedVersionGroupRecommendations[0])
        await store.waitForOrganizationMutations()
        let candidateID = try #require(savedCandidate.databaseID)
        let groupedCandidate = try #require(try context.books.fetch(id: candidateID))
        #expect(groupedCandidate.versionGroupID == group.databaseID)
        #expect(groupedCandidate.hiddenBook)
        #expect(groupedCandidate.versionLabel == "翻译")
        #expect(try context.versionLabels.fetchLabels(bookID: candidateID) == ["翻译"])
        #expect(store.addToVersionGroupRecommendationCounts[group.databaseID ?? -1] == nil)
    }

    @Test("incremental version recommendations preserve unrelated pending entries")
    func incrementalVersionRecommendationsPreserveUnrelatedPendingEntries() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        var alphaOriginal = sampleBook(
            title: "[Circle] Alpha Story",
            filepath: "/tmp/version-alpha-original.cbz",
            tags: tags
        )
        alphaOriginal.category = "Doujinshi"
        var alphaTranslated = sampleBook(
            title: "[Chinese] Alpha Story",
            hash: "sha1-version-alpha-translated",
            filepath: "/tmp/version-alpha-translated.cbz",
            tags: tags
        )
        alphaTranslated.category = "Doujinshi"
        var betaOriginal = sampleBook(
            title: "[Circle] Beta Story",
            hash: "sha1-version-beta-original",
            filepath: "/tmp/version-beta-original.cbz",
            tags: tags
        )
        betaOriginal.category = "Doujinshi"
        let savedAlphaOriginal = try context.books.insert(alphaOriginal)
        let savedAlphaTranslated = try context.books.insert(alphaTranslated)
        let savedBetaOriginal = try context.books.insert(betaOriginal)
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations
        )

        try service.refreshRecommendations()
        let originalRecommendations = try context.versionRecommendations.fetchPending(
            kind: .createGroup,
            targetVersionGroupID: nil
        )
        #expect(originalRecommendations.count == 1)

        Thread.sleep(forTimeInterval: 0.02)
        var betaTranslated = sampleBook(
            title: "[Chinese] Beta Story",
            hash: "sha1-version-beta-translated",
            filepath: "/tmp/version-beta-translated.cbz",
            tags: tags
        )
        betaTranslated.category = "Doujinshi"
        let savedBetaTranslated = try context.books.insert(betaTranslated)

        let didUpdate = try service.updateRecommendationsIncrementally()

        #expect(didUpdate)
        let recommendations = try context.versionRecommendations.fetchPending(
            kind: .createGroup,
            targetVersionGroupID: nil
        )
        let memberSets = try recommendations.map { recommendation in
            Set(try context.versionRecommendations.fetchMemberBookIDs(
                recommendationID: try #require(recommendation.databaseID)
            ))
        }
        #expect(memberSets.contains(Set([
            try #require(savedAlphaOriginal.databaseID),
            try #require(savedAlphaTranslated.databaseID)
        ])))
        #expect(memberSets.contains(Set([
            try #require(savedBetaOriginal.databaseID),
            try #require(savedBetaTranslated.databaseID)
        ])))
    }

    @Test("incremental version recommendations no-op without changed books")
    func incrementalVersionRecommendationsNoOpWithoutChangedBooks() throws {
        let context = try makeContext()
        var original = sampleBook(
            title: "[Circle] Noop Story",
            filepath: "/tmp/version-noop-original.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        original.category = "Doujinshi"
        var translated = sampleBook(
            title: "[Chinese] Noop Story",
            hash: "sha1-version-noop-translated",
            filepath: "/tmp/version-noop-translated.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        translated.category = "Doujinshi"
        _ = try context.books.insert(original)
        _ = try context.books.insert(translated)
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations
        )

        try service.refreshRecommendations()

        #expect(try service.updateRecommendationsIncrementally() == false)
    }

    @Test("version recommendation focus reads the full library but writes only involved candidates")
    func versionRecommendationFocusUsesFullLibraryCandidates() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        var historical = sampleBook(title: "[Circle] Focus Story", filepath: "/tmp/focus-version-old.cbz", tags: tags)
        historical.category = "Doujinshi"
        historical.status = .correct
        var focused = sampleBook(
            title: "[Chinese] Focus Story",
            hash: "sha1-focus-version-new",
            filepath: "/tmp/focus-version-new.cbz",
            tags: tags
        )
        focused.category = "Doujinshi"
        focused.status = .correct
        var unrelatedA = sampleBook(title: "[Circle] Other Story", hash: "sha1-other-a", filepath: "/tmp/focus-other-a.cbz", tags: tags)
        unrelatedA.category = "Doujinshi"
        unrelatedA.status = .correct
        var unrelatedB = sampleBook(title: "[Chinese] Other Story", hash: "sha1-other-b", filepath: "/tmp/focus-other-b.cbz", tags: tags)
        unrelatedB.category = "Doujinshi"
        unrelatedB.status = .correct
        let savedHistorical = try context.books.insert(historical)
        let savedFocused = try context.books.insert(focused)
        _ = try context.books.insert(unrelatedA)
        _ = try context.books.insert(unrelatedB)
        let focusID = try #require(savedFocused.databaseID)
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations
        )

        try service.refreshRecommendations(focusBookIDs: [focusID])

        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)
        #expect(recommendations.count == 1)
        let memberIDs = try context.versionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendations[0].databaseID)
        )
        #expect(Set(memberIDs) == Set([try #require(savedHistorical.databaseID), focusID]))
    }

    @Test("collection recommendations create series from metadata and structured titles")
    func collectionRecommendationsCreateSeriesFromMetadataAndStructuredTitles() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "(例大祭15) [ナギヤマスギ (那岐山)] 東方陵辱40さとり (東方Project) [中国翻訳]",
            filepath: "/tmp/series-create-a.cbz",
            tags: #"["artist:那岐山","group:ナギヤマスギ"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "(例大祭16) [ナギヤマスギ (那岐山)] 東方陵辱43 早苗 (東方Project)",
            hash: "sha1-series-create-b",
            filepath: "/tmp/series-create-b.cbz",
            tags: #"["artist:那岐山","group:ナギヤマスギ"]"#
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        let recommendations = try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        )
        #expect(recommendations.count == 1)
        let recommendation = try #require(recommendations.first)
        let memberIDs = try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendation.databaseID)
        )
        #expect(Set(memberIDs) == Set([try #require(savedFirst.databaseID), try #require(savedSecond.databaseID)]))
        #expect(recommendation.reasons.contains("seriesTitle"))
    }

    @Test("collection recommendations require artist group and primary versions")
    func collectionRecommendationsRequireArtistGroupAndPrimaryVersions() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "無口少女の痴漢被害7",
            filepath: "/tmp/series-hard-a.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        first.category = "Doujinshi"
        var differentGroup = sampleBook(
            title: "無口少女の痴漢被害8",
            hash: "sha1-series-hard-b",
            filepath: "/tmp/series-hard-b.cbz",
            tags: #"["artist:maker","group:other"]"#
        )
        differentGroup.category = "Doujinshi"
        var secondaryVersion = sampleBook(
            title: "無口少女の痴漢被害9",
            hash: "sha1-series-hard-c",
            filepath: "/tmp/series-hard-c.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        secondaryVersion.category = "Doujinshi"
        secondaryVersion.isPrimaryVersion = false
        _ = try context.books.insert(first)
        _ = try context.books.insert(differentGroup)
        _ = try context.books.insert(secondaryVersion)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        let recommendations = try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        )
        #expect(recommendations.isEmpty)
    }

    @Test("semantic title evidence recalls structurally valid series with different wording")
    func semanticTitleEvidenceExpandsSeriesRecall() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        var first = sampleBook(
            title: "Namae mo Shiranai Onnanoko Sono 1",
            filepath: "/tmp/semantic-series-1.cbz",
            tags: tags
        )
        first.titleJpn = "名前も知らない女の子 その1"
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "名前も知らない女の子3～濡れ透けJK編～",
            hash: "sha1-semantic-series-2",
            filepath: "/tmp/semantic-series-2.cbz",
            tags: tags
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let semanticSearch = StubSemanticTitleVectorSearch(
            neighbors: [
                firstID: [.init(bookID: secondID, distance: 0.08)],
                secondID: [.init(bookID: firstID, distance: 0.08)]
            ]
        )
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations,
            semanticVectorSearch: semanticSearch
        )

        try service.refreshRecommendations(semanticConfiguration: .diagnostic)

        let recommendation = try #require(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).first)
        #expect(recommendation.reasons.contains("semanticTitle"))
        #expect(!recommendation.reasons.contains("seriesTitle"))
    }

    @Test("semantic title evidence stays diagnostic without a distinctive anchor")
    func semanticTitleEvidenceRejectsUnanchoredPair() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let first = try context.books.insert(sampleBook(
            title: "月下の秘密 Vol.1",
            filepath: "/tmp/semantic-unanchored-1.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "月夜に隠した約束 Vol.2",
            hash: "sha1-semantic-unanchored-2",
            filepath: "/tmp/semantic-unanchored-2.cbz",
            tags: tags
        ))
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations,
            semanticVectorSearch: StubSemanticTitleVectorSearch(
                neighbors: [
                    firstID: [.init(bookID: secondID, distance: 0.04)],
                    secondID: [.init(bookID: firstID, distance: 0.04)]
                ]
            )
        )

        try service.refreshRecommendations(semanticConfiguration: .diagnostic)

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).isEmpty)
        let diagnostic = try #require(try service.semanticEdgeDiagnostics().first)
        #expect(!diagnostic.isAccepted)
        #expect(diagnostic.rejectionReason == "missing_distinctive_anchor")
    }

    @Test("semantic recommendations reject mismatched code families")
    func semanticRecommendationsRejectMismatchedCodeFamilies() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let first = try context.books.insert(sampleBook(
            title: "刊行物 F1",
            filepath: "/tmp/semantic-code-f.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "刊行物 G2",
            hash: "sha1-semantic-code-g",
            filepath: "/tmp/semantic-code-g.cbz",
            tags: tags
        ))
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations,
            semanticVectorSearch: StubSemanticTitleVectorSearch(
                neighbors: [
                    firstID: [.init(bookID: secondID, distance: 0.02)],
                    secondID: [.init(bookID: firstID, distance: 0.02)]
                ]
            )
        )

        try service.refreshRecommendations(semanticConfiguration: .diagnostic)

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).isEmpty)
        let diagnostic = try #require(try service.semanticEdgeDiagnostics().first)
        #expect(diagnostic.rejectionReason == "numbering_family_mismatch")
    }

    @Test("semantic bridge cannot merge structurally incompatible lexical components")
    func semanticBridgeRequiresCompleteStructuralCompatibility() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        var first = sampleBook(
            title: "青空少女日記 Vol.1",
            filepath: "/tmp/semantic-bridge-a.cbz",
            tags: tags
        )
        first.titleJpn = "青空少女日記 Vol.1"
        var bridge = sampleBook(
            title: "夜空物語続編 Vol.2",
            hash: "sha1-semantic-bridge-b",
            filepath: "/tmp/semantic-bridge-b.cbz",
            tags: tags
        )
        bridge.titleJpn = "青空少女日記 Vol.2"
        let third = sampleBook(
            title: "夜空物語外伝 Vol.3",
            hash: "sha1-semantic-bridge-c",
            filepath: "/tmp/semantic-bridge-c.cbz",
            tags: tags
        )
        let savedFirst = try context.books.insert(first)
        let savedBridge = try context.books.insert(bridge)
        let savedThird = try context.books.insert(third)
        let firstID = try #require(savedFirst.databaseID)
        let bridgeID = try #require(savedBridge.databaseID)
        let thirdID = try #require(savedThird.databaseID)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations,
            semanticVectorSearch: StubSemanticTitleVectorSearch(
                neighbors: [
                    bridgeID: [.init(bookID: thirdID, distance: 0.05)],
                    thirdID: [.init(bookID: bridgeID, distance: 0.05)]
                ]
            )
        )

        try service.refreshRecommendations(semanticConfiguration: .diagnostic)

        let recommendations = try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        )
        let recommendation = try #require(recommendations.first)
        let memberIDs = Set(try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendation.databaseID)
        ))
        #expect(memberIDs == [firstID, bridgeID])
        #expect(!memberIDs.contains(thirdID))
    }

    @Test("create-series candidates reject duplicate ordinals joined through another volume")
    func createSeriesRejectsTransitivelyJoinedDuplicateOrdinals() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        _ = try context.books.insert(sampleBook(
            title: "同じ物語 Vol.1",
            filepath: "/tmp/transitive-duplicate-a.cbz",
            tags: tags
        ))
        _ = try context.books.insert(sampleBook(
            title: "同じ物語 第1話",
            hash: "sha1-transitive-duplicate-b",
            filepath: "/tmp/transitive-duplicate-b.cbz",
            tags: tags
        ))
        _ = try context.books.insert(sampleBook(
            title: "同じ物語 Vol.2",
            hash: "sha1-transitive-duplicate-c",
            filepath: "/tmp/transitive-duplicate-c.cbz",
            tags: tags
        ))
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).isEmpty)
    }

    @Test("unnumbered first volume joins an explicit second volume")
    func implicitFirstVolumeCreatesTwoBookSeries() throws {
        let context = try makeContext()
        let tags = #"["artist:namamo nanase","group:kaitsushin"]"#
        var firstBook = sampleBook(
            title: "898367 [Kaitsushin (Namamo Nanase)] Aido Rape [Chinese] [CE家族社] [Digital]",
            filepath: "/tmp/implicit-first-aido.cbz",
            tags: tags
        )
        firstBook.titleJpn = "[海通信 (なまもななせ)] 愛奴陵辱 [中国翻訳] [DL版]"
        firstBook.category = "Doujinshi"
        var secondBook = sampleBook(
            title: "1023811 [Kaitsushin (Namamo Nanase)] Aido Rape 2 [Digital]",
            hash: "sha1-implicit-first-aido-2",
            filepath: "/tmp/implicit-first-aido-2.cbz",
            tags: tags
        )
        secondBook.titleJpn = "[海通信 (なまもななせ)] 愛奴陵辱2 [DL版]"
        secondBook.category = "Doujinshi"
        let first = try context.books.insert(firstBook)
        let second = try context.books.insert(secondBook)
        let firstFeature = try #require(CollectionBookFeature(book: first))
        let secondFeature = try #require(CollectionBookFeature(book: second))
        #expect(firstFeature.isCleanUnnumbered)
        #expect(secondFeature.ordinalKey == "2")
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        let recommendation = try #require(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).first)
        let memberIDs = try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendation.databaseID)
        )
        #expect(memberIDs == [
            try #require(first.databaseID),
            try #require(second.databaseID)
        ])
        #expect(recommendation.reasons.contains("implicitFirstVolume"))
        #expect(recommendation.score <= 96)
    }

    @Test("unnumbered first volume without volume two needs two numbered supporters")
    func implicitFirstVolumeNeedsConsensusWithoutSecondVolume() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let first = try context.books.insert(sampleBook(
            title: "長い少女観察日記",
            filepath: "/tmp/implicit-consensus-first.cbz",
            tags: tags
        ))
        _ = try context.books.insert(sampleBook(
            title: "長い少女観察日記3",
            hash: "sha1-implicit-consensus-3",
            filepath: "/tmp/implicit-consensus-3.cbz",
            tags: tags
        ))
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()
        #expect(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).isEmpty)

        _ = try context.books.insert(sampleBook(
            title: "長い少女観察日記4",
            hash: "sha1-implicit-consensus-4",
            filepath: "/tmp/implicit-consensus-4.cbz",
            tags: tags
        ))
        try service.refreshRecommendations()

        let recommendation = try #require(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).first)
        let memberIDs = Set(try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendation.databaseID)
        ))
        #expect(memberIDs.contains(try #require(first.databaseID)))
        #expect(memberIDs.count == 3)
    }

    @Test("implicit first volume stays diagnostic when candidates are ambiguous")
    func implicitFirstVolumeRejectsAmbiguousCandidatesAndCatalogs() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        _ = try context.books.insert(sampleBook(
            title: "同じ物語",
            filepath: "/tmp/implicit-ambiguous-a.cbz",
            tags: tags
        ))
        _ = try context.books.insert(sampleBook(
            title: "同じ物語",
            hash: "sha1-implicit-ambiguous-b",
            filepath: "/tmp/implicit-ambiguous-b.cbz",
            tags: tags
        ))
        _ = try context.books.insert(sampleBook(
            title: "同じ物語2",
            hash: "sha1-implicit-ambiguous-2",
            filepath: "/tmp/implicit-ambiguous-2.cbz",
            tags: tags
        ))
        _ = try context.books.insert(sampleBook(
            title: "ARCANUMS",
            hash: "sha1-implicit-arcanums",
            filepath: "/tmp/implicit-arcanums.cbz",
            tags: tags
        ))
        _ = try context.books.insert(sampleBook(
            title: "ARCANUMS2",
            hash: "sha1-implicit-arcanums-2",
            filepath: "/tmp/implicit-arcanums-2.cbz",
            tags: tags
        ))
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).isEmpty)
    }

    @Test("explicit first volume and special editions are never inferred as another first volume")
    func implicitFirstVolumeRejectsExistingFirstAndSpecialEditions() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let explicitFirst = try context.books.insert(sampleBook(
            title: "少女記録 Vol.1",
            filepath: "/tmp/implicit-explicit-1.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "少女記録 Vol.2",
            hash: "sha1-implicit-explicit-2",
            filepath: "/tmp/implicit-explicit-2.cbz",
            tags: tags
        ))
        let special = try context.books.insert(sampleBook(
            title: "少女記録 総集編",
            hash: "sha1-implicit-special",
            filepath: "/tmp/implicit-special.cbz",
            tags: tags
        ))
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        let recommendation = try #require(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).first)
        let memberIDs = Set(try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendation.databaseID)
        ))
        #expect(memberIDs == [
            try #require(explicitFirst.databaseID),
            try #require(second.databaseID)
        ])
        #expect(!memberIDs.contains(try #require(special.databaseID)))
        #expect(!recommendation.reasons.contains("implicitFirstVolume"))
    }

    @Test("accepting an inferred first volume prepends it to an existing series")
    func implicitFirstVolumeAcceptancePrependsMember() throws {
        let context = try makeContext()
        let tags = #"["artist:namamo nanase","group:kaitsushin"]"#
        let first = try context.books.insert(sampleBook(
            title: "愛奴陵辱",
            filepath: "/tmp/implicit-add-first.cbz",
            tags: tags
        ))
        let translatedFirst = try context.books.insert(sampleBook(
            title: "Aido Rape",
            hash: "sha1-implicit-add-first-translated",
            filepath: "/tmp/implicit-add-first-translated.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "愛奴陵辱2",
            hash: "sha1-implicit-add-2",
            filepath: "/tmp/implicit-add-2.cbz",
            tags: tags
        ))
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        _ = try libraryService.createVersionGroup(with: [first, translatedFirst])
        let firstID = try #require(first.databaseID)
        let translatedFirstID = try #require(translatedFirst.databaseID)
        let groupedFirst = try #require(try context.books.fetch(id: firstID))
        let collection = try libraryService.createCollection(name: "愛奴陵辱")
        try libraryService.addBook(second, to: collection)
        let recommendationService = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try recommendationService.refreshRecommendations()
        let collectionID = try #require(collection.databaseID)

        let recommendation = try #require(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collectionID
        ).first)
        #expect(recommendation.reasons.contains("implicitFirstVolume"))
        try libraryService.acceptAddToCollectionRecommendation(
            recommendation,
            book: groupedFirst,
            collection: collection
        )

        let members = try context.books.fetchByCollectionID(collectionID)
        let secondID = try #require(second.databaseID)
        #expect(Set(members.prefix(2).compactMap(\.databaseID)) == [firstID, translatedFirstID])
        #expect(members.last?.databaseID == secondID)
        #expect(members.map(\.collectionOrder) == [0, 0, 1])
        let hiddenSecondary = try #require(try context.books.fetch(id: translatedFirstID))
        #expect(hiddenSecondary.hiddenBook)
        #expect(!hiddenSecondary.isPrimaryVersion)
    }

    @Test("an explicit second volume can join a series containing only an unnumbered first")
    func explicitSecondVolumeJoinsExistingUnnumberedSeries() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let first = try context.books.insert(sampleBook(
            title: "静かな観察日記",
            filepath: "/tmp/implicit-existing-first.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "静かな観察日記2",
            hash: "sha1-implicit-existing-2",
            filepath: "/tmp/implicit-existing-2.cbz",
            tags: tags
        ))
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        let collection = try libraryService.createCollection(name: "静かな観察日記")
        try libraryService.addBook(first, to: collection)
        let recommendationService = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try recommendationService.refreshRecommendations()
        let collectionID = try #require(collection.databaseID)

        let recommendation = try #require(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collectionID
        ).first)
        #expect(recommendation.reasons.contains("implicitFirstVolume"))
        let memberIDs = try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendation.databaseID)
        )
        #expect(memberIDs == [try #require(second.databaseID)])
    }

    @Test("semantic add-to-series requires two existing member supporters")
    func semanticAddToSeriesRequiresConsensus() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let first = try context.books.insert(sampleBook(
            title: "名前も知らない女の子 その1",
            filepath: "/tmp/semantic-consensus-1.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "名前も知らない女の子 その2",
            hash: "sha1-semantic-consensus-2",
            filepath: "/tmp/semantic-consensus-2.cbz",
            tags: tags
        ))
        let candidate = try context.books.insert(sampleBook(
            title: "名前も知らない女の子3～濡れ透けJK編～",
            hash: "sha1-semantic-consensus-3",
            filepath: "/tmp/semantic-consensus-3.cbz",
            tags: tags
        ))
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        let collection = try libraryService.createCollection(name: "名前も知らない女の子")
        try libraryService.addBook(first, to: collection)
        try libraryService.addBook(second, to: collection)
        let firstID = try #require(first.databaseID)
        let candidateID = try #require(candidate.databaseID)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations,
            semanticVectorSearch: StubSemanticTitleVectorSearch(
                neighbors: [
                    firstID: [.init(bookID: candidateID, distance: 0.05)],
                    candidateID: [.init(bookID: firstID, distance: 0.05)]
                ]
            )
        )

        try service.refreshRecommendations(semanticConfiguration: .diagnostic)

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collection.databaseID
        ).isEmpty)
    }

    @Test("add-to-series recommendations reject an ordinal already present in the target series")
    func collectionRecommendationsRejectDuplicateOrdinalInExistingSeries() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        var existing = sampleBook(
            title: "同じ物語 Vol.1",
            filepath: "/tmp/duplicate-ordinal-existing.cbz",
            tags: tags
        )
        existing.category = "Doujinshi"
        var candidate = sampleBook(
            title: "同じ物語 第1話",
            hash: "sha1-duplicate-ordinal-candidate",
            filepath: "/tmp/duplicate-ordinal-candidate.cbz",
            tags: tags
        )
        candidate.category = "Doujinshi"
        let savedExisting = try context.books.insert(existing)
        _ = try context.books.insert(candidate)
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        let collection = try libraryService.createCollection(name: "同じ物語")
        try libraryService.addBook(savedExisting, to: collection)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collection.databaseID
        ).isEmpty)
    }

    @Test("collection recommendations add uncollected primary to existing series")
    func collectionRecommendationsAddUncollectedPrimaryToExistingSeries() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "無口少女の痴漢被害7",
            filepath: "/tmp/series-add-a.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        first.category = "Doujinshi"
        var candidate = sampleBook(
            title: "無口少女の痴漢被害8",
            hash: "sha1-series-add-b",
            filepath: "/tmp/series-add-b.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        candidate.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedCandidate = try context.books.insert(candidate)
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        let collection = try libraryService.createCollection(name: "無口少女の痴漢被害")
        try libraryService.addBook(savedFirst, to: collection)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        let recommendations = try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collection.databaseID
        )
        #expect(recommendations.count == 1)
        let recommendation = try #require(recommendations.first)
        #expect(try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendation.databaseID)
        ) == [try #require(savedCandidate.databaseID)])
    }

    @Test("collection recommendations prefer existing series for long suffix numbered titles")
    func collectionRecommendationsPreferExistingSeriesForLongSuffixNumberedTitles() throws {
        let context = try makeContext()
        let tags = #"["artist:nagiyama","group:nagiyamasugi"]"#
        var anchor = sampleBook(
            title: "プリキュア陵辱17キュアワンダフル",
            filepath: "/tmp/precure-series-anchor.cbz",
            tags: tags
        )
        anchor.category = "Doujinshi"
        let titles = [
            "プリキュア陵辱12トロピカルージュ角オナ",
            "プリキュア陵辱18キュアニャミー",
            "プリキュア陵辱19咲良うた",
            "プリキュア陵辱20キュアキュンキュン"
        ]
        let savedAnchor = try context.books.insert(anchor)
        let savedCandidates = try titles.enumerated().map { offset, title in
            var book = sampleBook(
                title: title,
                hash: "sha1-precure-\(offset)",
                filepath: "/tmp/precure-series-\(offset).cbz",
                tags: tags
            )
            book.category = "Doujinshi"
            return try context.books.insert(book)
        }
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        let collection = try libraryService.createCollection(name: "プリキュア陵辱")
        try libraryService.addBook(savedAnchor, to: collection)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        let addRecommendations = try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collection.databaseID
        )
        #expect(addRecommendations.count == 4)
        let addMemberIDs = try addRecommendations.flatMap { recommendation in
            try context.collectionRecommendations.fetchMemberBookIDs(
                recommendationID: try #require(recommendation.databaseID)
            )
        }
        #expect(Set(addMemberIDs) == Set(savedCandidates.map { $0.databaseID! }))

        let createRecommendations = try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        )
        #expect(createRecommendations.isEmpty)
    }

    @Test("collection recommendations still create series when no existing collection matches")
    func collectionRecommendationsStillCreateSeriesWhenNoExistingCollectionMatches() throws {
        let context = try makeContext()
        let tags = #"["artist:nagiyama","group:nagiyamasugi"]"#
        let titles = [
            "プリキュア陵辱18キュアニャミー",
            "プリキュア陵辱19咲良うた"
        ]
        let savedBooks = try titles.enumerated().map { offset, title in
            var book = sampleBook(
                title: title,
                hash: "sha1-precure-create-\(offset)",
                filepath: "/tmp/precure-create-\(offset).cbz",
                tags: tags
            )
            book.category = "Doujinshi"
            return try context.books.insert(book)
        }
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        let recommendations = try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        )
        #expect(recommendations.count == 1)
        let recommendation = try #require(recommendations.first)
        let memberIDs = try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendation.databaseID)
        )
        #expect(Set(memberIDs) == Set(savedBooks.map { $0.databaseID! }))
    }

    @Test("incremental collection recommendations preserve unrelated pending entries")
    func incrementalCollectionRecommendationsPreserveUnrelatedPendingEntries() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        var alphaOne = sampleBook(title: "Alpha Series 1", filepath: "/tmp/collection-alpha-1.cbz", tags: tags)
        alphaOne.category = "Doujinshi"
        var alphaTwo = sampleBook(
            title: "Alpha Series 2",
            hash: "sha1-collection-alpha-2",
            filepath: "/tmp/collection-alpha-2.cbz",
            tags: tags
        )
        alphaTwo.category = "Doujinshi"
        var betaTwo = sampleBook(
            title: "Beta Series 2",
            hash: "sha1-collection-beta-2",
            filepath: "/tmp/collection-beta-2.cbz",
            tags: tags
        )
        betaTwo.category = "Doujinshi"
        let savedAlphaOne = try context.books.insert(alphaOne)
        let savedAlphaTwo = try context.books.insert(alphaTwo)
        let savedBetaTwo = try context.books.insert(betaTwo)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()
        let originalRecommendations = try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        )
        #expect(originalRecommendations.count == 1)

        Thread.sleep(forTimeInterval: 0.02)
        var betaOne = sampleBook(
            title: "Beta Series 1",
            hash: "sha1-collection-beta-1",
            filepath: "/tmp/collection-beta-1.cbz",
            tags: tags
        )
        betaOne.category = "Doujinshi"
        let savedBetaOne = try context.books.insert(betaOne)

        let didUpdate = try service.updateRecommendationsIncrementally()

        #expect(didUpdate)
        let recommendations = try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        )
        let memberSets = try recommendations.map { recommendation in
            Set(try context.collectionRecommendations.fetchMemberBookIDs(
                recommendationID: try #require(recommendation.databaseID)
            ))
        }
        #expect(memberSets.contains(Set([
            try #require(savedAlphaOne.databaseID),
            try #require(savedAlphaTwo.databaseID)
        ])))
        #expect(memberSets.contains(Set([
            try #require(savedBetaOne.databaseID),
            try #require(savedBetaTwo.databaseID)
        ])))
    }

    @Test("incremental collection recommendations no-op without changed books")
    func incrementalCollectionRecommendationsNoOpWithoutChangedBooks() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Noop Series 1",
            filepath: "/tmp/collection-noop-1.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Noop Series 2",
            hash: "sha1-collection-noop-2",
            filepath: "/tmp/collection-noop-2.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        second.category = "Doujinshi"
        _ = try context.books.insert(first)
        _ = try context.books.insert(second)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()

        #expect(try service.updateRecommendationsIncrementally() == false)
    }

    @Test("collection recommendation focus compares the batch primary with historical books")
    func collectionRecommendationFocusUsesFullLibraryCandidates() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        var historical = sampleBook(title: "Focus Series 1", filepath: "/tmp/focus-series-old.cbz", tags: tags)
        historical.category = "Doujinshi"
        historical.status = .correct
        var focused = sampleBook(
            title: "Focus Series 2",
            hash: "sha1-focus-series-new",
            filepath: "/tmp/focus-series-new.cbz",
            tags: tags
        )
        focused.category = "Doujinshi"
        focused.status = .correct
        let savedHistorical = try context.books.insert(historical)
        let savedFocused = try context.books.insert(focused)
        let focusID = try #require(savedFocused.databaseID)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations(focusBookIDs: [focusID])

        let recommendations = try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        )
        #expect(recommendations.count == 1)
        let memberIDs = try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(recommendations[0].databaseID)
        )
        #expect(Set(memberIDs) == Set([try #require(savedHistorical.databaseID), focusID]))
    }

    @Test("accepting collection recommendation rolls back all writes when status update fails")
    func acceptingCollectionRecommendationIsTransactional() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        var first = sampleBook(title: "Atomic Series 1", filepath: "/tmp/atomic-series-1.cbz", tags: tags)
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Atomic Series 2",
            hash: "sha1-atomic-series-2",
            filepath: "/tmp/atomic-series-2.cbz",
            tags: tags
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let recommendationService = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )
        try recommendationService.refreshRecommendations()
        let recommendation = try #require(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).first)
        try context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_accept_collection_recommendation
                BEFORE UPDATE OF status ON collection_recommendations
                WHEN NEW.status = 'accepted'
                BEGIN
                    SELECT RAISE(ABORT, 'forced recommendation failure');
                END;
                """)
        }
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )

        #expect(throws: (any Error).self) {
            _ = try libraryService.acceptCreateCollectionRecommendation(
                recommendation,
                books: [savedFirst, savedSecond],
                fallbackName: "Atomic Series"
            )
        }

        #expect(try context.collections.fetchAll().isEmpty)
        #expect(try context.books.fetchAll().allSatisfy { $0.collectionID == nil })
    }

    @Test("store accepts collection recommendations")
    @MainActor
    func storeAcceptsCollectionRecommendations() async throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "無口少女の痴漢被害7",
            filepath: "/tmp/series-store-a.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "無口少女の痴漢被害8",
            hash: "sha1-series-store-b",
            filepath: "/tmp/series-store-b.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        second.category = "Doujinshi"
        _ = try context.books.insert(first)
        _ = try context.books.insert(second)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        let store = CatalogStore(service: service)
        store.refresh()

        store.refreshCollectionRecommendations()
        await store.waitForCollectionRecommendationRefresh()
        #expect(store.createCollectionRecommendations.count == 1)

        store.acceptCreateCollectionRecommendation(
            store.createCollectionRecommendations[0],
            localizer: AppLocalizer(language: .zhHans)
        )
        await store.waitForOrganizationMutations()

        #expect(store.collections.count == 1)
        let collection = try #require(store.collections.first)
        #expect(store.displayBooks(in: collection).count == 2)
        #expect(store.createCollectionRecommendations.isEmpty)
    }

    @Test("series title pattern orders numeric and localized ordinals")
    func seriesTitlePatternOrdersNumericAndLocalizedOrdinals() throws {
        #expect(try #require(SeriesTitlePattern(title: "無口少女の痴漢被害2")).ordinalSortValue == 2)
        #expect(try #require(SeriesTitlePattern(title: "無口少女の痴漢被害10")).ordinalSortValue == 10)
        #expect(try #require(SeriesTitlePattern(title: "無口少女第十話")).ordinalSortValue == 10)
        #expect(try #require(SeriesTitlePattern(title: "白昼夢上")).ordinalSortValue == 1)
        #expect(try #require(SeriesTitlePattern(title: "白昼夢中")).ordinalSortValue == 2)
        #expect(try #require(SeriesTitlePattern(title: "白昼夢下")).ordinalSortValue == 3)
        #expect(try #require(SeriesTitlePattern(title: "夢の前篇")).ordinalSortValue == 1)
        #expect(try #require(SeriesTitlePattern(title: "夢の後篇")).ordinalSortValue == 3)
        #expect(try #require(SeriesTitlePattern(title: "夢の記録 Vol. IV")).ordinalSortValue == 4)
        #expect(try #require(SeriesTitlePattern(title: "夢の記録 #5")).ordinalSortValue == 5)
        #expect(try #require(SeriesTitlePattern(title: "夢の記録 Episode 6")).ordinalSortValue == 6)
        #expect(try #require(SeriesTitlePattern(title: "プリキュア陵辱17キュアワンダフル")).ordinalSortValue == 17)
        #expect(SeriesTitlePattern(title: "夢の記録 2024") == nil)
        #expect(SeriesTitlePattern(title: "即売会SC99新刊") == nil)
    }

    @Test("series title pattern distinguishes catalog families from incidental numbers")
    func seriesTitlePatternDistinguishesCatalogFamilies() throws {
        let arcanum20 = try #require(SeriesTitlePattern(title: "ARCANUMS 20 配信はじめました"))
        let arcanum33 = try #require(SeriesTitlePattern(title: "ARCANUM33 しましま人間"))
        #expect(arcanum20.ordinalSortValue == 20)
        #expect(arcanum33.ordinalSortValue == 33)
        #expect(arcanum20.numberingFamily == "arcanum")
        #expect(arcanum33.numberingFamily == "arcanum")
        #expect(arcanum20.ordinalEvidence.kind == .catalogNumber)

        let shortF = try #require(SeriesTitlePattern(title: "2ストローク F3"))
        #expect(shortF.numberingFamily == "f")
        #expect(shortF.semanticStem == "ストローク")
        #expect(SeriesTitlePattern(title: "2ストローク SC1") == nil)

        #expect(SeriesTitlePattern(title: "アスカ、六畳間監禁飼育") == nil)
        #expect(SeriesTitlePattern(title: "アネモネ症候群 2.00") == nil)
        #expect(SeriesTitlePattern(title: "アネモネ症候群 2.10") == nil)
        #expect(SeriesTitlePattern(title: "即売会 2024年5月17日") == nil)
        #expect(SeriesTitlePattern(title: "即売会 5月17日") == nil)
        #expect(SeriesTitlePattern(title: "C96セット限定本") == nil)

        var conflicting = sampleBook(
            title: "刊行物 F1",
            filepath: "/tmp/conflicting-number-family.cbz",
            tags: #"["artist:maker","group:circle"]"#
        )
        conflicting.databaseID = 99
        conflicting.titleJpn = "刊行物 G1"
        #expect(CollectionBookFeature(book: conflicting) == nil)
    }

    @Test("series title analysis distinguishes clean unnumbered titles from risky metadata")
    func seriesTitleAnalysisClassifiesUnnumberedTitles() throws {
        let clean = try #require(SeriesTitleAnalysis(title: "愛奴陵辱"))
        #expect(clean.isCleanUnnumbered)
        #expect(clean.semanticStem == "愛奴陵辱")

        let explicit = try #require(SeriesTitleAnalysis(title: "愛奴陵辱2"))
        #expect(explicit.ordinalEvidence?.key == "2")

        for title in [
            "少女記録 総集編",
            "少女記録 番外編",
            "少女記録 2.10",
            "少女記録 1+2",
            "即売会 2024年5月17日",
            "C96セット限定本"
        ] {
            let analysis = try #require(SeriesTitleAnalysis(title: title))
            guard case .rejected = analysis.ordinalState else {
                Issue.record("\(title) should be rejected for implicit-first inference")
                continue
            }
        }
        #expect(try #require(SeriesTitleAnalysis(title: "アスカ、六畳間監禁飼育")).isCleanUnnumbered)
    }

    @Test("repository replaces collection order without touching other series")
    func repositoryReplacesCollectionOrderWithoutTouchingOtherSeries() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/order-first.cbz"))
        let second = try context.books.insert(sampleBook(
            title: "Second",
            hash: "sha1-order-second",
            filepath: "/tmp/order-second.cbz"
        ))
        let other = try context.books.insert(sampleBook(
            title: "Other",
            hash: "sha1-order-other",
            filepath: "/tmp/order-other.cbz"
        ))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Series")
        let otherCollection = try service.createCollection(name: "Other Series")
        try service.addBook(first, to: collection)
        try service.addBook(second, to: collection)
        try service.addBook(other, to: otherCollection)
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let otherID = try #require(other.databaseID)

        let updated = try context.books.replaceCollectionOrder(
            bookIDs: [secondID, firstID],
            collectionID: try #require(collection.databaseID)
        )

        #expect(updated.filter(\.isPrimaryVersion).map(\.databaseID) == [secondID, firstID])
        #expect(try context.books.fetch(id: otherID)?.collectionOrder == 0)
    }

    @Test("service moves and reorders collection members in one batch")
    func serviceMovesAndReordersCollectionMembersInOneBatch() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/move-first.cbz"))
        let second = try context.books.insert(sampleBook(
            title: "Second",
            hash: "sha1-move-second",
            filepath: "/tmp/move-second.cbz"
        ))
        let third = try context.books.insert(sampleBook(
            title: "Third",
            hash: "sha1-move-third",
            filepath: "/tmp/move-third.cbz"
        ))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Series")
        try service.addBook(first, to: collection)
        try service.addBook(second, to: collection)
        try service.addBook(third, to: collection)
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let thirdID = try #require(third.databaseID)

        let moved = try service.moveBook(third, in: collection, direction: .up)
        #expect(moved.map(\.databaseID) == [firstID, thirdID, secondID])

        let reordered = try service.reorderBooks([third, first, second], in: collection)
        #expect(reordered.map(\.databaseID) == [thirdID, firstID, secondID])
        #expect(reordered.compactMap(\.collectionOrder) == [0, 1, 2])
    }

    @Test("service auto sorts collection members by title ordinal")
    func serviceAutoSortsCollectionMembersByTitleOrdinal() throws {
        let context = try makeContext()
        var ten = sampleBook(title: "fallback ten", filepath: "/tmp/auto-ten.cbz")
        ten.titleJpn = "無口少女第十話"
        var unknown = sampleBook(
            title: "番外編",
            hash: "sha1-auto-unknown",
            filepath: "/tmp/auto-unknown.cbz"
        )
        unknown.titleJpn = "番外編"
        var two = sampleBook(
            title: "fallback two",
            hash: "sha1-auto-two",
            filepath: "/tmp/auto-two.cbz"
        )
        two.titleJpn = "無口少女2"
        var one = sampleBook(
            title: "fallback one",
            hash: "sha1-auto-one",
            filepath: "/tmp/auto-one.cbz"
        )
        one.titleJpn = "無口少女1"
        var unnumbered = sampleBook(
            title: "fallback unnumbered",
            hash: "sha1-auto-unnumbered",
            filepath: "/tmp/auto-unnumbered.cbz"
        )
        unnumbered.titleJpn = "無口少女"
        let savedTen = try context.books.insert(ten)
        let savedUnknown = try context.books.insert(unknown)
        let savedTwo = try context.books.insert(two)
        let savedOne = try context.books.insert(one)
        let savedUnnumbered = try context.books.insert(unnumbered)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Series")
        for book in [savedTen, savedUnknown, savedTwo, savedOne, savedUnnumbered] {
            try service.addBook(book, to: collection)
        }
        let unnumberedID = try #require(savedUnnumbered.databaseID)
        let oneID = try #require(savedOne.databaseID)
        let twoID = try #require(savedTwo.databaseID)
        let tenID = try #require(savedTen.databaseID)
        let unknownID = try #require(savedUnknown.databaseID)

        let sorted = try service.autoSortBooks(in: collection)

        #expect(sorted.map(\.databaseID) == [unnumberedID, oneID, twoID, tenID, unknownID])
    }

    @Test("shared ordinal resolver sorts inferred first duplicates and rejected titles stably")
    func sharedOrdinalResolverSortsStructuredSeriesStably() throws {
        let context = try makeContext()
        let ten = try context.books.insert(sampleBook(
            title: "愛奴陵辱10",
            filepath: "/tmp/resolver-ten.cbz"
        ))
        let inferredFirst = try context.books.insert(sampleBook(
            title: "愛奴陵辱",
            hash: "sha1-resolver-first",
            filepath: "/tmp/resolver-first.cbz"
        ))
        let firstTwo = try context.books.insert(sampleBook(
            title: "愛奴陵辱2",
            hash: "sha1-resolver-two-a",
            filepath: "/tmp/resolver-two-a.cbz"
        ))
        let secondTwo = try context.books.insert(sampleBook(
            title: "愛奴陵辱2",
            hash: "sha1-resolver-two-b",
            filepath: "/tmp/resolver-two-b.cbz"
        ))
        var conflict = sampleBook(
            title: "愛奴陵辱4",
            hash: "sha1-resolver-conflict",
            filepath: "/tmp/resolver-conflict.cbz"
        )
        conflict.titleJpn = "愛奴陵辱3"
        let savedConflict = try context.books.insert(conflict)
        let special = try context.books.insert(sampleBook(
            title: "愛奴陵辱 番外編",
            hash: "sha1-resolver-special",
            filepath: "/tmp/resolver-special.cbz"
        ))

        let plan = try #require(SeriesOrdinalResolver.sortPlan(for: [
            ten,
            inferredFirst,
            firstTwo,
            secondTwo,
            savedConflict,
            special
        ]))

        #expect(plan.inferredFirstBookID == inferredFirst.databaseID)
        #expect(plan.orderedPrimaryBookIDs == [
            try #require(inferredFirst.databaseID),
            try #require(firstTwo.databaseID),
            try #require(secondTwo.databaseID),
            try #require(ten.databaseID),
            try #require(savedConflict.databaseID),
            try #require(special.databaseID)
        ])
    }

    @Test("confirmed collection sorting puts every clean unnumbered member first")
    func confirmedCollectionSortsCleanUnnumberedMembersFirst() throws {
        let context = try makeContext()
        let third = try context.books.insert(sampleBook(
            title: "愛奴陵辱3",
            filepath: "/tmp/confirmed-sort-three.cbz"
        ))
        let firstUnnumbered = try context.books.insert(sampleBook(
            title: "愛奴陵辱",
            hash: "sha1-confirmed-sort-first",
            filepath: "/tmp/confirmed-sort-first.cbz"
        ))
        let special = try context.books.insert(sampleBook(
            title: "愛奴陵辱 番外編",
            hash: "sha1-confirmed-sort-special",
            filepath: "/tmp/confirmed-sort-special.cbz"
        ))
        let secondUnnumbered = try context.books.insert(sampleBook(
            title: "愛奴陵辱 初版",
            hash: "sha1-confirmed-sort-second",
            filepath: "/tmp/confirmed-sort-second.cbz"
        ))
        var conflict = sampleBook(
            title: "愛奴陵辱4",
            hash: "sha1-confirmed-sort-conflict",
            filepath: "/tmp/confirmed-sort-conflict.cbz"
        )
        conflict.titleJpn = "愛奴陵辱5"
        let savedConflict = try context.books.insert(conflict)
        let input = [third, firstUnnumbered, special, secondUnnumbered, savedConflict]

        #expect(SeriesOrdinalResolver.sortPlan(for: input) == nil)
        let plan = try #require(SeriesOrdinalResolver.sortPlan(
            for: input,
            policy: .confirmedCollection
        ))

        #expect(plan.inferredFirstBookID == nil)
        #expect(plan.orderedPrimaryBookIDs == [
            try #require(firstUnnumbered.databaseID),
            try #require(secondUnnumbered.databaseID),
            try #require(third.databaseID),
            try #require(special.databaseID),
            try #require(savedConflict.databaseID)
        ])

        let unnumberedOnlyPlan = try #require(SeriesOrdinalResolver.sortPlan(
            for: [special, firstUnnumbered, secondUnnumbered],
            policy: .confirmedCollection
        ))
        #expect(unnumberedOnlyPlan.orderedPrimaryBookIDs == [
            try #require(firstUnnumbered.databaseID),
            try #require(secondUnnumbered.databaseID),
            try #require(special.databaseID)
        ])
    }

    @Test("catalog ordinals sort only within one numbering family")
    func catalogOrdinalsRequireOneFamilyForSorting() throws {
        let context = try makeContext()
        let thirtyFive = try context.books.insert(sampleBook(
            title: "ARCANUMS35",
            filepath: "/tmp/catalog-35.cbz"
        ))
        let twenty = try context.books.insert(sampleBook(
            title: "ARCANUMS20",
            hash: "sha1-catalog-20",
            filepath: "/tmp/catalog-20.cbz"
        ))
        let thirtyThree = try context.books.insert(sampleBook(
            title: "ARCANUMS33",
            hash: "sha1-catalog-33",
            filepath: "/tmp/catalog-33.cbz"
        ))
        let plan = try #require(SeriesOrdinalResolver.sortPlan(for: [
            thirtyFive,
            twenty,
            thirtyThree
        ]))
        #expect(plan.orderedPrimaryBookIDs == [
            try #require(twenty.databaseID),
            try #require(thirtyThree.databaseID),
            try #require(thirtyFive.databaseID)
        ])

        let otherFamily = try context.books.insert(sampleBook(
            title: "刊物 F3",
            hash: "sha1-catalog-f3",
            filepath: "/tmp/catalog-f3.cbz"
        ))
        #expect(SeriesOrdinalResolver.sortPlan(for: [twenty, otherFamily]) == nil)
    }

    @Test("accepting an add recommendation automatically sorts the target series")
    func acceptingAddRecommendationAutomaticallySortsSeries() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let first = try context.books.insert(sampleBook(
            title: "順序作品1",
            filepath: "/tmp/accept-sort-1.cbz",
            tags: tags
        ))
        let third = try context.books.insert(sampleBook(
            title: "順序作品3",
            hash: "sha1-accept-sort-3",
            filepath: "/tmp/accept-sort-3.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "順序作品2",
            hash: "sha1-accept-sort-2",
            filepath: "/tmp/accept-sort-2.cbz",
            tags: tags
        ))
        let unnumbered = try context.books.insert(sampleBook(
            title: "順序作品",
            hash: "sha1-accept-sort-unnumbered",
            filepath: "/tmp/accept-sort-unnumbered.cbz",
            tags: tags
        ))
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        let collection = try libraryService.createCollection(name: "順序作品")
        try libraryService.addBook(first, to: collection)
        try libraryService.addBook(third, to: collection)
        try libraryService.addBook(unnumbered, to: collection)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )
        try service.refreshRecommendations()
        let collectionID = try #require(collection.databaseID)
        let recommendation = try #require(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collectionID
        ).first)

        try libraryService.acceptAddToCollectionRecommendation(
            recommendation,
            book: second,
            collection: collection
        )

        let members = try context.books.fetchByCollectionID(collectionID).filter(\.isPrimaryVersion)
        #expect(members.compactMap(\.databaseID) == [
            try #require(unnumbered.databaseID),
            try #require(first.databaseID),
            try #require(second.databaseID),
            try #require(third.databaseID)
        ])
        #expect(members.compactMap(\.collectionOrder) == [0, 1, 2, 3])
    }

    @Test("one uncollected book keeps only its strongest existing-series target")
    func addRecommendationKeepsOnlyStrongestTarget() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        func saved(_ ordinal: Int, suffix: String, category: String?) throws -> LibraryBook {
            var book = sampleBook(
                title: "競合作品\(ordinal)",
                hash: "sha1-strong-target-\(suffix)",
                filepath: "/tmp/strong-target-\(suffix).cbz",
                tags: tags
            )
            book.category = category
            return try context.books.insert(book)
        }
        let strongMembers = try [
            saved(1, suffix: "a1", category: "Doujinshi"),
            saved(2, suffix: "a2", category: "Doujinshi")
        ]
        let weakMembers = try [
            saved(5, suffix: "b5", category: nil),
            saved(6, suffix: "b6", category: nil)
        ]
        _ = try saved(3, suffix: "candidate", category: "Doujinshi")
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let strong = try libraryService.createCollection(name: "Strong")
        let weak = try libraryService.createCollection(name: "Weak")
        for book in strongMembers {
            try libraryService.addBook(book, to: strong)
        }
        for book in weakMembers {
            try libraryService.addBook(book, to: weak)
        }
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()
        let strongID = try #require(strong.databaseID)
        let weakID = try #require(weak.databaseID)

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: strongID
        ).count == 1)
        #expect(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: weakID
        ).isEmpty)
    }

    @Test("an exact multi-target tie produces no add recommendation")
    func addRecommendationSuppressesExactTargetTie() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        func saved(_ ordinal: Int, suffix: String) throws -> LibraryBook {
            var book = sampleBook(
                title: "同分作品\(ordinal)",
                hash: "sha1-tied-target-\(suffix)",
                filepath: "/tmp/tied-target-\(suffix).cbz",
                tags: tags
            )
            book.category = "Doujinshi"
            return try context.books.insert(book)
        }
        let leftMembers = try [
            saved(1, suffix: "a1"),
            saved(2, suffix: "a2")
        ]
        let rightMembers = try [
            saved(5, suffix: "b5"),
            saved(6, suffix: "b6")
        ]
        _ = try saved(3, suffix: "candidate")
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let left = try libraryService.createCollection(name: "Left")
        let right = try libraryService.createCollection(name: "Right")
        for book in leftMembers {
            try libraryService.addBook(book, to: left)
        }
        for book in rightMembers {
            try libraryService.addBook(book, to: right)
        }
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )

        try service.refreshRecommendations()
        let leftID = try #require(left.databaseID)
        let rightID = try #require(right.databaseID)

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: leftID
        ).isEmpty)
        #expect(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: rightID
        ).isEmpty)
    }

    @Test("dismissed overlapping create groups require stronger evidence to return")
    func dismissedOverlappingCreateGroupsRequireEvidenceGain() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let first = try context.books.insert(sampleBook(
            title: "忽略作品1",
            filepath: "/tmp/dismiss-overlap-1.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "忽略作品2",
            hash: "sha1-dismiss-overlap-2",
            filepath: "/tmp/dismiss-overlap-2.cbz",
            tags: tags
        ))
        var third = try context.books.insert(sampleBook(
            title: "忽略作品3",
            hash: "sha1-dismiss-overlap-3",
            filepath: "/tmp/dismiss-overlap-3.cbz",
            tags: tags
        ))
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )
        try service.refreshRecommendations()
        let dismissed = try #require(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).first)
        try service.dismiss(dismissed)

        third.exist = false
        _ = try context.books.update(third)
        try service.refreshRecommendations()
        #expect(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).isEmpty)

        third.exist = true
        _ = try context.books.update(third)
        let fourth = try context.books.insert(sampleBook(
            title: "忽略作品4",
            hash: "sha1-dismiss-overlap-4",
            filepath: "/tmp/dismiss-overlap-4.cbz",
            tags: tags
        ))
        try service.refreshRecommendations()
        let returned = try #require(try context.collectionRecommendations.fetchPending(
            kind: .createCollection,
            targetCollectionID: nil
        ).first)
        let returnedIDs = Set(try context.collectionRecommendations.fetchMemberBookIDs(
            recommendationID: try #require(returned.databaseID)
        ))
        #expect(returnedIDs == [
            try #require(first.databaseID),
            try #require(second.databaseID),
            try #require(third.databaseID),
            try #require(fourth.databaseID)
        ])
    }

    @Test("accepting one add recommendation stales conflicting target recommendations")
    func acceptingAddRecommendationStalesConflictingTargetCandidates() throws {
        let context = try makeContext()
        let tags = #"["artist:maker","group:circle"]"#
        let first = try context.books.insert(sampleBook(
            title: "缓存同步1",
            filepath: "/tmp/stale-add-1.cbz",
            tags: tags
        ))
        let second = try context.books.insert(sampleBook(
            title: "缓存同步2",
            hash: "sha1-stale-add-2",
            filepath: "/tmp/stale-add-2.cbz",
            tags: tags
        ))
        let third = try context.books.insert(sampleBook(
            title: "缓存同步3",
            hash: "sha1-stale-add-3",
            filepath: "/tmp/stale-add-3.cbz",
            tags: tags
        ))
        _ = try context.books.insert(sampleBook(
            title: "缓存同步4",
            hash: "sha1-stale-add-4",
            filepath: "/tmp/stale-add-4.cbz",
            tags: tags
        ))
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections,
            collectionRecommendationRepository: context.collectionRecommendations
        )
        let collection = try libraryService.createCollection(name: "缓存同步")
        try libraryService.addBook(first, to: collection)
        try libraryService.addBook(second, to: collection)
        let service = CollectionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.collectionRecommendations
        )
        try service.refreshRecommendations()
        let collectionID = try #require(collection.databaseID)
        let pending = try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collectionID
        )
        #expect(pending.count == 2)
        let thirdID = try #require(third.databaseID)
        let thirdRecommendation = try #require(pending.first { recommendation in
            guard let id = recommendation.databaseID else { return false }
            return (try? context.collectionRecommendations.fetchMemberBookIDs(
                recommendationID: id
            ).contains(thirdID)) == true
        })

        try libraryService.acceptAddToCollectionRecommendation(
            thirdRecommendation,
            book: third,
            collection: collection
        )

        #expect(try context.collectionRecommendations.fetchPending(
            kind: .addToCollection,
            targetCollectionID: collectionID
        ).isEmpty)
    }

    @MainActor
    @Test("store reorders collection members without full refresh")
    func storeReordersCollectionMembersWithoutFullRefresh() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/store-reorder-first.cbz"))
        let second = try context.books.insert(sampleBook(
            title: "Second",
            hash: "sha1-store-reorder-second",
            filepath: "/tmp/store-reorder-second.cbz"
        ))
        let candidate = try context.books.insert(sampleBook(
            title: "Candidate",
            hash: "sha1-store-reorder-candidate",
            filepath: "/tmp/store-reorder-candidate.cbz"
        ))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Series")
        try service.addBook(first, to: collection)
        try service.addBook(second, to: collection)
        let collectionID = try #require(collection.databaseID)
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let commitGate = CollectionOrderCommitGate()
        let store = CatalogStore(
            service: service,
            sleep: { nanoseconds in
                try await commitGate.sleep(nanoseconds)
            }
        )
        store.refresh()
        let selected = try #require(store.collections.first)
        let derivedRevision = store.derivedDataRevision
        let orderRevision = store.collectionOrderRevision
        let candidateIDs = store.collectionCandidateBooks(for: selected, query: "").map(\.id)
        #expect(candidateIDs.contains(candidate.id))

        store.reorderBooks(Array(store.displayBooks(in: selected).reversed()), in: selected)

        #expect(store.displayBooks(in: selected).map(\.databaseID) == [secondID, firstID])
        #expect(store.collectionOrderRevision == orderRevision + 1)
        #expect(store.derivedDataRevision == derivedRevision)
        #expect(store.collectionCandidateBooks(for: selected, query: "").map(\.id) == candidateIDs)
        await commitGate.waitForSleepCount(1)
        #expect(try context.books.fetchByCollectionID(collectionID)
            .filter(\.isPrimaryVersion)
            .map(\.databaseID) == [firstID, secondID])
        await commitGate.resumeAll()
        await store.waitForCollectionOrderCommit(collectionID: collectionID)
        #expect(try context.books.fetchByCollectionID(collectionID)
            .filter(\.isPrimaryVersion)
            .map(\.databaseID) == [secondID, firstID])
        #expect(store.collectionCandidateBooks(for: selected, query: "").map(\.id) == candidateIDs)
    }

    @MainActor
    @Test("store debounces collection member order commits")
    func storeDebouncesCollectionMemberOrderCommits() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/debounce-reorder-first.cbz"))
        let second = try context.books.insert(sampleBook(
            title: "Second",
            hash: "sha1-debounce-reorder-second",
            filepath: "/tmp/debounce-reorder-second.cbz"
        ))
        let third = try context.books.insert(sampleBook(
            title: "Third",
            hash: "sha1-debounce-reorder-third",
            filepath: "/tmp/debounce-reorder-third.cbz"
        ))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Series")
        try service.addBook(first, to: collection)
        try service.addBook(second, to: collection)
        try service.addBook(third, to: collection)
        let collectionID = try #require(collection.databaseID)
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let thirdID = try #require(third.databaseID)
        let store = CatalogStore(
            service: service,
            sleep: { _ in
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        )
        store.refresh()
        let selected = try #require(store.collections.first)
        let displayBooks = store.displayBooks(in: selected)
        let byID = Dictionary(uniqueKeysWithValues: displayBooks.compactMap { book in
            book.databaseID.map { ($0, book) }
        })

        store.reorderBooks([byID[secondID], byID[firstID], byID[thirdID]].compactMap(\.self), in: selected)
        store.reorderBooks([byID[thirdID], byID[secondID], byID[firstID]].compactMap(\.self), in: selected)

        #expect(store.displayBooks(in: selected).map(\.databaseID) == [thirdID, secondID, firstID])
        #expect(store.isSavingOrganization)
        #expect(store.savingOrganizationKeys.contains("collection:\(collectionID)"))
        await store.waitForCollectionOrderCommit(collectionID: collectionID)
        #expect(!store.isSavingOrganization)
        #expect(try context.books.fetchByCollectionID(collectionID)
            .filter(\.isPrimaryVersion)
            .map(\.databaseID) == [thirdID, secondID, firstID])
    }

    @Test("manual collection deletion rolls back and membership writes preserve fresh metadata")
    func manualCollectionMutationIsAtomicAndUsesCurrentRows() throws {
        let context = try makeContext()
        let stale = try context.books.insert(sampleBook(title: "Old", filepath: "/tmp/collection-atomic.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Atomic")
        let bookID = try #require(stale.databaseID)
        let collectionID = try #require(collection.databaseID)
        var current = try #require(try context.books.fetch(id: bookID))
        current.title = "Fresh metadata"
        _ = try context.books.update(current)
        try service.addBook(stale, to: collection)
        #expect(try context.books.fetch(id: bookID)?.title == "Fresh metadata")

        try context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_collection_delete BEFORE DELETE ON book_collections
                BEGIN SELECT RAISE(ABORT, 'forced delete failure'); END
                """)
        }
        #expect(throws: Error.self) { try service.deleteCollection(collection) }
        #expect(try context.collections.fetch(id: collectionID) != nil)
        #expect(try context.books.fetch(id: bookID)?.collectionID == collection.databaseID)
    }

    @MainActor
    @Test("series count follows displayed members and deletion keeps books and versions")
    func seriesCountAndDeletion() async throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/series-delete-primary.cbz"))
        let secondary = try context.books.insert(sampleBook(title: "Secondary", hash: "series-delete-secondary", filepath: "/tmp/series-delete-secondary.cbz"))
        let standalone = try context.books.insert(sampleBook(title: "Standalone", hash: "series-delete-standalone", filepath: "/tmp/series-delete-standalone.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionGroupMutationRepository: context.versionGroups
        )
        let versionGroup = try service.createVersionGroup(with: [primary, secondary])
        let collection = try service.createCollection(name: "Keep Books")
        try service.addBook(primary, to: collection)
        let store = CatalogStore(service: service)
        store.refresh()
        let selected = try #require(store.collections.first)
        store.selectedCollectionID = selected.id
        #expect(store.displayBooks(in: selected).count == 1)
        #expect(store.books(in: selected).count == 2)

        store.addBook(standalone, to: selected)
        #expect(store.displayBooks(in: selected).count == 2)
        await store.waitForOrganizationMutations()
        #expect(store.displayBooks(in: selected).count == 2)
        store.removeBook(standalone, from: selected)
        #expect(store.displayBooks(in: selected).count == 1)
        await store.waitForOrganizationMutations()
        store.setPrimaryVersion(secondary)
        #expect(store.displayBooks(in: selected).map(\.id) == [secondary.id])
        await store.waitForOrganizationMutations()

        store.deleteCollection(selected)
        #expect(store.isSavingOrganization)
        #expect(store.savingOrganizationKeys.contains("collection:\(try #require(collection.databaseID))"))
        await store.waitForOrganizationMutations()
        #expect(store.collection(id: selected.id) == nil)
        #expect(store.organizationSaveError == nil)
        #expect(try context.books.fetch(id: try #require(primary.databaseID))?.collectionID == nil)
        #expect(try context.books.fetch(id: try #require(secondary.databaseID))?.collectionID == nil)
        #expect(try context.books.fetch(id: try #require(primary.databaseID))?.versionGroupID == versionGroup.databaseID)
        #expect(try context.books.fetch(id: try #require(secondary.databaseID))?.versionGroupID == versionGroup.databaseID)
    }

    @MainActor
    @Test("failed series deletion restores the saved group and shows an error")
    func failedSeriesDeletionRestoresState() async throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(filepath: "/tmp/failed-series-delete.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Stay")
        try service.addBook(book, to: collection)
        let store = CatalogStore(service: service)
        store.refresh()
        let selected = try #require(store.collections.first)
        store.selectedCollectionID = selected.id
        try await context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_series_delete BEFORE DELETE ON book_collections
                BEGIN SELECT RAISE(ABORT, 'forced series deletion failure'); END
                """)
        }
        store.deleteCollection(selected)
        await store.waitForOrganizationMutations()
        #expect(store.collection(id: selected.id) != nil)
        #expect(store.selectedCollectionID == selected.id)
        #expect(store.displayBooks(in: selected).map(\.id) == [book.id])
        #expect(store.organizationSaveError?.contains("forced series deletion failure") == true)
        #expect(try context.books.fetch(id: try #require(book.databaseID))?.collectionID == collection.databaseID)
    }

    @Test("manual version label write rolls back both representations")
    func manualVersionLabelMutationIsAtomic() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(filepath: "/tmp/version-label-atomic.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels
        )
        try context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_version_label BEFORE INSERT ON book_version_labels
                BEGIN SELECT RAISE(ABORT, 'forced label failure'); END
                """)
        }
        #expect(throws: Error.self) { try service.setVersionLabels(["Translated"], for: book) }
        let bookID = try #require(book.databaseID)
        #expect(try context.books.fetch(id: bookID)?.versionLabel == nil)
        #expect(try context.versionLabels.fetchLabels(bookID: bookID).isEmpty)
        #expect(try context.versionLabelSuggestions.fetchAll().isEmpty)
    }

    @Test("manual version group creation rolls back every member")
    func manualVersionGroupCreationIsAtomic() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(filepath: "/tmp/version-atomic-first.cbz"))
        let second = try context.books.insert(sampleBook(hash: "version-atomic-second", filepath: "/tmp/version-atomic-second.cbz"))
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            versionGroupRepository: context.versionGroups
        )
        try context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_second_version_member BEFORE UPDATE OF version_group_id ON library_books
                WHEN NEW.id = \(secondID)
                BEGIN SELECT RAISE(ABORT, 'forced version failure'); END
                """)
        }
        #expect(throws: Error.self) { try service.createVersionGroup(with: [first, second]) }
        #expect(try context.versionGroups.fetchAll().isEmpty)
        #expect(try context.books.fetch(id: firstID)?.versionGroupID == nil)
        #expect(try context.books.fetch(id: secondID)?.versionGroupID == nil)
    }

    @Test("new secondary versions inherit the primary's series position")
    func secondaryVersionsInheritLogicalCollectionOrder() throws {
        let context = try makeContext()
        let preceding = try context.books.insert(sampleBook(filepath: "/tmp/order-preceding.cbz"))
        let primary = try context.books.insert(sampleBook(hash: "order-primary", filepath: "/tmp/order-primary.cbz"))
        let second = try context.books.insert(sampleBook(hash: "order-second", filepath: "/tmp/order-second.cbz"))
        let third = try context.books.insert(sampleBook(hash: "order-third", filepath: "/tmp/order-third.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let collection = try service.createCollection(name: "Ordered")
        try service.addBook(preceding, to: collection)
        try service.addBook(primary, to: collection)
        let group = try service.createVersionGroup(with: [primary, second])
        try service.addBook(third, toVersionGroup: group)
        let primaryID = try #require(primary.databaseID)
        let secondID = try #require(second.databaseID)
        let thirdID = try #require(third.databaseID)
        let expectedOrder = try #require(context.books.fetch(id: primaryID)?.collectionOrder)
        #expect(expectedOrder == 1)
        #expect(try context.books.fetch(id: secondID)?.collectionOrder == expectedOrder)
        #expect(try context.books.fetch(id: thirdID)?.collectionOrder == expectedOrder)
        try service.setPrimaryVersion(third)
        #expect(try context.books.fetch(id: primaryID)?.collectionOrder == expectedOrder)
        #expect(try context.books.fetch(id: secondID)?.collectionOrder == expectedOrder)
        #expect(try context.books.fetch(id: thirdID)?.collectionOrder == expectedOrder)
        try service.setPrimaryVersion(primary)
        #expect(try context.books.fetch(id: primaryID)?.collectionOrder == expectedOrder)
        #expect(try context.books.fetch(id: secondID)?.collectionOrder == expectedOrder)
        #expect(try context.books.fetch(id: thirdID)?.collectionOrder == expectedOrder)
        #expect(try context.books.fetch(id: primaryID)?.isPrimaryVersion == true)
        #expect(try context.books.fetch(id: thirdID)?.isPrimaryVersion == false)
    }

    @Test("primary version switches in both book ID directions")
    func primaryVersionSwitchRespectsUniqueIndex() throws {
        let context = try makeContext()
        let lowerID = try context.books.insert(sampleBook(filepath: "/tmp/primary-lower.cbz"))
        let higherID = try context.books.insert(sampleBook(hash: "primary-higher", filepath: "/tmp/primary-higher.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [higherID, lowerID])
        let groupID = try #require(group.databaseID)
        let lowerBookID = try #require(lowerID.databaseID)
        let higherBookID = try #require(higherID.databaseID)

        for target in [lowerID, higherID, lowerID] {
            try service.setPrimaryVersion(target)
            let members = try context.books.fetchByVersionGroupID(groupID)
            #expect(members.count == 2)
            #expect(members.filter(\.isPrimaryVersion).map(\.id) == [target.id])
            #expect(members.first(where: { $0.id == target.id })?.hiddenBook == false)
            #expect(members.first(where: { $0.id != target.id })?.hiddenBook == true)
        }
        #expect(lowerBookID < higherBookID)
        try context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_redundant_primary_write BEFORE UPDATE ON library_books
                WHEN NEW.id = \(lowerBookID)
                BEGIN SELECT RAISE(ABORT, 'redundant primary write'); END
                """)
        }
        try service.setPrimaryVersion(lowerID)
    }

    @Test("failed primary promotion restores the original primary transactionally")
    func failedPrimaryPromotionRollsBackDemotion() throws {
        let context = try makeContext()
        let replacement = try context.books.insert(sampleBook(filepath: "/tmp/rollback-replacement.cbz"))
        let original = try context.books.insert(sampleBook(hash: "rollback-original", filepath: "/tmp/rollback-original.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            versionGroupRepository: context.versionGroups
        )
        _ = try service.createVersionGroup(with: [original, replacement])
        let originalID = try #require(original.databaseID)
        let replacementID = try #require(replacement.databaseID)
        try context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_primary_promotion BEFORE UPDATE OF is_primary_version ON library_books
                WHEN NEW.id = \(replacementID) AND NEW.is_primary_version = 1
                BEGIN SELECT RAISE(ABORT, 'forced primary promotion failure'); END
                """)
        }

        #expect(throws: Error.self) { try service.setPrimaryVersion(replacement) }
        #expect(try context.books.fetch(id: originalID)?.isPrimaryVersion == true)
        #expect(try context.books.fetch(id: originalID)?.hiddenBook == false)
        #expect(try context.books.fetch(id: replacementID)?.isPrimaryVersion == false)
        #expect(try context.books.fetch(id: replacementID)?.hiddenBook == true)
    }

    @Test("organization snapshots include only changed books for names and labels")
    func organizationSnapshotsStayTargeted() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(filepath: "/tmp/targeted-first.cbz"))
        let second = try context.books.insert(sampleBook(hash: "targeted-second", filepath: "/tmp/targeted-second.cbz"))
        let secondID = try #require(second.databaseID)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        _ = try service.createVersionGroup(with: [first, second])
        let collection = try service.createCollection(name: "Before")
        try service.addBook(first, to: collection)
        let worker = OrganizationMutationWorker(service: service)
        let renamed = try await worker.execute(
            .renameCollection(collection, "After"),
            selectedCollectionID: collection.databaseID,
            selectedVersionGroupID: nil
        )
        #expect(renamed.books.isEmpty)
        #expect(renamed.collections?.first?.name == "After")
        let labeled = try await worker.execute(
            .setVersionLabels(["Translated"], first),
            selectedCollectionID: collection.databaseID,
            selectedVersionGroupID: nil
        )
        #expect(labeled.books.map(\.id) == [first.id])
        #expect(try context.books.fetch(id: secondID)?.versionLabel == nil)
    }

    @MainActor
    @Test("organization queue preserves rapid reorder add and undo")
    func organizationQueuePreservesRapidChanges() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/queue-first.cbz"))
        let second = try context.books.insert(sampleBook(title: "Second", hash: "queue-second", filepath: "/tmp/queue-second.cbz"))
        let third = try context.books.insert(sampleBook(title: "Third", hash: "queue-third", filepath: "/tmp/queue-third.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Queue")
        try service.addBook(first, to: collection)
        try service.addBook(second, to: collection)
        let store = CatalogStore(service: service)
        store.refresh()
        let selected = try #require(store.collections.first)
        let collectionID = try #require(collection.databaseID)
        let thirdID = try #require(third.databaseID)
        store.reorderBooks(Array(store.displayBooks(in: selected).reversed()), in: selected)
        store.addBook(third, to: selected)
        #expect(store.isSavingOrganization)
        #expect(store.displayBooks(in: selected).map(\.id) == [second.id, first.id, third.id])
        await store.waitForOrganizationMutations()
        #expect(try context.books.fetchByCollectionID(collectionID)
            .filter(\.isPrimaryVersion).map(\.id) == [second.id, first.id, third.id])

        store.removeBook(third, from: selected)
        await store.waitForOrganizationMutations()
        #expect(try context.books.fetch(id: thirdID)?.collectionID == nil)
    }

    @MainActor
    @Test("paused organization write leaves UI responsive and newer intent visible")
    func pausedOrganizationWriteKeepsUIResponsive() async throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(filepath: "/tmp/queue-paused.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Paused")
        let bookID = try #require(book.databaseID)
        let gate = OrganizationExecutionGate()
        let store = CatalogStore(service: service, organizationBeforeExecute: { await gate.pause() })
        store.refresh()
        store.addBook(book, to: collection)
        await gate.waitForStarts(1)
        #expect(store.displayBooks(in: collection).map(\.id) == [book.id])
        #expect(store.isSavingOrganization)
        store.searchText = "still responsive"
        #expect(store.searchText == "still responsive")

        store.removeBook(book, from: collection)
        #expect(store.displayBooks(in: collection).isEmpty)
        await gate.releaseNext()
        await gate.waitForStarts(2)
        #expect(store.displayBooks(in: collection).isEmpty)
        #expect(store.isSavingOrganization)
        await gate.releaseNext()
        await store.waitForOrganizationMutations()
        #expect(!store.isSavingOrganization)
        #expect(try context.books.fetch(id: bookID)?.collectionID == nil)
    }

    @MainActor
    @Test("batch member removal reports each failure and restores its version companions")
    func batchCollectionRemovalRestoresFailedMembers() async throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/batch-remove-primary.cbz"))
        let secondary = try context.books.insert(sampleBook(title: "Secondary", hash: "batch-remove-secondary", filepath: "/tmp/batch-remove-secondary.cbz"))
        let other = try context.books.insert(sampleBook(title: "Other", hash: "batch-remove-other", filepath: "/tmp/batch-remove-other.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        _ = try service.createVersionGroup(with: [primary, secondary])
        let collection = try service.createCollection(name: "Batch")
        try service.addBook(primary, to: collection)
        try service.addBook(other, to: collection)
        let collectionID = try #require(collection.databaseID)
        let secondaryID = try #require(secondary.databaseID)
        let primaryID = try #require(primary.databaseID)
        let otherID = try #require(other.databaseID)
        try await context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_companion_removal BEFORE UPDATE OF collection_id ON library_books
                WHEN NEW.id = \(secondaryID) AND NEW.collection_id IS NULL
                BEGIN SELECT RAISE(ABORT, 'forced companion removal failure'); END
                """)
        }

        let store = CatalogStore(service: service)
        store.refresh()
        store.removeBooks([primary, other], from: collection)
        #expect(store.displayBooks(in: collection).isEmpty)
        await store.waitForOrganizationMutations()

        #expect(try context.books.fetch(id: primaryID)?.collectionID == collectionID)
        #expect(try context.books.fetch(id: secondaryID)?.collectionID == collectionID)
        #expect(try context.books.fetch(id: otherID)?.collectionID == nil)
        #expect(store.displayBooks(in: collection).map(\.id) == [primary.id])
        #expect(store.organizationSaveError?.contains("Primary") == true)
    }

    @MainActor
    @Test("reorder flushes before moving selected members to another series")
    func batchCollectionMovePreservesOrder() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/batch-move-first.cbz"))
        let second = try context.books.insert(sampleBook(title: "Second", hash: "batch-move-second", filepath: "/tmp/batch-move-second.cbz"))
        let third = try context.books.insert(sampleBook(title: "Third", hash: "batch-move-third", filepath: "/tmp/batch-move-third.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let source = try service.createCollection(name: "Source")
        let destination = try service.createCollection(name: "Destination")
        for book in [first, second, third] { try service.addBook(book, to: source) }
        let sourceID = try #require(source.databaseID)
        let destinationID = try #require(destination.databaseID)
        let store = CatalogStore(service: service)
        store.refresh()
        store.reorderBooks([third, second, first], in: source)
        store.addBooks([second, first], to: destination)
        #expect(store.displayBooks(in: source).map(\.id) == [third.id])
        #expect(store.displayBooks(in: destination).map(\.id) == [second.id, first.id])
        await store.waitForOrganizationMutations()
        #expect(try context.books.fetchByCollectionID(sourceID).filter(\.isPrimaryVersion).map(\.id) == [third.id])
        #expect(try context.books.fetchByCollectionID(destinationID).filter(\.isPrimaryVersion).map(\.id) == [second.id, first.id])
        #expect(store.organizationSaveError == nil)
    }

    @MainActor
    @Test("older reorder result cannot restore members already queued for transfer")
    func queuedBatchMoveKeepsLatestIntent() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/queued-move-first.cbz"))
        let second = try context.books.insert(sampleBook(title: "Second", hash: "queued-move-second", filepath: "/tmp/queued-move-second.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let source = try service.createCollection(name: "Source")
        let destination = try service.createCollection(name: "Destination")
        try service.addBook(first, to: source)
        try service.addBook(second, to: source)
        let gate = OrganizationExecutionGate()
        let store = CatalogStore(service: service, organizationBeforeExecute: { await gate.pause() })
        store.refresh()
        store.reorderBooks([second, first], in: source)
        store.addBooks([second], to: destination)
        await gate.waitForStarts(1)
        #expect(store.displayBooks(in: source).map(\.id) == [first.id])
        #expect(store.displayBooks(in: destination).map(\.id) == [second.id])
        await gate.releaseNext()
        await gate.waitForStarts(2)
        #expect(store.displayBooks(in: source).map(\.id) == [first.id])
        #expect(store.displayBooks(in: destination).map(\.id) == [second.id])
        await gate.releaseNext()
        await store.waitForOrganizationMutations()
        #expect(store.displayBooks(in: source).map(\.id) == [first.id])
        #expect(store.displayBooks(in: destination).map(\.id) == [second.id])
    }

    @MainActor
    @Test("batch transfer reconciles successes and restores failed members")
    func batchCollectionMoveReportsPartialFailure() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/partial-move-first.cbz"))
        let second = try context.books.insert(sampleBook(title: "Second", hash: "partial-move-second", filepath: "/tmp/partial-move-second.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let source = try service.createCollection(name: "Source")
        let destination = try service.createCollection(name: "Destination")
        try service.addBook(first, to: source)
        try service.addBook(second, to: source)
        let sourceID = try #require(source.databaseID)
        let destinationID = try #require(destination.databaseID)
        let secondID = try #require(second.databaseID)
        try await context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_selected_transfer BEFORE UPDATE OF collection_id ON library_books
                WHEN NEW.id = \(secondID) AND NEW.collection_id = \(destinationID)
                BEGIN SELECT RAISE(ABORT, 'forced transfer failure'); END
                """)
        }
        let store = CatalogStore(service: service)
        store.refresh()
        store.addBooks([first, second], to: destination)
        #expect(store.displayBooks(in: source).isEmpty)
        await store.waitForOrganizationMutations()
        #expect(store.displayBooks(in: source).map(\.id) == [second.id])
        #expect(store.displayBooks(in: destination).map(\.id) == [first.id])
        #expect(try context.books.fetch(id: secondID)?.collectionID == sourceID)
        #expect(store.organizationSaveError?.contains("Second") == true)
    }

    @MainActor
    @Test("immediate version add undo is serialized against current database membership")
    func immediateVersionAddUndoUsesCurrentDatabaseState() async throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(filepath: "/tmp/version-undo-primary.cbz"))
        let existing = try context.books.insert(sampleBook(hash: "version-undo-existing", filepath: "/tmp/version-undo-existing.cbz"))
        let candidate = try context.books.insert(sampleBook(hash: "version-undo-candidate", filepath: "/tmp/version-undo-candidate.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [primary, existing])
        let groupID = try #require(group.databaseID)
        let candidateID = try #require(candidate.databaseID)
        let gate = OrganizationExecutionGate()
        let store = CatalogStore(service: service, organizationBeforeExecute: { await gate.pause() })
        store.refresh()
        store.addBooks([candidate], toVersionGroup: group)
        store.removeBookFromVersionGroup(candidate)
        await gate.waitForStarts(1)
        #expect(store.isSavingOrganization)
        await gate.releaseNext()
        await gate.waitForStarts(2)
        await gate.releaseNext()
        await store.waitForOrganizationMutations()
        #expect(try context.books.fetch(id: candidateID)?.versionGroupID == nil)
        #expect(try context.versionGroups.fetch(id: groupID) != nil)
    }

    @MainActor
    @Test("failed background organization write restores optimistic UI")
    func failedOrganizationMutationRestoresStore() async throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(filepath: "/tmp/queue-rollback.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            collectionRepository: context.collections
        )
        let collection = try service.createCollection(name: "Rollback")
        let collectionID = try #require(collection.databaseID)
        try await context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_collection_add BEFORE UPDATE OF collection_id ON library_books
                WHEN NEW.collection_id = \(collectionID)
                BEGIN SELECT RAISE(ABORT, 'forced add failure'); END
                """)
        }
        let store = CatalogStore(service: service)
        let bookID = try #require(book.databaseID)
        store.refresh()
        store.addBook(book, to: collection)
        #expect(store.displayBooks(in: collection).map(\.id) == [book.id])
        await store.waitForOrganizationMutations()
        #expect(store.displayBooks(in: collection).isEmpty)
        #expect(try context.books.fetch(id: bookID)?.collectionID == nil)
        #expect(store.loadError != nil)
    }

    @MainActor
    @Test("primary version switch is optimistic and restores after a failed promotion")
    func primaryVersionSwitchRestoresOptimisticState() async throws {
        let context = try makeContext()
        let lower = try context.books.insert(sampleBook(filepath: "/tmp/queued-primary-lower.cbz"))
        let higher = try context.books.insert(sampleBook(hash: "queued-primary-higher", filepath: "/tmp/queued-primary-higher.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            versionGroupRepository: context.versionGroups
        )
        _ = try service.createVersionGroup(with: [higher, lower])
        let lowerID = try #require(lower.databaseID)
        let higherID = try #require(higher.databaseID)
        let gate = OrganizationExecutionGate()
        let store = CatalogStore(service: service, organizationBeforeExecute: { await gate.pause() })
        store.refresh()

        store.setPrimaryVersion(lower)
        await gate.waitForStarts(1)
        #expect(store.book(id: lower.id)?.isPrimaryVersion == true)
        #expect(store.book(id: higher.id)?.isPrimaryVersion == false)
        #expect(store.savingOrganizationKeys.contains("book:\(lowerID)"))
        await gate.releaseNext()
        await store.waitForOrganizationMutations()
        #expect(try context.books.fetch(id: lowerID)?.isPrimaryVersion == true)
        #expect(store.loadError == nil)

        try await context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_queued_primary_promotion BEFORE UPDATE OF is_primary_version ON library_books
                WHEN NEW.id = \(higherID) AND NEW.is_primary_version = 1
                BEGIN SELECT RAISE(ABORT, 'forced queued primary failure'); END
                """)
        }
        store.setPrimaryVersion(higher)
        await gate.waitForStarts(2)
        #expect(store.book(id: higher.id)?.isPrimaryVersion == true)
        await gate.releaseNext()
        await store.waitForOrganizationMutations()
        #expect(try context.books.fetch(id: lowerID)?.isPrimaryVersion == true)
        #expect(try context.books.fetch(id: higherID)?.isPrimaryVersion == false)
        #expect(store.book(id: lower.id)?.isPrimaryVersion == true)
        #expect(store.book(id: higher.id)?.isPrimaryVersion == false)
        #expect(store.loadError != nil)
    }

    @MainActor
    @Test("rapid version label edits keep the latest value")
    func rapidVersionLabelEditsKeepLatestValue() async throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(filepath: "/tmp/queue-labels.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels
        )
        let store = CatalogStore(service: service)
        let bookID = try #require(book.databaseID)
        store.refresh()
        store.setVersionLabels(["Alpha"], for: book)
        store.setVersionLabels(["Alpha", "Beta"], for: book)
        store.setVersionLabels(["Beta"], for: book)
        #expect(store.versionLabels(for: try #require(store.book(id: book.id))) == ["Beta"])
        await store.waitForOrganizationMutations()
        #expect(try context.versionLabels.fetchLabels(bookID: bookID) == ["Beta"])
    }

    @Test("accepting create recommendation rolls back when recommendation update fails")
    func acceptingCreateRecommendationRollsBackWhenRecommendationUpdateFails() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "Story", filepath: "/tmp/rollback-a.cbz"))
        let second = try context.books.insert(sampleBook(title: "Story Chinese", filepath: "/tmp/rollback-b.cbz"))
        let firstID = try #require(first.databaseID)
        let secondID = try #require(second.databaseID)
        try context.versionRecommendations.replacePending(with: [
            VersionRecommendationCandidate(
                kind: .createGroup,
                targetVersionGroupID: nil,
                bookIDs: [firstID, secondID],
                score: 100,
                reasons: ["title"],
                fingerprint: "rollback-create"
            )
        ])
        let recommendation = try #require(try context.versionRecommendations.fetchPending(
            kind: .createGroup,
            targetVersionGroupID: nil
        ).first)
        try context.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_accept_version_recommendation
                BEFORE UPDATE OF status ON version_recommendations
                WHEN NEW.status = 'accepted'
                BEGIN
                    SELECT RAISE(ABORT, 'forced recommendation failure');
                END
                """)
        }
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels,
            versionRecommendationRepository: context.versionRecommendations
        )

        #expect(throws: Error.self) {
            _ = try service.acceptCreateVersionGroupRecommendation(recommendation, books: [first, second])
        }

        #expect(try context.versionGroups.fetchAll().isEmpty)
        #expect(try context.books.fetch(id: firstID)?.versionGroupID == nil)
        #expect(try context.books.fetch(id: secondID)?.versionGroupID == nil)
    }

    @Test("deleting version group dissolves members and clears labels")
    func deletingVersionGroupDissolvesMembersAndClearsLabels() throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/delete-group-a.cbz"))
        let secondary = try context.books.insert(sampleBook(title: "Secondary", filepath: "/tmp/delete-group-b.cbz"))
        let candidate = try context.books.insert(sampleBook(title: "Candidate", filepath: "/tmp/delete-group-c.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionLabelSuggestionRepository: context.versionLabelSuggestions,
            bookVersionLabelRepository: context.versionLabels,
            versionRecommendationRepository: context.versionRecommendations
        )
        let group = try service.createVersionGroup(with: [primary, secondary])
        try service.setVersionLabels(["翻译", "彩色"], for: primary)
        try service.setVersionLabels(["无修"], for: secondary)
        let groupID = try #require(group.databaseID)
        let candidateID = try #require(candidate.databaseID)
        try context.versionRecommendations.replacePending(with: [
            VersionRecommendationCandidate(
                kind: .addToGroup,
                targetVersionGroupID: groupID,
                bookIDs: [candidateID],
                score: 80,
                reasons: ["cover"],
                fingerprint: "delete-group-add"
            )
        ])
        #expect(try context.versionRecommendations.fetchPendingAddToGroupCounts()[groupID] == 1)

        try service.deleteVersionGroup(group)

        #expect(try context.versionGroups.fetchAll().isEmpty)
        for book in [primary, secondary] {
            let bookID = try #require(book.databaseID)
            let dissolved = try #require(try context.books.fetch(id: bookID))
            #expect(dissolved.versionGroupID == nil)
            #expect(dissolved.isPrimaryVersion)
            #expect(dissolved.versionLabel == nil)
            #expect(!dissolved.hiddenBook)
            #expect(try context.versionLabels.fetchLabels(bookID: bookID).isEmpty)
        }
        #expect(try context.versionRecommendations.fetchPendingAddToGroupCounts()[groupID] == nil)
    }

    @Test("version recommendations no longer hard-reject numbered titles")
    @MainActor
    func versionRecommendationsNoLongerHardRejectNumberedTitles() async throws {
        let context = try makeContext()
        for volume in [8, 7, 6] {
            var book = sampleBook(
                title: "無口少女の痴漢被害\(volume)",
                hash: "sha1-series-\(volume)",
                filepath: "/tmp/series-\(volume).cbz",
                tags: #"["artist:maker","group:circle a","parody:source"]"#
            )
            book.category = "Doujinshi"
            _ = try context.books.insert(book)
        }

        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionRecommendationRepository: context.versionRecommendations
        )
        let store = CatalogStore(service: service)
        store.refresh()
        store.refreshVersionRecommendations()
        await store.waitForVersionRecommendationRefresh()

        #expect(!store.createVersionGroupRecommendations.isEmpty)
    }

    @Test("version recommendations can add numbered title to group")
    @MainActor
    func versionRecommendationsCanAddNumberedTitleToGroup() async throws {
        let context = try makeContext()
        var primary = sampleBook(
            title: "無口少女の痴漢被害7",
            filepath: "/tmp/series-7.cbz",
            tags: #"["artist:maker","group:circle a","parody:source"]"#
        )
        primary.category = "Doujinshi"
        var candidate = sampleBook(
            title: "無口少女の痴漢被害8",
            hash: "sha1-series-8",
            filepath: "/tmp/series-8.cbz",
            tags: #"["artist:maker","group:circle a","parody:source"]"#
        )
        candidate.category = "Doujinshi"
        let savedPrimary = try context.books.insert(primary)
        _ = try context.books.insert(candidate)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionRecommendationRepository: context.versionRecommendations
        )
        let group = try service.createVersionGroup(with: [savedPrimary])

        let store = CatalogStore(service: service)
        store.refresh()
        store.selectedVersionGroupID = group.id
        store.refreshVersionRecommendations()
        await store.waitForVersionRecommendationRefresh()

        #expect(store.addToSelectedVersionGroupRecommendations.count == 1)
    }

    @Test("version recommendations reject explicit category mismatches")
    @MainActor
    func versionRecommendationsRejectExplicitCategoryMismatches() async throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "[Circle A] Shared Story",
            filepath: "/tmp/category-a.cbz",
            tags: #"["artist:maker"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "[Chinese] Shared Story",
            hash: "sha1-category-b",
            filepath: "/tmp/category-b.cbz",
            tags: #"["artist:maker"]"#
        )
        second.category = "Manga"
        _ = try context.books.insert(first)
        _ = try context.books.insert(second)

        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups,
            versionRecommendationRepository: context.versionRecommendations
        )
        let store = CatalogStore(service: service)
        store.refresh()
        store.refreshVersionRecommendations()
        await store.waitForVersionRecommendationRefresh()

        #expect(store.createVersionGroupRecommendations.isEmpty)
    }

    @Test("cover similarity adds a reason to otherwise valid version recommendations")
    func coverSimilarityAddsReasonToValidRecommendations() throws {
        let context = try makeContext()
        var japanese = sampleBook(
            title: "[Circle A] Shared Story",
            filepath: "/tmp/cover-shared-jp.cbz",
            tags: #"["artist:maker","group:circle a","parody:source"]"#
        )
        japanese.category = "Doujinshi"
        var chinese = sampleBook(
            title: "[Chinese] Shared Story",
            hash: "sha1-cover-shared-zh",
            filepath: "/tmp/cover-shared-zh.cbz",
            tags: #"["artist:maker","group:circle a","parody:source","language:chinese"]"#
        )
        chinese.category = "Doujinshi"
        let savedJapanese = try context.books.insert(japanese)
        let savedChinese = try context.books.insert(chinese)
        let japaneseID = try #require(savedJapanese.databaseID)
        let chineseID = try #require(savedChinese.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            japaneseID: [CoverVectorNeighbor(bookID: chineseID, distance: 0.2)],
            chineseID: [CoverVectorNeighbor(bookID: japaneseID, distance: 0.2)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: false)
        var recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)
        #expect(recommendations.count == 1)
        #expect(!recommendations[0].reasons.contains("cover"))

        try service.refreshRecommendations(useCoverSimilarity: true)
        recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.count == 1)
        #expect(recommendations[0].reasons.contains("cover"))
    }

    @Test("cover similarity can generate recommendations when titles differ")
    func coverSimilarityCanGenerateRecommendationsWhenTitlesDiffer() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Completely Different Story",
            filepath: "/tmp/cover-only-a.cbz",
            tags: #"["group:circle a"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Unrelated Bonus Book",
            hash: "sha1-cover-only-b",
            filepath: "/tmp/cover-only-b.cbz",
            tags: #"["group:circle a"]"#
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 0.1)],
            secondID: [CoverVectorNeighbor(bookID: firstID, distance: 0.1)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.count == 1)
        #expect(recommendations[0].reasons.contains("cover"))
    }

    @Test("cover similarity accepts supported default-threshold matches")
    func coverSimilarityAcceptsSupportedDefaultThresholdMatches() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Shared Story Original",
            filepath: "/tmp/cover-supported-a.cbz"
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Shared Story Translation",
            hash: "sha1-cover-supported-b",
            filepath: "/tmp/cover-supported-b.cbz"
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 20)],
            secondID: [CoverVectorNeighbor(bookID: firstID, distance: 20)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.count == 1)
        #expect(recommendations[0].reasons.contains("cover"))
        #expect(recommendations[0].reasons.contains("title"))
    }

    @Test("cover similarity rejects unsupported default-threshold matches")
    func coverSimilarityRejectsUnsupportedDefaultThresholdMatches() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Completely Different Story",
            filepath: "/tmp/cover-unsupported-a.cbz"
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Unrelated Bonus Book",
            hash: "sha1-cover-unsupported-b",
            filepath: "/tmp/cover-unsupported-b.cbz"
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 20)],
            secondID: [CoverVectorNeighbor(bookID: firstID, distance: 20)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.isEmpty)
    }

    @Test("near-duplicate cover match bypasses auxiliary support")
    func nearDuplicateCoverMatchBypassesAuxiliarySupport() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Completely Different Story",
            filepath: "/tmp/cover-near-duplicate-a.cbz"
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Unrelated Bonus Book",
            hash: "sha1-cover-near-duplicate-b",
            filepath: "/tmp/cover-near-duplicate-b.cbz"
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 4)],
            secondID: [CoverVectorNeighbor(bookID: firstID, distance: 4)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.count == 1)
        #expect(recommendations[0].reasons.contains("cover"))
    }

    @Test("cover similarity rejects over-threshold title matches")
    func coverSimilarityRejectsOverThresholdTitleMatches() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Shared Story Original",
            filepath: "/tmp/cover-over-threshold-a.cbz"
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Shared Story Translation",
            hash: "sha1-cover-over-threshold-b",
            filepath: "/tmp/cover-over-threshold-b.cbz"
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 21)],
            secondID: [CoverVectorNeighbor(bookID: firstID, distance: 21)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.isEmpty)
    }

    @Test("cover similarity respects configured maximum distance")
    func coverSimilarityRespectsConfiguredMaximumDistance() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Completely Different Story",
            filepath: "/tmp/cover-threshold-a.cbz",
            tags: #"["group:circle a"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Unrelated Bonus Book",
            hash: "sha1-cover-threshold-b",
            filepath: "/tmp/cover-threshold-b.cbz",
            tags: #"["group:circle a"]"#
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 119.87)],
            secondID: [CoverVectorNeighbor(bookID: firstID, distance: 119.87)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true, maximumCoverDistance: 80)
        var recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)
        #expect(recommendations.isEmpty)

        try service.refreshRecommendations(useCoverSimilarity: true, maximumCoverDistance: 120)
        recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)
        #expect(recommendations.count == 1)
    }

    @Test("cover similarity requires mutual top three neighbors")
    func coverSimilarityRequiresMutualTopThreeNeighbors() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Completely Different Story",
            filepath: "/tmp/cover-rank-a.cbz",
            tags: #"["group:circle a"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Unrelated Bonus Book",
            hash: "sha1-cover-rank-b",
            filepath: "/tmp/cover-rank-b.cbz",
            tags: #"["group:circle a"]"#
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 61.0)],
            secondID: []
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true, maximumCoverDistance: 120)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.isEmpty)
    }

    @Test("indexed dissimilar covers reject title-only version recommendations")
    func indexedDissimilarCoversRejectTitleOnlyRecommendations() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "[Circle A] Shared Story",
            filepath: "/tmp/dissimilar-cover-a.cbz",
            tags: #"["artist:maker","group:circle a","parody:source"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "[Chinese] Shared Story",
            hash: "sha1-dissimilar-cover-b",
            filepath: "/tmp/dissimilar-cover-b.cbz",
            tags: #"["artist:maker","group:circle a","parody:source","language:chinese"]"#
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(indexedBookIDs: [firstID, secondID], neighbors: [:])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.isEmpty)
    }

    @Test("cover similarity still rejects explicit category mismatches")
    func coverSimilarityStillRejectsExplicitCategoryMismatches() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "Shared Cover Story",
            filepath: "/tmp/cover-category-a.cbz",
            tags: #"["artist:maker"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "Renamed Shared Cover Story",
            hash: "sha1-cover-category-b",
            filepath: "/tmp/cover-category-b.cbz",
            tags: #"["artist:maker"]"#
        )
        second.category = "Manga"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 0.1)],
            secondID: [CoverVectorNeighbor(bookID: firstID, distance: 0.1)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.isEmpty)
    }

    @Test("missing cover vectors fall back to title metadata recommendations")
    func missingCoverVectorsFallBackToTitleMetadataRecommendations() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "[Circle A] Shared Story",
            filepath: "/tmp/missing-cover-vector-a.cbz",
            tags: #"["artist:maker","group:circle a","parody:source"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "[Chinese] Shared Story",
            hash: "sha1-missing-cover-vector-b",
            filepath: "/tmp/missing-cover-vector-b.cbz",
            tags: #"["artist:maker","group:circle a","parody:source","language:chinese"]"#
        )
        second.category = "Doujinshi"
        _ = try context.books.insert(first)
        _ = try context.books.insert(second)
        let coverSearch = FakeCoverVectorSearch(indexedBookIDs: [], neighbors: [:])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.count == 1)
        #expect(!recommendations[0].reasons.contains("cover"))
    }

    @Test("add to group recommendations use cover neighbors as candidate source")
    func addToGroupRecommendationsUseCoverNeighborsAsCandidateSource() throws {
        let context = try makeContext()
        var primary = sampleBook(
            title: "Original Edition",
            filepath: "/tmp/add-cover-primary.cbz",
            tags: #"["artist:maker"]"#
        )
        primary.category = "Doujinshi"
        var candidate = sampleBook(
            title: "Totally Renamed Translation",
            hash: "sha1-add-cover-candidate",
            filepath: "/tmp/add-cover-candidate.cbz",
            tags: #"["artist:maker","language:chinese"]"#
        )
        candidate.category = "Doujinshi"
        let savedPrimary = try context.books.insert(primary)
        let savedCandidate = try context.books.insert(candidate)
        let primaryID = try #require(savedPrimary.databaseID)
        let candidateID = try #require(savedCandidate.databaseID)
        let group = try context.versionGroups.insert(BookVersionGroup())
        var groupedPrimary = savedPrimary
        groupedPrimary.versionGroupID = group.databaseID
        groupedPrimary.isPrimaryVersion = true
        _ = try context.books.update(groupedPrimary)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            primaryID: [CoverVectorNeighbor(bookID: candidateID, distance: 0.1)],
            candidateID: [CoverVectorNeighbor(bookID: primaryID, distance: 0.1)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(
            kind: .addToGroup,
            targetVersionGroupID: group.databaseID
        )

        #expect(recommendations.count == 1)
        #expect(recommendations[0].reasons.contains("cover"))
    }

    @Test("numbered titles can match through cover similarity")
    func numberedTitlesCanMatchThroughCoverSimilarity() throws {
        let context = try makeContext()
        var first = sampleBook(
            title: "無口少女の痴漢被害7",
            filepath: "/tmp/cover-series-7.cbz",
            tags: #"["artist:maker","group:circle a","parody:source"]"#
        )
        first.category = "Doujinshi"
        var second = sampleBook(
            title: "無口少女の痴漢被害8",
            hash: "sha1-cover-series-8",
            filepath: "/tmp/cover-series-8.cbz",
            tags: #"["artist:maker","group:circle a","parody:source"]"#
        )
        second.category = "Doujinshi"
        let savedFirst = try context.books.insert(first)
        let savedSecond = try context.books.insert(second)
        let firstID = try #require(savedFirst.databaseID)
        let secondID = try #require(savedSecond.databaseID)
        let coverSearch = FakeCoverVectorSearch(neighbors: [
            firstID: [CoverVectorNeighbor(bookID: secondID, distance: 0.1)],
            secondID: [CoverVectorNeighbor(bookID: firstID, distance: 0.1)]
        ])
        let service = VersionRecommendationService(
            bookRepository: context.books,
            recommendationRepository: context.versionRecommendations,
            coverVectorSearch: coverSearch
        )

        try service.refreshRecommendations(useCoverSimilarity: true)
        let recommendations = try context.versionRecommendations.fetchPending(kind: .createGroup, targetVersionGroupID: nil)

        #expect(recommendations.count == 1)
        #expect(recommendations[0].reasons.contains("cover"))
    }

    @Test("migration backfills version labels and suggestions")
    func migrationBackfillsVersionLabelsAndSuggestions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("NyaEH.sqlite")

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.execute(sql: legacyV2SchemaSQL)
            try db.execute(
                sql: """
                    INSERT INTO grdb_migrations (identifier)
                    VALUES
                        ('v1_initial_library'),
                        ('v2_book_library_schema'),
                        ('v3_tag_indexing'),
                        ('v4_tag_translation_cache'),
                        ('v5_library_grouping')
                    """
            )
            // The fixture declares v5 as applied, so it must include its tables and columns.
            try db.execute(sql: "CREATE TABLE book_collections (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            try db.execute(sql: "CREATE TABLE book_version_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            try db.execute(sql: "ALTER TABLE library_books ADD COLUMN collection_id INTEGER")
            try db.execute(sql: "ALTER TABLE library_books ADD COLUMN collection_order INTEGER")
            try db.execute(sql: "ALTER TABLE library_books ADD COLUMN version_group_id INTEGER")
            try db.execute(sql: "ALTER TABLE library_books ADD COLUMN is_primary_version INTEGER NOT NULL DEFAULT 1")
            try db.execute(sql: "ALTER TABLE library_books ADD COLUMN version_label TEXT")
            try db.execute(
                sql: """
                    INSERT INTO library_books (
                        title, hash, filepath, type, status, date, tags, version_label,
                        exist, created_at, updated_at
                    ) VALUES
                        (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                        (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                        (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "A",
                    "hash-a",
                    "/tmp/a.zip",
                    BookType.archive.rawValue,
                    BookStatus.unscanned.rawValue,
                    1,
                    "[]",
                    "中文翻译版",
                    1,
                    1,
                    10,
                    "B",
                    "hash-b",
                    "/tmp/b.zip",
                    BookType.archive.rawValue,
                    BookStatus.unscanned.rawValue,
                    2,
                    "[]",
                    "中文翻译版",
                    1,
                    2,
                    20,
                    "C",
                    "hash-c",
                    "/tmp/c.zip",
                    BookType.archive.rawValue,
                    BookStatus.unscanned.rawValue,
                    3,
                    "[]",
                    "日文原版",
                    1,
                    3,
                    30
                ]
            )
        }

        let database = try DatabaseManager(path: databaseURL.path)
        let repository = SQLiteVersionLabelSuggestionRepository(dbQueue: database.dbQueue)
        let suggestions = try repository.fetchAll()

        #expect(suggestions.map(\.label) == ["中文翻译版", "日文原版"])
        #expect(suggestions.first?.usageCount == 2)

        let labelRows = try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT library_books.hash, book_version_labels.label
                    FROM library_books
                    JOIN book_version_labels ON book_version_labels.book_id = library_books.id
                    ORDER BY library_books.hash
                    """
            ).map { row in
                (hash: row["hash"] as String, label: row["label"] as String)
            }
        }
        #expect(labelRows.map { $0.hash } == ["hash-a", "hash-b", "hash-c"])
        #expect(labelRows.map { $0.label } == ["中文翻译版", "中文翻译版", "日文原版"])
    }

    @Test("home shelves use book semantics instead of collection display items")
    @MainActor
    func homeShelvesUseBookSemantics() throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/primary.cbz"))
        let secondary = try context.books.insert(sampleBook(title: "Secondary", filepath: "/tmp/secondary.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [primary])
        try service.addBook(secondary, toVersionGroup: group)
        let collection = try service.createCollection(name: "Series")
        let primaryID = try #require(primary.databaseID)
        let fetchedPrimary = try context.books.fetch(id: primaryID)
        let savedPrimary = try #require(fetchedPrimary)
        try service.addBook(savedPrimary, to: collection)
        _ = try service.setMarked(true, for: secondary)

        let store = CatalogStore(service: service)
        store.refresh()

        #expect(store.recommendedBooks.contains { $0.id == primary.id })
        #expect(!store.recommendedBooks.contains { $0.id == secondary.id })
        #expect(store.markedPreviewBooks.contains { $0.id == primary.id })
        #expect(!store.markedPreviewBooks.contains { $0.id == secondary.id })
        #expect(store.recentlyAddedBooks.contains { $0.id == primary.id })
        #expect(store.recentlyAddedBooks.contains { $0.id == secondary.id })
    }

    @Test("home shelves ignore library search cache")
    @MainActor
    func homeShelvesIgnoreLibrarySearchCache() throws {
        let context = try makeContext()
        let visible = try context.books.insert(sampleBook(title: "Visible", filepath: "/tmp/visible.cbz"))
        let favorite = try context.books.insert(sampleBook(title: "Favorite", hash: "sha1-favorite", filepath: "/tmp/favorite.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        _ = try service.setMarked(true, for: favorite)

        let store = CatalogStore(service: service)
        store.refresh()
        store.searchText = "no matches"

        #expect(store.displayItems.isEmpty)
        #expect(store.recommendedBooks.contains { $0.id == visible.id })
        #expect(store.markedPreviewBooks.contains { $0.id == favorite.id })
        #expect(store.recentlyAddedBooks.contains { $0.id == favorite.id })
        #expect(store.recentlyViewedBooks.isEmpty)
    }

    @Test("recently viewed home shelf orders by last read time")
    @MainActor
    func recentlyViewedHomeShelfOrdersByLastReadTime() throws {
        let context = try makeContext()
        var expectedIDs: [LibraryBook.ID] = []

        for index in 0..<12 {
            var book = sampleBook(
                title: "Viewed \(index)",
                hash: "sha1-viewed-\(index)",
                filepath: "/tmp/viewed-\(index).cbz"
            )
            book.lastReadAt = 1_775_657_600_000 + Int64(index)
            if index == 11 {
                book.hiddenBook = true
            }
            let saved = try context.books.insert(book)
            if !saved.hiddenBook {
                expectedIDs.insert(saved.id, at: 0)
            }
        }

        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags
        )
        let store = CatalogStore(service: service)
        store.refresh()

        #expect(store.recentlyViewedBooks.count == 10)
        #expect(store.recentlyViewedBooks.map(\.id) == Array(expectedIDs.prefix(10)))
    }

    @Test("library and filter caches update from search and filter")
    @MainActor
    func libraryAndFilterCachesUpdateFromSearchAndFilter() throws {
        let context = try makeContext()
        let alpha = try context.books.insert(sampleBook(title: "Alpha", filepath: "/tmp/alpha.cbz"))
        var beta = try context.books.insert(sampleBook(title: "Beta", hash: "sha1-beta", filepath: "/tmp/beta.cbz"))
        beta.mark = true
        _ = try context.books.update(beta)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags
        )
        let store = CatalogStore(service: service)
        store.refresh()

        #expect(store.displayItems.count == 2)
        #expect(store.filteredDisplayItems.count == 2)

        store.searchText = "Alpha"
        #expect(store.displayItems.map(\.representativeBook?.id).contains(alpha.id))
        #expect(store.displayItems.count == 1)

        store.searchText = ""
        store.filter = .marked
        #expect(store.filteredBooks.map(\.id) == [beta.id])
        #expect(store.filteredDisplayItems.map(\.representativeBook?.id) == [beta.id])
    }

    @Test("collection and version caches update after refresh")
    @MainActor
    func collectionAndVersionCachesUpdateAfterRefresh() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(title: "First", filepath: "/tmp/first.cbz"))
        let second = try context.books.insert(sampleBook(title: "Second", hash: "sha1-second", filepath: "/tmp/second.cbz"))
        let third = try context.books.insert(sampleBook(title: "Third", hash: "sha1-third", filepath: "/tmp/third.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let collection = try service.createCollection(name: "Series")
        try service.addBook(first, to: collection)
        let group = try service.createVersionGroup(with: [second])

        let store = CatalogStore(service: service)
        store.refresh()

        #expect(store.displayBooks(in: collection).map(\.id) == [first.id])
        #expect(store.books(inVersionGroup: group).map(\.id) == [second.id])
        #expect(store.collectionCandidateBooks(for: collection, query: "").map(\.id).contains(third.id))
        #expect(!store.collectionCandidateBooks(for: collection, query: "").map(\.id).contains(first.id))
        #expect(store.versionCandidateBooks(query: "").map(\.id).contains(third.id))
        #expect(!store.versionCandidateBooks(query: "").map(\.id).contains(second.id))

        store.addBook(third, to: collection)
        #expect(store.displayBooks(in: collection).map(\.id).contains(third.id))
        #expect(!store.collectionCandidateBooks(for: collection, query: "").map(\.id).contains(third.id))
        await store.waitForOrganizationMutations()
        store.removeBook(third, from: collection)
        #expect(store.collectionCandidateBooks(for: collection, query: "").map(\.id).contains(third.id))
        await store.waitForOrganizationMutations()
    }

    @Test("derived list caches handle larger libraries")
    @MainActor
    func derivedListCachesHandleLargerLibraries() throws {
        let context = try makeContext()
        for index in 0..<2_000 {
            var book = sampleBook(
                title: "Book \(index)",
                hash: "sha1-\(index)",
                filepath: "/tmp/book-\(index).cbz"
            )
            book.mark = index.isMultiple(of: 10)
            _ = try context.books.insert(book)
        }
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags
        )
        let store = CatalogStore(service: service)
        store.refresh()

        #expect(store.displayItems.count == 2_000)
        #expect(store.favoriteManagementBooks.count == 200)
        #expect(store.recommendedBooks.count == 10)
        #expect(store.recentlyAddedBooks.count == 10)
        #expect(store.recentlyViewedBooks.isEmpty)

        store.searchText = "Book 19"
        #expect(store.displayItems.count == 111)
        store.filter = .marked
        #expect(store.filteredBooks.allSatisfy { $0.mark })
    }

    @Test("collection companions exclude all books from the same version group")
    @MainActor
    func collectionCompanionsExcludeSameVersionGroup() throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/primary.cbz"))
        let secondary = try context.books.insert(sampleBook(title: "Secondary", filepath: "/tmp/secondary.cbz"))
        let other = try context.books.insert(sampleBook(title: "Other", filepath: "/tmp/other.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [primary])
        try service.addBook(secondary, toVersionGroup: group)
        let collection = try service.createCollection(name: "Series")
        let primaryID = try #require(primary.databaseID)
        let fetchedPrimary = try context.books.fetch(id: primaryID)
        let savedPrimary = try #require(fetchedPrimary)
        try service.addBook(savedPrimary, to: collection)
        try service.addBook(other, to: collection)

        let store = CatalogStore(service: service)
        store.refresh()
        let savedSecondary = try #require(store.book(id: secondary.id))
        let companions = store.collectionCompanions(for: savedSecondary)

        #expect(companions.map(\.id) == [other.id])
    }

    @Test("detail collection related books include current and exclude sibling versions")
    @MainActor
    func detailCollectionRelatedBooksIncludeCurrentAndExcludeSiblingVersions() throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/detail-primary.cbz"))
        let secondary = try context.books.insert(sampleBook(title: "Secondary", filepath: "/tmp/detail-secondary.cbz"))
        let other = try context.books.insert(sampleBook(title: "Other", filepath: "/tmp/detail-other.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [primary])
        try service.addBook(secondary, toVersionGroup: group)
        let collection = try service.createCollection(name: "Series")
        let primaryID = try #require(primary.databaseID)
        let fetchedPrimary = try context.books.fetch(id: primaryID)
        let savedPrimary = try #require(fetchedPrimary)
        try service.addBook(savedPrimary, to: collection)
        try service.addBook(other, to: collection)

        let store = CatalogStore(service: service)
        store.refresh()
        let savedSecondary = try #require(store.book(id: secondary.id))
        let relatedBooks = store.detailCollectionRelatedBooks(for: savedSecondary)

        #expect(relatedBooks.map(\.id) == [secondary.id, other.id])
    }

    @Test("detail version related books include current and sibling versions")
    @MainActor
    func detailVersionRelatedBooksIncludeCurrentAndSiblingVersions() throws {
        let context = try makeContext()
        let primary = try context.books.insert(sampleBook(title: "Primary", filepath: "/tmp/version-primary.cbz"))
        let secondary = try context.books.insert(sampleBook(title: "Secondary", filepath: "/tmp/version-secondary.cbz"))
        let standalone = try context.books.insert(sampleBook(title: "Standalone", filepath: "/tmp/version-standalone.cbz"))
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            versionGroupRepository: context.versionGroups
        )
        let group = try service.createVersionGroup(with: [primary])
        try service.addBook(secondary, toVersionGroup: group)

        let store = CatalogStore(service: service)
        store.refresh()
        let savedSecondary = try #require(store.book(id: secondary.id))
        let relatedIDs = Set(store.detailVersionRelatedBooks(for: savedSecondary).map(\.id))
        let standaloneBook = try #require(store.book(id: standalone.id))

        #expect(relatedIDs == Set([primary.id, secondary.id]))
        #expect(store.detailVersionRelatedBooks(for: standaloneBook).isEmpty)
    }

    @Test("connects library books to metadata by hash")
    func connectsLibraryBooksToMetadataByHash() throws {
        let context = try makeContext()
        _ = try context.books.insert(sampleBook(hash: "same-hash"))
        _ = try context.metadata.upsert(GalleryMetadata(hash: "same-hash", title: "Metadata"))

        let books = try context.books.fetchByHash("same-hash")
        let metadata = try context.metadata.fetch(hash: "same-hash")

        #expect(books.count == 1)
        #expect(metadata?.title == "Metadata")
    }

    @Test("parses tag json into normalized tags")
    func parsesTagJSONIntoNormalizedTags() {
        let tags = TagParser.parseJSON(
            #"["language:chinese","parody:love live","uncategorized tag","language:translated"]"#
        )

        #expect(tags.map(\.rawValue) == [
            "language:chinese",
            "parody:love live",
            "other:uncategorized tag",
            "language:translated"
        ])
    }

    @Test("derives quick filter fields from tags")
    func derivesQuickFilterFieldsFromTags() {
        let tags = TagParser.parseJSON(
            #"["language:chinese","language:translated","other:full color","other:mosaic censorship","other:uncensored","other:extraneous ads"]"#
        )

        let state = TagParser.derivedState(from: tags)

        #expect(state.languageCode == "chinese")
        #expect(state.isTranslated)
        #expect(state.isFullColor)
        #expect(state.censorship == "uncensored")
        #expect(state.hasExtraneousAds)
    }

    @Test("rebuilds book tags and derived fields")
    func rebuildsBookTagsAndDerivedFields() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)

        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["language:chinese","language:translated","parody:love live","other:full color","other:full censored","other:extraneous ads"]"#
        )

        let fetchedBook = try context.books.fetch(id: bookID)
        let updated = try #require(fetchedBook)
        let summaries = try context.tags.summaries(namespace: nil)
        let parodyBookIDs = try context.tags.bookIDs(namespace: "parody", name: "love live")

        #expect(updated.languageCode == "chinese")
        #expect(updated.isTranslated)
        #expect(updated.isFullColor)
        #expect(updated.censorship == "full censored")
        #expect(updated.hasExtraneousAds)
        #expect(summaries.count == 6)
        #expect(summaries.allSatisfy { $0.id > 0 })
        #expect(parodyBookIDs == [bookID])
    }

    @Test("stores followed tags without changing tag index")
    func storesFollowedTagsWithoutChangingTagIndex() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(tags: #"["artist:sample","female:schoolgirl"]"#))
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(forBookID: bookID, tagsJSON: book.tags)
        let artist = try #require(try context.tags.summaries(namespace: "artist").first)

        try context.tags.setFollowed(tagID: artist.id, isFollowed: true)

        #expect(try context.tags.followedTagIDs() == Set([artist.id]))
        let followedSummary = try #require(try context.tags.summaries(namespace: "artist").first)
        let unrelatedSummary = try #require(try context.tags.summaries(namespace: "female").first)
        #expect(followedSummary.isFollowed)
        #expect(!unrelatedSummary.isFollowed)
        #expect(try context.tags.indexedBookTagCount() == 2)

        try context.tags.setFollowed(tagID: artist.id, isFollowed: false)
        #expect(try context.tags.followedTagIDs().isEmpty)
    }

    @Test("rebuilding book tags replaces old links without duplicating tags")
    func rebuildingBookTagsReplacesOldLinksWithoutDuplicatingTags() throws {
        let context = try makeContext()
        let firstBook = try context.books.insert(sampleBook())
        let secondBook = try context.books.insert(sampleBook(title: "Second", hash: "sha1-second", filepath: "/tmp/second.cbz"))
        let firstID = try #require(firstBook.databaseID)
        let secondID = try #require(secondBook.databaseID)

        try context.tags.rebuildTags(forBookID: firstID, tagsJSON: #"["artist:sample","language:chinese"]"#)
        try context.tags.rebuildTags(forBookID: secondID, tagsJSON: #"["artist:sample"]"#)
        try context.tags.rebuildTags(forBookID: firstID, tagsJSON: #"["group:kaitsushin"]"#)

        let artistSummary = try context.tags.summaries(namespace: "artist")
        let groupSummary = try context.tags.summaries(namespace: "group")
        let artistBookIDs = try context.tags.bookIDs(namespace: "artist", name: "sample")

        #expect(artistSummary.count == 1)
        #expect(artistSummary[0].id > 0)
        #expect(artistSummary[0].count == 1)
        #expect(groupSummary.count == 1)
        #expect(groupSummary[0].count == 1)
        #expect(artistBookIDs == [secondID])
    }

    @Test("rebuilds all book tags from existing library metadata")
    func rebuildsAllBookTagsFromExistingLibraryMetadata() throws {
        let context = try makeContext()
        var first = sampleBook()
        first.tags = #"["artist:sample","parody:love live","character:honoka"]"#
        var second = sampleBook(title: "Second", hash: "sha1-second", filepath: "/tmp/second.cbz")
        second.tags = #"["artist:sample","parody:love live"]"#
        let firstBook = try context.books.insert(first)
        let secondBook = try context.books.insert(second)

        try context.tags.rebuildAllTags(from: [firstBook, secondBook])

        let artist = try context.tags.summaries(namespace: "artist")
        let parody = try context.tags.summaries(namespace: "parody")
        let character = try context.tags.summaries(namespace: "character")

        #expect(try context.tags.indexedBookTagCount() == 5)
        #expect(artist.map(\.name) == ["sample"])
        #expect(artist.map(\.count) == [2])
        #expect(parody.map(\.name) == ["love live"])
        #expect(parody.map(\.count) == [2])
        #expect(character.map(\.name) == ["honoka"])
    }

    @Test("loads top tag summaries across multiple namespaces")
    func loadsTopTagSummariesAcrossMultipleNamespaces() throws {
        let context = try makeContext()
        let first = try context.books.insert(
            sampleBook(tags: #"["artist:alpha","parody:solar","female:magic"]"#)
        )
        let second = try context.books.insert(
            sampleBook(
                title: "Second",
                hash: "sha1-second",
                filepath: "/tmp/second.cbz",
                tags: #"["artist:alpha","group:circle","character:luna","female:magic","male:glasses"]"#
            )
        )
        let third = try context.books.insert(
            sampleBook(
                title: "Third",
                hash: "sha1-third",
                filepath: "/tmp/third.cbz",
                tags: #"["artist:beta","parody:solar","female:magic","male:glasses"]"#
            )
        )
        try context.tags.rebuildAllTags(from: [first, second, third])
        let solar = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:solar" })
        try context.tags.upsertTranslation(
            tagID: try #require(solar.id),
            languageCode: EhTagTranslationCache.languageCode,
            translatedName: "太阳"
        )

        let works = try context.tags.topSummaries(
            namespaces: ["parody", "character"],
            limit: 2,
            languageCode: EhTagTranslationCache.languageCode
        )
        let authors = try context.tags.topSummaries(
            namespaces: ["artist", "group"],
            limit: 2,
            languageCode: nil
        )
        let empty = try context.tags.topSummaries(
            namespaces: ["artist"],
            limit: 0,
            languageCode: nil
        )

        #expect(works.map(\.rawValue) == ["parody:solar", "character:luna"])
        #expect(works.map(\.count) == [2, 1])
        #expect(works.first?.translatedName == "太阳")
        #expect(authors.map(\.rawValue) == ["artist:alpha", "artist:beta"])
        #expect(authors.map(\.count) == [2, 1])
        #expect(empty.isEmpty)
    }

    @MainActor
    @Test("store loads home insight charts")
    func storeLoadsHomeInsightCharts() throws {
        let context = try makeContext()
        var books: [LibraryBook] = []
        let first = sampleBook(tags: #"["artist:alpha","parody:solar","female:magic","language:chinese"]"#)
        books.append(try context.books.insert(first))
        let second = sampleBook(
            title: "Second",
            hash: "sha1-second",
            filepath: "/tmp/second.cbz",
            tags: #"["artist:alpha","group:circle","character:luna","female:magic","male:glasses","language:japanese"]"#
        )
        books.append(try context.books.insert(second))
        for index in 0..<25 {
            books.append(
                try context.books.insert(
                    sampleBook(
                        title: "Extra \(index)",
                        hash: "sha1-extra-\(index)",
                        filepath: "/tmp/extra-\(index).cbz",
                        tags: #"["female:extra-\#(index)"]"#
                    )
                )
            )
        }
        try context.tags.rebuildAllTags(from: books)
        let magic = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "female:magic" })
        try context.tags.upsertTranslation(
            tagID: try #require(magic.id),
            languageCode: EhTagTranslationCache.languageCode,
            translatedName: "魔法"
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags,
                tagVisualProfileRepository: context.visualProfiles
            )
        )

        store.refresh()
        store.loadHomeInsightCharts(isTagTranslationEnabled: false)

        #expect(store.homeInsightCharts.works.map(\.rawValue) == ["parody:solar"])
        #expect(store.homeInsightCharts.characters.map(\.rawValue) == ["character:luna"])
        #expect(store.homeInsightCharts.authors.first?.rawValue == "artist:alpha")
        #expect(store.homeInsightCharts.groups.map(\.rawValue) == ["group:circle"])
        #expect(store.homeInsightCharts.tags.first?.rawValue == "female:magic")
        #expect(store.homeInsightCharts.tags.count == 20)
        #expect(store.homeInsightCharts.languages.map(\.rawValue) == ["language:chinese", "language:japanese"])
        #expect(store.homeInsightChartError == nil)

        store.loadHomeInsightCharts(isTagTranslationEnabled: true)

        #expect(store.homeInsightCharts.tags.first?.displayName == "魔法")
    }

    @Test("home insight chart scale compresses long tail values")
    func homeInsightChartScaleCompressesLongTailValues() {
        let maxValue = HomeInsightChartScale.sqrtFraction(count: 625, maxCount: 625)
        let tailValue = HomeInsightChartScale.sqrtFraction(count: 100, maxCount: 625)
        let zeroValue = HomeInsightChartScale.sqrtFraction(count: 0, maxCount: 625)

        #expect(maxValue == 1)
        #expect(tailValue > Double(100) / Double(625))
        #expect(tailValue <= 1)
        #expect(zeroValue == 0)
        #expect(HomeInsightChartScale.sqrtFraction(count: 5, maxCount: 0) == 0)
    }

    @Test("creates work character index tables")
    func createsWorkCharacterIndexTables() throws {
        let context = try makeContext()

        let tableNames = try context.database.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table'
                      AND name IN ('book_work_character_links', 'work_character_index_state')
                    ORDER BY name
                    """
            )
        }

        #expect(tableNames == ["book_work_character_links", "work_character_index_state"])
    }

    @Test("creates durable work-character decisions and book-scoped suppression tables")
    func createsWorkCharacterClaimTables() throws {
        let context = try makeContext()
        let tables = try context.database.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name IN ('work_character_decisions', 'book_work_character_suppressions')
                ORDER BY name
                """)
        }
        #expect(tables == ["book_work_character_suppressions", "work_character_decisions"])
    }

    @Test("v21 claim migration upgrades a v20 database without rebuilding the existing index")
    func upgradesWorkCharacterClaimSchema() throws {
        let database = try DatabaseQueue()
        try DatabaseMigrator.nyaeh.migrate(database, upTo: "v20_deletion_consistency")
        let oldIndexExists = try database.read { db in try db.tableExists("book_work_character_links") }
        #expect(oldIndexExists)
        try DatabaseMigrator.nyaeh.migrate(database)
        let tables = try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                  AND name IN ('book_work_character_links', 'work_character_decisions', 'book_work_character_suppressions')
                ORDER BY name
                """)
        }
        #expect(tables == ["book_work_character_links", "book_work_character_suppressions", "work_character_decisions"])
    }

    @Test("indexes only books with one non-origin parody and characters")
    func indexesOnlyBooksWithOneNonOriginParodyAndCharacters() throws {
        let context = try makeContext()
        let eligible = try insertBook(
            context,
            title: "Eligible",
            hash: "sha1-eligible",
            filepath: "/tmp/eligible.cbz",
            tags: #"["parody:love live","character:honoka","character:kotori","character:honoka"]"#
        )
        _ = try insertBook(
            context,
            title: "Origin",
            hash: "sha1-origin",
            filepath: "/tmp/origin.cbz",
            tags: #"["parody:origin","character:someone"]"#
        )
        _ = try insertBook(
            context,
            title: "Multiple Parodies",
            hash: "sha1-multiple",
            filepath: "/tmp/multiple.cbz",
            tags: #"["parody:love live","parody:touhou project","character:reimu"]"#
        )
        _ = try insertBook(
            context,
            title: "No Character",
            hash: "sha1-no-character",
            filepath: "/tmp/no-character.cbz",
            tags: #"["parody:love live"]"#
        )

        let result = try context.workCharacters.rebuildIndex()
        let works = try context.workCharacters.fetchWorks(languageCode: nil)
        let work = try #require(works.first)
        let characters = try context.workCharacters.fetchCharacters(parodyTagID: work.tag.id, languageCode: nil)

        #expect(result.didChange)
        #expect(result.linkCount == 2)
        #expect(works.map(\.tag.name) == ["love live"])
        #expect(work.characterCount == 2)
        #expect(work.bookCount == 1)
        #expect(characters.map(\.tag.name).sorted() == ["honoka", "kotori"])
        #expect(characters.allSatisfy { $0.bookCount == 1 })
        #expect(eligible.databaseID != nil)
    }

    @Test("incremental work character index replaces changed book links")
    func incrementalWorkCharacterIndexReplacesChangedBookLinks() throws {
        let context = try makeContext()
        let book = try insertBook(
            context,
            title: "Changing",
            hash: "sha1-changing",
            filepath: "/tmp/changing.cbz",
            tags: #"["parody:love live","character:honoka"]"#
        )
        let bookID = try #require(book.databaseID)

        _ = try context.workCharacters.rebuildIndex()
        #expect(try context.workCharacters.fetchWorks(languageCode: nil).map(\.tag.name) == ["love live"])

        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["parody:touhou project","character:reimu"]"#
        )
        try bumpUpdatedAt(context, bookID: bookID, updatedAt: 9_000_000_000_000)

        let changed = try context.workCharacters.updateIndexIncrementally()
        let changedWorks = try context.workCharacters.fetchWorks(languageCode: nil)
        let changedWork = try #require(changedWorks.first)
        let changedCharacters = try context.workCharacters.fetchCharacters(parodyTagID: changedWork.tag.id, languageCode: nil)

        #expect(changed.processedBooks == 1)
        #expect(changed.linkCount == 1)
        #expect(changedWorks.map(\.tag.name) == ["touhou project"])
        #expect(changedCharacters.map(\.tag.name) == ["reimu"])

        try context.tags.rebuildTags(forBookID: bookID, tagsJSON: "[]")
        try bumpUpdatedAt(context, bookID: bookID, updatedAt: 9_100_000_000_000)

        let cleared = try context.workCharacters.updateIndexIncrementally()

        #expect(cleared.processedBooks == 1)
        #expect(cleared.linkCount == 0)
        #expect(try context.workCharacters.fetchWorks(languageCode: nil).isEmpty)
        #expect(!(try context.workCharacters.hasIncrementalChanges()))
    }

    @Test("work detail uses work character index as character whitelist")
    func workDetailUsesWorkCharacterIndexAsCharacterWhitelist() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Love Live Evidence",
            hash: "work-detail-love-live-evidence",
            filepath: "/tmp/work-detail-love-live-evidence.cbz",
            tags: #"["parody:love live","character:honoka"]"#
        )
        _ = try insertBook(
            context,
            title: "Konosuba Evidence",
            hash: "work-detail-konosuba-evidence",
            filepath: "/tmp/work-detail-konosuba-evidence.cbz",
            tags: #"["parody:konosuba","character:megumi"]"#
        )
        _ = try insertBook(
            context,
            title: "Crossover",
            hash: "work-detail-multi-work",
            filepath: "/tmp/work-detail-multi-work.cbz",
            tags: #"["parody:love live","parody:konosuba","character:honoka","character:megumi"]"#
        )
        _ = try insertBook(
            context,
            title: "No Character",
            hash: "work-detail-no-character",
            filepath: "/tmp/work-detail-no-character.cbz",
            tags: #"["parody:love live"]"#
        )
        _ = try context.workCharacters.rebuildIndex()
        _ = try insertBook(
            context,
            title: "Love Unknown",
            hash: "work-detail-love-unknown",
            filepath: "/tmp/work-detail-love-unknown.cbz",
            tags: #"["parody:love live","character:unknown visitor"]"#
        )

        let loveLive = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:love live" })
        let konosuba = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:konosuba" })
        let loveLiveID = try #require(loveLive.id)
        let konosubaID = try #require(konosuba.id)

        let loveLiveDetail = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: loveLiveID, languageCode: nil))
        let loveLiveSections = Dictionary(
            uniqueKeysWithValues: loveLiveDetail.sections.compactMap { section -> (String, WorkCharacterBookSection)? in
                guard let name = section.character?.name else {
                    return nil
                }
                return (name, section)
            }
        )
        let loveLiveUnmatched = try #require(loveLiveDetail.sections.first { $0.character == nil })
        let konosubaDetail = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: konosubaID, languageCode: nil))
        let konosubaSections = Dictionary(
            uniqueKeysWithValues: konosubaDetail.sections.compactMap { section -> (String, WorkCharacterBookSection)? in
                guard let name = section.character?.name else {
                    return nil
                }
                return (name, section)
            }
        )

        #expect(loveLiveDetail.work.name == "love live")
        #expect(loveLiveDetail.hasCharacterIndexRelations)
        #expect(loveLiveDetail.characterCount == 1)
        #expect(loveLiveSections["honoka"]?.books.map(\.title).sorted() == ["Crossover", "Love Live Evidence"])
        #expect(loveLiveSections["megumi"] == nil)
        #expect(loveLiveUnmatched.books.map(\.title).sorted() == ["Love Unknown", "No Character"])

        #expect(konosubaDetail.hasCharacterIndexRelations)
        #expect(konosubaDetail.characterCount == 1)
        #expect(konosubaSections["megumi"]?.books.map(\.title).sorted() == ["Crossover", "Konosuba Evidence"])
        #expect(konosubaSections["honoka"] == nil)
    }

    @Test("work detail keeps books unclassified without index relations")
    func workDetailDoesNotInferCharactersWithoutIndexRelations() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Unindexed Work",
            hash: "work-detail-unindexed",
            filepath: "/tmp/work-detail-unindexed.cbz",
            tags: #"["parody:unindexed work","character:someone"]"#
        )
        let unindexedWork = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:unindexed work" })
        let unindexedWorkID = try #require(unindexedWork.id)

        let detail = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: unindexedWorkID, languageCode: nil))

        #expect(!detail.hasCharacterIndexRelations)
        #expect(detail.sections.count == 1)
        #expect(detail.sections[0].character == nil)
        #expect(detail.sections[0].books.map(\.title) == ["Unindexed Work"])
        #expect(detail.totalBookCount == 1)
    }

    @Test("multi-work books remain visible and a unique remainder is automatically claimed")
    func workCharacterClaimsFromReliableRemainder() throws {
        let context = try makeContext()
        _ = try insertBook(context, title: "Seed", hash: "claim-seed", filepath: "/tmp/claim-seed.cbz",
                           tags: #"["parody:work a","character:person a"]"#)
        let crossover = try insertBook(context, title: "Crossover", hash: "claim-crossover", filepath: "/tmp/claim-crossover.cbz",
                                       tags: #"["parody:work a","parody:work b","character:person a","character:person b"]"#)
        _ = try insertBook(context, title: "No Character", hash: "claim-no-character", filepath: "/tmp/claim-no-character.cbz",
                                         tags: #"["parody:work b","parody:work c"]"#)
        _ = try context.workCharacters.rebuildIndex()
        let tags = try context.tags.fetchAllTags()
        let workA = try #require(tags.first { $0.rawValue == "parody:work a" }?.id)
        let workB = try #require(tags.first { $0.rawValue == "parody:work b" }?.id)
        let workC = try #require(tags.first { $0.rawValue == "parody:work c" }?.id)
        let personB = try #require(tags.first { $0.rawValue == "character:person b" }?.id)
        let crossoverID = try #require(crossover.databaseID)

        let detailA = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workA, languageCode: nil))
        let detailB = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workB, languageCode: nil))
        let inferred = try #require(detailB.sections.first { $0.character?.id == personB })
        let unclassified = try #require(detailB.sections.first { $0.character == nil })
        #expect(detailA.totalBookCount == 2)
        #expect(detailB.totalBookCount == 2)
        #expect(inferred.books.map(\.title) == ["Crossover"])
        #expect(inferred.claimsByBookID[crossoverID]?.source == .automatic)
        #expect(unclassified.books.map(\.title) == ["No Character"])
        let detailC = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workC, languageCode: nil))
        #expect(detailC.totalBookCount == 1)
        #expect(detailC.sections.first?.character == nil)

        let characterDetail = try #require(try context.workDetails.fetchCharacterDetail(characterTagID: personB, languageCode: nil))
        #expect(characterDetail.sections.first { $0.work?.id == workB }?.claimsByBookID[crossoverID]?.source == .automatic)

        let pair = WorkCharacterPair(workID: workB, characterID: personB)
        try context.workDetails.setAutomaticClaimSuppressed(true, bookID: crossoverID, pair: pair)
        _ = try context.workCharacters.rebuildIndex()
        let suppressed = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workB, languageCode: nil))
        #expect(suppressed.sections.first { $0.character?.id == personB } == nil)
        #expect(suppressed.sections.first { $0.character == nil }?.books.map(\.title).sorted() == ["Crossover", "No Character"])

        try context.workDetails.setWorkCharacterDecision(.confirmed, pair: pair)
        let confirmed = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workB, languageCode: nil))
        #expect(confirmed.sections.first { $0.character?.id == personB }?.claimsByBookID[crossoverID]?.source == .manual)
    }

    @Test("manual work-character decisions survive index rebuild and override indexed evidence")
    func manualWorkCharacterDecisionsSurviveRebuild() throws {
        let context = try makeContext()
        let book = try insertBook(context, title: "Direct", hash: "claim-direct", filepath: "/tmp/claim-direct.cbz",
                                  tags: #"["parody:work a","character:person a"]"#)
        _ = try context.workCharacters.rebuildIndex()
        let tags = try context.tags.fetchAllTags()
        let workID = try #require(tags.first { $0.rawValue == "parody:work a" }?.id)
        let characterID = try #require(tags.first { $0.rawValue == "character:person a" }?.id)
        let pair = WorkCharacterPair(workID: workID, characterID: characterID)
        try context.workDetails.setWorkCharacterDecision(.excluded, pair: pair)
        _ = try context.workCharacters.rebuildIndex()
        let excluded = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workID, languageCode: nil))
        #expect(excluded.sections.first { $0.character != nil } == nil)
        #expect(excluded.sections.first { $0.character == nil }?.books.map(\.title) == ["Direct"])
        try context.workDetails.setWorkCharacterDecision(nil, pair: pair)
        let restored = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workID, languageCode: nil))
        let bookID = try #require(book.databaseID)
        #expect(restored.sections.first { $0.character?.id == characterID }?.claimsByBookID[bookID]?.source == .indexed)
    }

    @Test("automatic claims disappear when their sole indexed evidence is removed")
    func automaticClaimTracksSourceDeletion() throws {
        let context = try makeContext()
        let seed = try insertBook(context, title: "Seed", hash: "claim-remove-seed", filepath: "/tmp/claim-remove-seed.cbz",
                                  tags: #"["parody:work a","character:person a"]"#)
        _ = try insertBook(context, title: "Cross", hash: "claim-remove-cross", filepath: "/tmp/claim-remove-cross.cbz",
                           tags: #"["parody:work a","parody:work b","character:person a","character:person b"]"#)
        _ = try context.workCharacters.rebuildIndex()
        let tags = try context.tags.fetchAllTags()
        let workB = try #require(tags.first { $0.rawValue == "parody:work b" }?.id)
        let personB = try #require(tags.first { $0.rawValue == "character:person b" }?.id)
        #expect(try context.workDetails.fetchWorkDetail(parodyTagID: workB, languageCode: nil)?
            .sections.first { $0.character?.id == personB } != nil)

        let seedID = try #require(seed.databaseID)
        try context.database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM library_books WHERE id = ?", arguments: [seedID])
        }
        let afterDeletion = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workB, languageCode: nil))
        #expect(afterDeletion.sections.first { $0.character?.id == personB } == nil)
        #expect(afterDeletion.sections.first { $0.character == nil }?.books.map(\.title) == ["Cross"])
    }

    @Test("changing a seed book's character tag retracts its dependent automatic claim")
    func automaticClaimTracksMetadataChange() throws {
        let context = try makeContext()
        let seed = try insertBook(context, title: "Seed", hash: "claim-edit-seed", filepath: "/tmp/claim-edit-seed.cbz",
                                  tags: #"["parody:work a","character:person a"]"#)
        _ = try insertBook(context, title: "Cross", hash: "claim-edit-cross", filepath: "/tmp/claim-edit-cross.cbz",
                           tags: #"["parody:work a","parody:work b","character:person a","character:person b"]"#)
        _ = try context.workCharacters.rebuildIndex()
        let tags = try context.tags.fetchAllTags()
        let workB = try #require(tags.first { $0.rawValue == "parody:work b" }?.id)
        let personB = try #require(tags.first { $0.rawValue == "character:person b" }?.id)
        #expect(try context.workDetails.fetchWorkDetail(parodyTagID: workB, languageCode: nil)?
            .sections.first { $0.character?.id == personB } != nil)

        let seedID = try #require(seed.databaseID)
        try context.tags.rebuildTags(forBookID: seedID, tagsJSON: #"["parody:work a","character:person c"]"#)
        try bumpUpdatedAt(context, bookID: seedID, updatedAt: 9_500_000_000_000)
        _ = try context.workCharacters.updateIndexIncrementally()
        let updated = try #require(try context.workDetails.fetchWorkDetail(parodyTagID: workB, languageCode: nil))
        #expect(updated.sections.first { $0.character?.id == personB } == nil)
        #expect(updated.sections.first { $0.character == nil }?.books.map(\.title) == ["Cross"])
    }

    @Test("character detail groups books by indexed work and keeps ungrouped fallback")
    func characterDetailGroupsBooksByIndexedWorkAndKeepsUngroupedFallback() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Honoka Love",
            hash: "character-detail-honoka-love",
            filepath: "/tmp/character-detail-honoka-love.cbz",
            tags: #"["parody:love live","character:honoka"]"#
        )
        _ = try insertBook(
            context,
            title: "Honoka Idol",
            hash: "character-detail-honoka-idol",
            filepath: "/tmp/character-detail-honoka-idol.cbz",
            tags: #"["parody:idol master","character:honoka"]"#
        )
        _ = try insertBook(
            context,
            title: "Honoka Crossover",
            hash: "character-detail-honoka-crossover",
            filepath: "/tmp/character-detail-honoka-crossover.cbz",
            tags: #"["parody:love live","parody:idol master","character:honoka"]"#
        )
        _ = try context.workCharacters.rebuildIndex()

        let honoka = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "character:honoka" })
        let loveLive = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:love live" })
        let honokaID = try #require(honoka.id)
        let loveLiveID = try #require(loveLive.id)
        _ = try context.visualProfiles.upsert(
            TagVisualProfile(
                tagID: honokaID,
                foregroundAssetPath: "TagAssets/character/honoka-\(honokaID)/show.png",
                backgroundAssetPath: "TagAssets/character/honoka-\(honokaID)/bg.jpg"
            )
        )
        _ = try context.visualProfiles.upsert(
            TagVisualProfile(
                tagID: loveLiveID,
                foregroundAssetPath: "TagAssets/parody/love-live-\(loveLiveID)/show.png",
                backgroundAssetPath: "TagAssets/parody/love-live-\(loveLiveID)/bg.jpg"
            )
        )

        let detail = try #require(try context.workDetails.fetchCharacterDetail(characterTagID: honokaID, languageCode: nil))
        let sections = Dictionary(
            uniqueKeysWithValues: detail.sections.compactMap { section -> (String, CharacterWorkBookSection)? in
                guard let name = section.work?.name else {
                    return nil
                }
                return (name, section)
            }
        )
        let ungrouped = try #require(detail.sections.first { $0.work == nil })

        #expect(detail.character.name == "honoka")
        #expect(detail.character.visualProfile?.foregroundAssetPath == "TagAssets/character/honoka-\(honokaID)/show.png")
        #expect(detail.workCount == 2)
        #expect(detail.totalBookCount == 3)
        #expect(sections["love live"]?.books.map(\.title) == ["Honoka Love"])
        #expect(sections["love live"]?.work?.visualProfile?.backgroundAssetPath == "TagAssets/parody/love-live-\(loveLiveID)/bg.jpg")
        #expect(sections["idol master"]?.books.map(\.title) == ["Honoka Idol"])
        #expect(ungrouped.books.map(\.title) == ["Honoka Crossover"])
    }

    @MainActor
    @Test("store reuses work detail cache for matching translation state")
    func storeReusesWorkDetailCacheForMatchingTranslationState() async throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Cached Work",
            hash: "work-detail-cache-same-state",
            filepath: "/tmp/work-detail-cache-same-state.cbz",
            tags: #"["parody:cached work","character:someone"]"#
        )
        let work = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:cached work" })
        let workID = try #require(work.id)
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags,
                workDetailRepository: context.workDetails
            )
        )

        store.reloadWorkDetail(tagID: workID, isTagTranslationEnabled: false)
        await store.waitForWorkDetailLoad(tagID: workID)
        let firstRevision = store.workDetailRevision
        store.reloadWorkDetail(tagID: workID, isTagTranslationEnabled: false)
        await store.waitForWorkDetailLoad(tagID: workID)

        #expect(store.workDetail(tagID: workID) != nil)
        #expect(store.workDetailRevision == firstRevision)
        #expect(store.workDetailTranslationStates[workID] == false)
    }

    @MainActor
    @Test("store refreshes work detail cache when translation state changes")
    func storeRefreshesWorkDetailCacheWhenTranslationStateChanges() async throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Translated Work",
            hash: "work-detail-cache-translation-state",
            filepath: "/tmp/work-detail-cache-translation-state.cbz",
            tags: #"["parody:translated work","character:someone"]"#
        )
        let work = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:translated work" })
        let workID = try #require(work.id)
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags,
                workDetailRepository: context.workDetails
            )
        )

        store.reloadWorkDetail(tagID: workID, isTagTranslationEnabled: false)
        await store.waitForWorkDetailLoad(tagID: workID)
        let firstRevision = store.workDetailRevision
        store.reloadWorkDetail(tagID: workID, isTagTranslationEnabled: true)
        await store.waitForWorkDetailLoad(tagID: workID)

        #expect(store.workDetail(tagID: workID) != nil)
        #expect(store.workDetailRevision == firstRevision + 1)
        #expect(store.workDetailTranslationStates[workID] == true)
    }

    @MainActor
    @Test("store reuses character detail cache for matching translation state")
    func storeReusesCharacterDetailCacheForMatchingTranslationState() async throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Cached Character",
            hash: "character-detail-cache-same-state",
            filepath: "/tmp/character-detail-cache-same-state.cbz",
            tags: #"["parody:cached work","character:cached character"]"#
        )
        let character = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "character:cached character" })
        let characterID = try #require(character.id)
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags,
                workDetailRepository: context.workDetails
            )
        )

        store.reloadCharacterDetail(tagID: characterID, isTagTranslationEnabled: false)
        await store.waitForCharacterDetailLoad(tagID: characterID)
        let firstRevision = store.characterDetailRevision
        store.reloadCharacterDetail(tagID: characterID, isTagTranslationEnabled: false)
        await store.waitForCharacterDetailLoad(tagID: characterID)

        #expect(store.characterDetail(tagID: characterID) != nil)
        #expect(store.characterDetailRevision == firstRevision)
        #expect(store.characterDetailTranslationStates[characterID] == false)
    }

    @MainActor
    @Test("store refreshes character detail cache when translation state changes")
    func storeRefreshesCharacterDetailCacheWhenTranslationStateChanges() async throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Translated Character",
            hash: "character-detail-cache-translation-state",
            filepath: "/tmp/character-detail-cache-translation-state.cbz",
            tags: #"["parody:translated work","character:translated character"]"#
        )
        let character = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "character:translated character" })
        let characterID = try #require(character.id)
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags,
                workDetailRepository: context.workDetails
            )
        )

        store.reloadCharacterDetail(tagID: characterID, isTagTranslationEnabled: false)
        await store.waitForCharacterDetailLoad(tagID: characterID)
        let firstRevision = store.characterDetailRevision
        store.reloadCharacterDetail(tagID: characterID, isTagTranslationEnabled: true)
        await store.waitForCharacterDetailLoad(tagID: characterID)

        #expect(store.characterDetail(tagID: characterID) != nil)
        #expect(store.characterDetailRevision == firstRevision + 1)
        #expect(store.characterDetailTranslationStates[characterID] == true)
    }

    @Test("library service repairs missing tag index from books")
    func libraryServiceRepairsMissingTagIndexFromBooks() throws {
        let context = try makeContext()
        var book = sampleBook()
        book.tags = #"["parody:love live","character:honoka"]"#
        let savedBook = try context.books.insert(book)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags
        )

        #expect(try context.tags.indexedBookTagCount() == 0)
        #expect(try service.ensureTagIndex(for: [savedBook]))
        #expect(try context.tags.summaries(namespace: "parody").map(\.name) == ["love live"])
        #expect(!(try service.ensureTagIndex(for: [savedBook])))
    }

    @MainActor
    @Test("store refresh invalidates tag summaries after index repair")
    func storeRefreshInvalidatesTagSummariesAfterIndexRepair() throws {
        let context = try makeContext()
        var first = sampleBook()
        first.tags = #"["parody:love live"]"#
        _ = try context.books.insert(first)
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags
            )
        )

        store.refresh()
        store.loadTagSummaries(for: .work, isTagTranslationEnabled: false)
        #expect(store.tagSummaries(for: .parody, isTagTranslationEnabled: false).map(\.name) == ["love live"])

        var second = sampleBook(title: "Second", hash: "sha1-second", filepath: "/tmp/second.cbz")
        second.tags = #"["parody:touhou project"]"#
        _ = try context.books.insert(second)

        store.refresh()
        store.loadTagSummaries(for: .work, isTagTranslationEnabled: false)
        #expect(store.tagSummaries(for: .parody, isTagTranslationEnabled: false).map(\.name).sorted() == ["love live", "touhou project"])
    }

    @MainActor
    @Test("store loads creator and work page summaries")
    func storeLoadsCreatorAndWorkPageSummaries() throws {
        let context = try makeContext()
        _ = try context.books.insert(
            sampleBook(
                tags: #"["artist:sample artist","group:sample circle","parody:love live","character:honoka","female:schoolgirl"]"#
            )
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags
            )
        )

        store.refresh()
        store.loadTagSummaries(for: .creator, isTagTranslationEnabled: false)
        store.loadTagSummaries(for: .work, isTagTranslationEnabled: false)

        #expect(store.tagSummaries(for: .creator, isTagTranslationEnabled: false).map(\.rawValue).sorted() == [
            "artist:sample artist",
            "group:sample circle"
        ])
        #expect(store.tagSummaries(for: .work, isTagTranslationEnabled: false).map(\.rawValue).sorted() == [
            "character:honoka",
            "parody:love live"
        ])
        #expect(store.tagSummaries(for: .artist, isTagTranslationEnabled: false).map(\.rawValue) == ["artist:sample artist"])
        #expect(store.tagSummaries(for: .group, isTagTranslationEnabled: false).map(\.rawValue) == ["group:sample circle"])
    }

    @MainActor
    @Test("store loads aggregate tag page summaries")
    func storeLoadsAggregateTagPageSummaries() throws {
        let context = try makeContext()
        _ = try context.books.insert(
            sampleBook(
                tags: #"["female:schoolgirl","male:glasses","mixed:group","location:school","other:full color","language:chinese"]"#
            )
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags
            )
        )

        store.refresh()
        store.loadTagSummaries(for: .tags, isTagTranslationEnabled: false)

        let summaries = store.tagSummaries(for: .tags, isTagTranslationEnabled: false)
        #expect(Set(summaries.map(\.namespace)) == ["female", "male", "mixed", "location", "other"])
        #expect(summaries.map(\.rawValue).contains("language:chinese") == false)
        #expect(store.tagSummaries(for: .female, isTagTranslationEnabled: false).map(\.rawValue) == ["female:schoolgirl"])
        #expect(store.tagSummaries(for: .other, isTagTranslationEnabled: false).map(\.rawValue) == ["other:full color"])
    }

    @Test("book detail tags are grouped without duplicated derived tags")
    func bookDetailTagsAreGroupedWithoutDuplicatedDerivedTags() {
        let tags = [
            TagDisplaySummary(id: 1, namespace: "artist", name: "sample artist", rawValue: "artist:sample artist", displayName: "sample artist", count: 1),
            TagDisplaySummary(id: 2, namespace: "group", name: "sample group", rawValue: "group:sample group", displayName: "sample group", count: 1),
            TagDisplaySummary(id: 3, namespace: "parody", name: "love live", rawValue: "parody:love live", displayName: "LoveLive!", count: 1),
            TagDisplaySummary(id: 4, namespace: "character", name: "honoka", rawValue: "character:honoka", displayName: "honoka", count: 1),
            TagDisplaySummary(id: 5, namespace: "female", name: "schoolgirl", rawValue: "female:schoolgirl", displayName: "schoolgirl", count: 1),
            TagDisplaySummary(id: 6, namespace: "language", name: "chinese", rawValue: "language:chinese", displayName: "chinese", count: 1),
            TagDisplaySummary(id: 7, namespace: "other", name: "full color", rawValue: "other:full color", displayName: "full color", count: 1)
        ]

        let groups = BookDetailTagOrganizer.groups(from: tags)

        #expect(groups.creatorGroups.map(\.namespace) == ["artist", "group"])
        #expect(groups.workGroups.map(\.namespace) == ["parody", "character"])
        #expect(groups.otherGroups.map(\.namespace) == ["female"])
        #expect(groups.creatorTags.map(\.rawValue) == ["artist:sample artist", "group:sample group"])
        #expect(groups.workTags.map(\.rawValue) == ["parody:love live", "character:honoka"])
        #expect(groups.otherTags.map(\.rawValue) == ["female:schoolgirl"])
    }

    @Test("expanded search groups all tags including derived and unknown namespaces")
    func expandedSearchGroupsAllTags() throws {
        let values = ["artist:maker", "character:hero", "language:chinese",
                      "other:full color", "other:uncensored", "custom:long label"]
            + (1...20).map { "female:tag \($0)" }
        let tags = values.enumerated().map { index, value in
            let parts = value.split(separator: ":", maxSplits: 1)
            return TagDisplaySummary(
                id: Int64(index + 1), namespace: String(parts[0]), name: String(parts[1]),
                rawValue: value, displayName: index == 0 ? "Translated artist" : String(parts[1]), count: 1
            )
        }
        let groups = BookDetailTagOrganizer.allGroups(from: tags)
        #expect(groups.map(\.namespace) == ["artist", "character", "female", "language", "other", "custom"])
        #expect(groups.flatMap(\.tags).count == 26)
        #expect(Set(groups.flatMap(\.tags).map(\.rawValue)) == Set(values))
        #expect(groups.first?.tags.first?.displayText == "Translated artist")
    }

    @Test("book detail tag display text hides raw translated name suffix")
    func bookDetailTagDisplayTextHidesRawTranslatedNameSuffix() {
        let tag = TagDisplaySummary(
            id: 1,
            namespace: "parody",
            name: "love live",
            rawValue: "parody:love live",
            displayName: "![拉拉图标](https://example.com/love.webp)LoveLive!",
            count: 1
        )

        #expect(tag.displayText == "LoveLive!")
        #expect(!tag.displayText.contains("love live"))
        #expect(tag.rawValue == "parody:love live")
    }

    @Test("library service returns translated display tags for one book")
    func libraryServiceReturnsTranslatedDisplayTagsForOneBook() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["parody:love live","female:schoolgirl"]"#
        )
        _ = try context.tags.materializeTranslations(
            [
                ExternalTagTranslation(
                    namespace: "parody",
                    name: "love live",
                    translatedName: "LoveLive! 中文",
                    intro: "作品系列说明",
                    links: ["https://example.com/love-live"]
                )
            ],
            languageCode: EhTagTranslationCache.languageCode,
            source: EhTagTranslationCache.source,
            sourceRevision: "rev1"
        )
        let parodyTag = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:love live" })
        try context.tags.setFollowed(tagID: try #require(parodyTag.id), isFollowed: true)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags
        )

        let untranslated = try service.displayTags(for: book, isTagTranslationEnabled: false)
        let translated = try service.displayTags(for: book, isTagTranslationEnabled: true)

        #expect(untranslated.first { $0.rawValue == "parody:love live" }?.displayName == "love live")
        #expect(untranslated.first { $0.rawValue == "parody:love live" }?.displayText == "love live")
        #expect(untranslated.first { $0.rawValue == "parody:love live" }?.translationIntro == "作品系列说明")
        #expect(untranslated.first { $0.rawValue == "parody:love live" }?.isFollowed == true)
        #expect(untranslated.first { $0.rawValue == "female:schoolgirl" }?.isFollowed == false)
        #expect(translated.first { $0.rawValue == "parody:love live" }?.displayName == "LoveLive! 中文")
        #expect(translated.first { $0.rawValue == "parody:love live" }?.displayText == "LoveLive! 中文")
        #expect(translated.first { $0.rawValue == "parody:love live" }?.translationLinks == ["https://example.com/love-live"])
        #expect(translated.map(\.rawValue).contains("female:schoolgirl"))
        #expect(translated.first { $0.rawValue == "female:schoolgirl" }?.translationIntro == nil)
    }

    @Test("candidate display tags filter namespaces and honor translation toggle")
    func candidateDisplayTagsFilterNamespacesAndHonorTranslationToggle() throws {
        let context = try makeContext()
        let tagsJSON = """
        ["female:sleeping","male:bbm","mixed:group","location:school","other:uncensored","parody:love live","language:chinese"]
        """
        let book = try context.books.insert(sampleBook(tags: tagsJSON))
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(forBookID: bookID, tagsJSON: tagsJSON)
        let sleeping = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "female:sleeping" })
        try context.tags.upsertTranslation(
            tagID: try #require(sleeping.id),
            languageCode: EhTagTranslationCache.languageCode,
            translatedName: "睡眠"
        )
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags
        )

        let untranslated = try service.candidateDisplayTags(for: book, isTagTranslationEnabled: false)
        let translated = try service.candidateDisplayTags(for: book, isTagTranslationEnabled: true)

        #expect(untranslated.map(\.namespace) == ["female", "male", "mixed", "location", "other"])
        #expect(untranslated.map(\.displayName) == ["sleeping", "bbm", "group", "school", "uncensored"])
        #expect(untranslated.allSatisfy { !$0.displayName.contains(":") })
        #expect(translated.first { $0.rawValue == "female:sleeping" }?.displayName == "睡眠")
        #expect(!translated.map(\.rawValue).contains("parody:love live"))
    }

    @MainActor
    @Test("candidate display tags are cached after page preparation")
    func candidateDisplayTagsAreCachedAfterPagePreparation() throws {
        let context = try makeContext()
        let firstTags = #"["female:sleeping","other:uncensored","language:chinese"]"#
        let secondTags = #"["female:schoolgirl","location:school","parody:sample"]"#
        let first = try context.books.insert(sampleBook(hash: "sha1-first", filepath: "/tmp/first.cbz", tags: firstTags))
        let second = try context.books.insert(sampleBook(hash: "sha1-second", filepath: "/tmp/second.cbz", tags: secondTags))
        try context.tags.rebuildTags(forBookID: try #require(first.databaseID), tagsJSON: firstTags)
        try context.tags.rebuildTags(forBookID: try #require(second.databaseID), tagsJSON: secondTags)
        let countingTags = CountingTagRepository(base: context.tags)
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: countingTags
            )
        )
        store.refresh()

        store.prepareCandidateDisplayData(for: [first, second], isTagTranslationEnabled: false)
        let firstFetchCount = countingTags.fetchAllTagsCallCount
        _ = store.candidateDisplayTags(for: first, isTagTranslationEnabled: false)
        _ = store.candidateDisplayTags(for: second, isTagTranslationEnabled: false)
        _ = store.candidateDisplayTags(for: first, isTagTranslationEnabled: false)

        #expect(firstFetchCount == 1)
        #expect(countingTags.fetchAllTagsCallCount == firstFetchCount)

        store.prepareCandidateDisplayData(for: [first, second], isTagTranslationEnabled: true)
        let translatedFetchCount = countingTags.fetchAllTagsCallCount
        _ = store.candidateDisplayTags(for: first, isTagTranslationEnabled: true)

        #expect(translatedFetchCount == firstFetchCount + 1)
        #expect(countingTags.fetchAllTagsCallCount == translatedFetchCount)
    }

    @Test("tag visual profiles can be saved cleared and cascade with tags")
    func tagVisualProfilesCanBeSavedClearedAndCascadeWithTags() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Tagged",
            hash: "tagged-hash",
            filepath: "/tmp/tagged.cbz",
            tags: #"["parody:love live","character:nico yazawa"]"#
        )
        let parody = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:love live" })
        let tagID = try #require(parody.id)

        let saved = try context.visualProfiles.upsert(
            TagVisualProfile(
                tagID: tagID,
                foregroundAssetPath: "TagAssets/parody/love-live-\(tagID)/show.png",
                foregroundScale: 1.7,
                foregroundOffsetX: 0.12,
                foregroundOffsetY: -0.08,
                backgroundAssetPath: "TagAssets/parody/love-live-\(tagID)/bg.png",
                backgroundScale: 1.3,
                backgroundOffsetX: -0.18,
                backgroundOffsetY: 0.22,
                backgroundColorHex: "#112233FF",
                backgroundColorSource: .manual
            )
        )

        #expect(saved.foregroundAssetPath == "TagAssets/parody/love-live-\(tagID)/show.png")
        #expect(saved.foregroundScale == 1.7)
        #expect(saved.backgroundAssetPath == "TagAssets/parody/love-live-\(tagID)/bg.png")
        #expect(saved.backgroundScale == 1.3)
        #expect(saved.backgroundColorSource == .manual)
        #expect(try context.visualProfiles.profile(tagID: tagID)?.backgroundColorHex == "#112233FF")

        let cleared = try #require(try context.visualProfiles.clearForegroundAsset(tagID: tagID))
        #expect(cleared.foregroundAssetPath == nil)
        #expect(cleared.foregroundScale == 1)
        #expect(cleared.backgroundAssetPath == "TagAssets/parody/love-live-\(tagID)/bg.png")
        #expect(cleared.backgroundColorHex == "#112233FF")

        let backgroundCleared = try #require(try context.visualProfiles.clearBackgroundAsset(tagID: tagID))
        #expect(backgroundCleared.backgroundAssetPath == nil)
        #expect(backgroundCleared.backgroundScale == 1)
        #expect(backgroundCleared.backgroundColorHex == "#112233FF")

        try context.database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tagID])
        }
        #expect(try context.visualProfiles.profile(tagID: tagID) == nil)
    }

    @Test("library service merges tag visual profiles into tag summaries")
    func libraryServiceMergesTagVisualProfilesIntoTagSummaries() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Tagged",
            hash: "visual-summary-hash",
            filepath: "/tmp/visual-summary.cbz",
            tags: #"["parody:love live"]"#
        )
        let parody = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:love live" })
        let tagID = try #require(parody.id)
        _ = try context.visualProfiles.upsert(
            TagVisualProfile(
                tagID: tagID,
                foregroundAssetPath: "TagAssets/parody/love-live-\(tagID)/show.png",
                foregroundScale: 1.25,
                backgroundAssetPath: "TagAssets/parody/love-live-\(tagID)/bg.png",
                backgroundScale: 1.5,
                backgroundColorHex: "#AA3366FF",
                backgroundColorSource: .image
            )
        )
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            tagVisualProfileRepository: context.visualProfiles,
            tagVisualAssetService: nil
        )

        let summaries = try service.tagSummaries(namespace: "parody", isTagTranslationEnabled: false)
        let summary = try #require(summaries.first)

        #expect(summary.visualProfile?.foregroundScale == 1.25)
        #expect(summary.visualProfile?.backgroundAssetPath == "TagAssets/parody/love-live-\(tagID)/bg.png")
        #expect(summary.visualProfile?.backgroundScale == 1.5)
        #expect(summary.visualProfile?.backgroundColorHex == "#AA3366FF")
    }

    @Test("tag visual asset service stores compressed readable visual assets")
    func tagVisualAssetServiceStoresCompressedReadableVisualAssets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let foregroundData = try testTransparentPNGData(size: NSSize(width: 1200, height: 900))
        let backgroundPNGData = try testPhotoLikePNGData(size: NSSize(width: 1200, height: 900))
        let request = TagVisualAssetTarget(
            tagID: 123,
            namespace: "parody",
            name: "Love Live!",
            rawValue: "parody:love live"
        )

        let stored = try service.storeForegroundImage(imageData: foregroundData, tag: request)
        let storedURL = service.resolvedURL(relativePath: stored.relativePath)
        let storedImage = try #require(NSImage(contentsOf: storedURL))
        let storedBitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: storedURL)))

        #expect(stored.relativePath == "TagAssets/parody/love-live-123/show.png")
        #expect(FileManager.default.fileExists(atPath: storedURL.path))
        #expect(storedImage.size.width <= TagVisualAssetService.maximumForegroundSize.width)
        #expect(storedImage.size.height <= TagVisualAssetService.maximumForegroundSize.height)
        #expect(alpha(atX: 0, y: 0, in: storedBitmap) < 0.01)
        #expect(alpha(atX: storedBitmap.pixelsWide / 2, y: storedBitmap.pixelsHigh / 2, in: storedBitmap) > 0.3)
        #expect(alpha(atX: storedBitmap.pixelsWide / 2, y: storedBitmap.pixelsHigh / 2, in: storedBitmap) < 0.7)
        #expect(stored.themeColorHex != nil)
        #expect(TagVisualAssetService.slug(namespaceOrName: "Sailor Moon!!") == "sailor-moon")

        let background = try service.storeBackgroundImage(imageData: backgroundPNGData, tag: request)
        let backgroundURL = service.resolvedURL(relativePath: background.relativePath)
        let backgroundImage = try #require(NSImage(contentsOf: backgroundURL))
        let backgroundData = try Data(contentsOf: backgroundURL)

        #expect(background.relativePath == "TagAssets/parody/love-live-123/bg.jpg")
        #expect(FileManager.default.fileExists(atPath: backgroundURL.path))
        #expect(!FileManager.default.fileExists(atPath: backgroundURL.deletingLastPathComponent().appendingPathComponent("bg.png").path))
        #expect(backgroundImage.size.width <= TagVisualAssetService.maximumBackgroundSize.width)
        #expect(backgroundImage.size.height <= TagVisualAssetService.maximumBackgroundSize.height)
        #expect(backgroundData.count < backgroundPNGData.count)

        let palette = try #require(try service.backgroundPalette(relativeBackgroundPath: background.relativePath))
        let paletteURL = backgroundURL.deletingLastPathComponent().appendingPathComponent(TagVisualAssetService.backgroundPaletteFilename)
        #expect(FileManager.default.fileExists(atPath: paletteURL.path))
        #expect(palette.version == TagVisualAssetService.backgroundPaletteVersion)
        #expect(palette.sourceHexColors.count == 3)
        #expect(palette.sourceHexColors.allSatisfy { NSColor.nyaehColor(hex: $0) != nil })

        let blurURL = try service.heroBlurBackgroundURL(relativeBackgroundPath: background.relativePath)
        let blurBitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: blurURL)))
        #expect(blurURL.lastPathComponent == TagVisualAssetService.heroBlurBackgroundFilename)
        #expect(FileManager.default.fileExists(atPath: blurURL.path))
        #expect(CGFloat(blurBitmap.pixelsWide) <= TagVisualAssetService.maximumHeroBlurBackgroundSize.width)
        #expect(CGFloat(blurBitmap.pixelsHigh) <= TagVisualAssetService.maximumHeroBlurBackgroundSize.height)
    }

    @Test("tag visual asset service preserves suitable jpeg backgrounds")
    func tagVisualAssetServicePreservesSuitableJPEGBackgrounds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let jpegData = try testJPEGData(size: NSSize(width: 1200, height: 675), color: .systemPurple)
        let request = TagVisualAssetTarget(
            tagID: 130,
            namespace: "parody",
            name: "Preserve JPEG",
            rawValue: "parody:preserve jpeg"
        )

        let stored = try service.storeBackgroundImage(imageData: jpegData, tag: request)
        let storedURL = service.resolvedURL(relativePath: stored.relativePath)
        let storedData = try Data(contentsOf: storedURL)
        let storedImage = try #require(NSImage(contentsOf: storedURL))

        #expect(stored.relativePath == "TagAssets/parody/preserve-jpeg-\(request.tagID)/bg.jpg")
        #expect(storedData == jpegData)
        #expect(storedImage.size.width == 1200)
        #expect(storedImage.size.height == 675)
        #expect(try service.backgroundPalette(relativeBackgroundPath: stored.relativePath) != nil)
        #expect(FileManager.default.fileExists(atPath: try service.heroBlurBackgroundURL(relativeBackgroundPath: stored.relativePath).path))
    }

    @Test("tag visual asset service keeps foreground portraits high resolution")
    func tagVisualAssetServiceKeepsForegroundPortraitsHighResolution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let foregroundData = try testTransparentPNGData(size: NSSize(width: 900, height: 1200))
        let request = TagVisualAssetTarget(
            tagID: 131,
            namespace: "character",
            name: "High Resolution",
            rawValue: "character:high resolution"
        )

        let stored = try service.storeForegroundImage(imageData: foregroundData, tag: request)
        let storedURL = service.resolvedURL(relativePath: stored.relativePath)
        let storedBitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: storedURL)))

        #expect(stored.relativePath == "TagAssets/character/high-resolution-\(request.tagID)/show.png")
        #expect(storedBitmap.pixelsWide == 900)
        #expect(storedBitmap.pixelsHigh == 1200)
        #expect(CGFloat(storedBitmap.pixelsHigh) > 432)
        #expect(CGFloat(storedBitmap.pixelsHigh) <= TagVisualAssetService.maximumForegroundSize.height)
        #expect(alpha(atX: storedBitmap.pixelsWide / 2, y: storedBitmap.pixelsHigh / 2, in: storedBitmap) > 0.3)
        #expect(alpha(atX: storedBitmap.pixelsWide / 2, y: storedBitmap.pixelsHigh / 2, in: storedBitmap) < 0.7)
    }

    @Test("tag visual asset service keeps transparent backgrounds as png")
    func tagVisualAssetServiceKeepsTransparentBackgroundsAsPNG() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let request = TagVisualAssetTarget(
            tagID: 126,
            namespace: "character",
            name: "Transparent",
            rawValue: "character:transparent"
        )

        let background = try service.storeBackgroundImage(
            imageData: testTransparentPNGData(size: NSSize(width: 640, height: 360)),
            tag: request
        )
        let backgroundURL = service.resolvedURL(relativePath: background.relativePath)
        let bitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: backgroundURL)))

        #expect(background.relativePath == "TagAssets/character/transparent-126/bg.png")
        #expect(FileManager.default.fileExists(atPath: backgroundURL.path))
        #expect(alpha(atX: 0, y: 0, in: bitmap) < 0.01)
        #expect(!FileManager.default.fileExists(atPath: backgroundURL.deletingLastPathComponent().appendingPathComponent("bg.jpg").path))
    }

    @Test("tag visual asset service ignores transparent pixels when generating palette")
    func tagVisualAssetServiceIgnoresTransparentPixelsWhenGeneratingPalette() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let request = TagVisualAssetTarget(
            tagID: 128,
            namespace: "character",
            name: "Sparse",
            rawValue: "character:sparse"
        )

        let background = try service.storeBackgroundImage(
            imageData: testSparseTransparentPNGData(size: NSSize(width: 640, height: 360)),
            tag: request
        )
        let palette = try #require(try service.backgroundPalette(relativeBackgroundPath: background.relativePath))
        let colors = palette.sourceHexColors.compactMap(NSColor.nyaehColor(hex:))

        #expect(colors.count == 3)
        #expect(colors.allSatisfy { $0.alphaComponent > 0.99 })
        #expect(colors.contains { $0.blueComponent > $0.redComponent && $0.blueComponent > $0.greenComponent })
    }

    @Test("tag visual asset service rebuilds missing hero blur cache")
    func tagVisualAssetServiceRebuildsMissingHeroBlurCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let imageData = try testPNGData(size: NSSize(width: 900, height: 500), color: .systemPurple)
        let request = TagVisualAssetTarget(
            tagID: 124,
            namespace: "parody",
            name: "Madoka",
            rawValue: "parody:madoka"
        )

        let background = try service.storeBackgroundImage(imageData: imageData, tag: request)
        let blurURL = try service.heroBlurBackgroundURL(relativeBackgroundPath: background.relativePath)
        try FileManager.default.removeItem(at: blurURL)

        let rebuiltURL = try service.heroBlurBackgroundURL(relativeBackgroundPath: background.relativePath)

        #expect(rebuiltURL == blurURL)
        #expect(FileManager.default.fileExists(atPath: rebuiltURL.path))
    }

    @Test("tag visual asset service rebuilds blur cache for legacy png background")
    func tagVisualAssetServiceRebuildsBlurCacheForLegacyPNGBackground() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let relativePath = "TagAssets/parody/legacy-127/bg.png"
        let backgroundURL = service.resolvedURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: backgroundURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try testPNGData(size: NSSize(width: 900, height: 500), color: .systemOrange)
            .write(to: backgroundURL)

        let blurURL = try service.heroBlurBackgroundURL(relativeBackgroundPath: relativePath)

        #expect(blurURL.lastPathComponent == TagVisualAssetService.heroBlurBackgroundFilename)
        #expect(FileManager.default.fileExists(atPath: blurURL.path))
    }

    @Test("tag visual asset service rebuilds palette cache for legacy png background")
    func tagVisualAssetServiceRebuildsPaletteCacheForLegacyPNGBackground() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let relativePath = "TagAssets/parody/legacy-palette-129/bg.png"
        let backgroundURL = service.resolvedURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: backgroundURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try testPNGData(size: NSSize(width: 900, height: 500), color: .systemOrange)
            .write(to: backgroundURL)

        let palette = try #require(try service.backgroundPalette(relativeBackgroundPath: relativePath))
        let paletteURL = backgroundURL.deletingLastPathComponent().appendingPathComponent(TagVisualAssetService.backgroundPaletteFilename)

        #expect(FileManager.default.fileExists(atPath: paletteURL.path))
        #expect(palette.version == TagVisualAssetService.backgroundPaletteVersion)
        #expect(palette.sourceHexColors.count == 3)
    }

    @Test("tag visual asset service repairs damaged palette cache")
    func tagVisualAssetServiceRepairsDamagedPaletteCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let request = TagVisualAssetTarget(
            tagID: 130,
            namespace: "parody",
            name: "Palette Repair",
            rawValue: "parody:palette repair"
        )

        let background = try service.storeBackgroundImage(
            imageData: testPNGData(size: NSSize(width: 900, height: 500), color: .systemTeal),
            tag: request
        )
        let backgroundURL = service.resolvedURL(relativePath: background.relativePath)
        let paletteURL = backgroundURL.deletingLastPathComponent().appendingPathComponent(TagVisualAssetService.backgroundPaletteFilename)
        try Data("not-json".utf8).write(to: paletteURL)

        let repaired = try #require(try service.backgroundPalette(relativeBackgroundPath: background.relativePath))

        #expect(repaired.version == TagVisualAssetService.backgroundPaletteVersion)
        #expect(repaired.sourceHexColors.count == 3)
        #expect(try Data(contentsOf: paletteURL) != Data("not-json".utf8))
    }

    @Test("tag visual asset service rebuilds legacy unversioned palette cache")
    func tagVisualAssetServiceRebuildsLegacyUnversionedPaletteCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let request = TagVisualAssetTarget(
            tagID: 131,
            namespace: "parody",
            name: "Legacy Palette",
            rawValue: "parody:legacy palette"
        )

        let background = try service.storeBackgroundImage(
            imageData: testPNGData(size: NSSize(width: 900, height: 500), color: .systemIndigo),
            tag: request
        )
        let backgroundURL = service.resolvedURL(relativePath: background.relativePath)
        let paletteURL = backgroundURL.deletingLastPathComponent().appendingPathComponent(TagVisualAssetService.backgroundPaletteFilename)
        try Data(##"{"hexColors":["#FFFFFFFF","#FFFFFFFF","#FFFFFFFF"]}"##.utf8).write(to: paletteURL)

        let rebuilt = try #require(try service.backgroundPalette(relativeBackgroundPath: background.relativePath))
        let stored = try JSONDecoder().decode(TagVisualBackgroundPalette.self, from: try Data(contentsOf: paletteURL))

        #expect(rebuilt.version == TagVisualAssetService.backgroundPaletteVersion)
        #expect(stored.version == TagVisualAssetService.backgroundPaletteVersion)
        #expect(stored.sourceHexColors != ["#FFFFFFFF", "#FFFFFFFF", "#FFFFFFFF"])
    }

    @Test("tag visual asset service refreshes hero blur cache when background updates")
    func tagVisualAssetServiceRefreshesHeroBlurCacheWhenBackgroundUpdates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TagVisualAssetService(appDataRoot: directory)
        let request = TagVisualAssetTarget(
            tagID: 125,
            namespace: "parody",
            name: "Nanoha",
            rawValue: "parody:nanoha"
        )

        let firstBackground = try service.storeBackgroundImage(
            imageData: testPNGData(size: NSSize(width: 900, height: 500), color: .systemBlue),
            tag: request
        )
        let blurURL = try service.heroBlurBackgroundURL(relativeBackgroundPath: firstBackground.relativePath)
        let firstBlurData = try Data(contentsOf: blurURL)

        let secondBackground = try service.storeBackgroundImage(
            imageData: testPNGData(size: NSSize(width: 900, height: 500), color: .systemGreen),
            tag: request
        )
        let refreshedBlurURL = try service.heroBlurBackgroundURL(relativeBackgroundPath: secondBackground.relativePath)
        let refreshedBlurData = try Data(contentsOf: refreshedBlurURL)

        #expect(secondBackground.relativePath == firstBackground.relativePath)
        #expect(refreshedBlurURL == blurURL)
        #expect(refreshedBlurData != firstBlurData)
    }

    @Test("work detail mesh palette adapts to light and dark")
    func workDetailMeshPaletteAdaptsToLightAndDark() throws {
        let white = TagVisualAssetService.backgroundMeshPalette(palette: nil, fallbackHex: nil)
        #expect(white.isWhiteFallback)
        #expect(white.baseColor(colorScheme: .light).isEqual(NSColor.white))
        #expect(white.baseColor(colorScheme: .dark).brightnessComponent < 0.12)

        let single = TagVisualAssetService.backgroundMeshPalette(palette: nil, fallbackHex: "#FF0000FF")
        #expect(!single.isWhiteFallback)
        #expect(single.meshColors(colorScheme: .light).count == 3)
        #expect(single.meshColors(colorScheme: .light).allSatisfy { $0.brightnessComponent >= 0.72 })
        #expect(single.meshColors(colorScheme: .light).allSatisfy { $0.saturationComponent >= 0.18 })
        #expect(single.meshColors(colorScheme: .dark).allSatisfy { $0.brightnessComponent < 0.42 })

        let palette = TagVisualBackgroundPalette(sourceHexColors: ["#FF0000FF", "#00FF00FF", "#0000FFFF"])
        let mesh = TagVisualAssetService.backgroundMeshPalette(palette: palette, fallbackHex: nil)
        let lightColors = mesh.meshColors(colorScheme: .light)
        let darkColors = mesh.meshColors(colorScheme: .dark)
        #expect(lightColors.count == 3)
        #expect(darkColors.count == 3)
        #expect(lightColors.allSatisfy { $0.brightnessComponent > 0.70 })
        #expect(darkColors.allSatisfy { $0.brightnessComponent < 0.42 })
        #expect(Set(darkColors.map { round($0.hueComponent * 100) }).count > 1)
    }

    @MainActor
    @Test("tag drop image loader reads file urls and image data")
    func tagDropImageLoaderReadsFileURLsAndImageData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageData = try testPNGData(size: NSSize(width: 320, height: 180), color: .systemTeal)
        let imageURL = directory.appendingPathComponent("drop.png")
        try imageData.write(to: imageURL)

        let fileProvider = try #require(NSItemProvider(contentsOf: imageURL))
        let fileData = try await TagDropImageLoader.imageData(from: [fileProvider])
        #expect(NSImage(data: fileData) != nil)

        let dataProvider = NSItemProvider(item: imageData as NSData, typeIdentifier: UTType.png.identifier)
        let providerData = try await TagDropImageLoader.imageData(from: [dataProvider])
        #expect(NSImage(data: providerData) != nil)

        let fallbackURL = try #require(URL(string: "https://example.com/drop.png"))
        let urlProvider = NSItemProvider(item: fallbackURL as NSURL, typeIdentifier: UTType.url.identifier)
        urlProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, NSError(domain: "NyaEHCoreTests", code: 1))
            return nil
        }
        let urlFallbackData = try await TagDropImageLoader.imageData(from: [urlProvider]) { url in
            #expect(url == fallbackURL)
            return (imageData, testURLResponse(url: url))
        }
        #expect(NSImage(data: urlFallbackData) != nil)

        let mixedDataProvider = NSItemProvider()
        mixedDataProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, NSError(domain: "NyaEHCoreTests", code: 2))
            return nil
        }
        mixedDataProvider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(imageData, nil)
            return nil
        }
        let mixedData = try await TagDropImageLoader.imageData(from: [mixedDataProvider])
        #expect(NSImage(data: mixedData) != nil)

        let textURLProvider = NSItemProvider(item: "preview \(fallbackURL.absoluteString)" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)
        let textURLData = try await TagDropImageLoader.imageData(from: [textURLProvider]) { url in
            #expect(url == fallbackURL)
            return (imageData, testURLResponse(url: url))
        }
        #expect(NSImage(data: textURLData) != nil)

        let remoteThenDirectProvider = NSItemProvider(item: fallbackURL as NSURL, typeIdentifier: UTType.url.identifier)
        remoteThenDirectProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(imageData, nil)
            return nil
        }
        let remoteThenDirectData = try await TagDropImageLoader.imageData(from: [remoteThenDirectProvider]) { url in
            #expect(url == fallbackURL)
            return (Data("not an image".utf8), testURLResponse(url: url))
        }
        #expect(NSImage(data: remoteThenDirectData) != nil)

        let invalidProvider = NSItemProvider(item: "not an image" as NSString, typeIdentifier: UTType.plainText.identifier)
        await #expect(throws: NyaEHError.self) {
            _ = try await TagDropImageLoader.imageData(from: [invalidProvider])
        }
    }

    @MainActor
    @Test("cover search drop loader accepts image files and direct image data")
    func coverSearchDropLoaderAcceptsImageFilesAndDirectImageData() async throws {
        #expect(CoverImageSearchDropLoader.typeIdentifiers.contains(UTType.fileURL.identifier))
        #expect(CoverImageSearchDropLoader.typeIdentifiers.contains(UTType.image.identifier))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageData = try testPNGData(size: NSSize(width: 120, height: 180), color: .systemPurple)
        let imageURL = directory.appendingPathComponent("cover-drop.png")
        try imageData.write(to: imageURL)

        let fileProvider = try #require(NSItemProvider(contentsOf: imageURL))
        let fileData = try await CoverImageSearchDropLoader.imageData(from: [fileProvider])
        #expect(NSImage(data: fileData) != nil)

        let directProvider = NSItemProvider(
            item: imageData as NSData,
            typeIdentifier: UTType.png.identifier
        )
        let directData = try await CoverImageSearchDropLoader.imageData(from: [directProvider])
        #expect(NSImage(data: directData) != nil)

        let invalidProvider = NSItemProvider(
            item: "not an image" as NSString,
            typeIdentifier: UTType.plainText.identifier
        )
        await #expect(throws: NyaEHError.self) {
            _ = try await CoverImageSearchDropLoader.imageData(from: [invalidProvider])
        }
    }

    @MainActor
    @Test("tag pasteboard image loader parses html and text image urls")
    func tagPasteboardImageLoaderParsesHTMLAndTextImageURLs() throws {
        let imageURL = try #require(URL(string: "https://example.com/images/drop.png"))
        let html = #"<a href="https://example.com/page"><img src="/images/drop.png"></a>"#

        #expect(TagPasteboardImageLoader.imageURLs(inHTML: html, baseURL: URL(string: "https://example.com/page")).first == imageURL)
        #expect(TagPasteboardImageLoader.firstHTTPURLs(in: "drag \(imageURL.absoluteString)").first == imageURL)
    }

    @MainActor
    @Test("store quick imports dropped tag foreground images")
    func storeQuickImportsDroppedTagForegroundImages() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Dropped",
            hash: "dropped-hash",
            filepath: "/tmp/dropped.cbz",
            tags: #"["parody:love live"]"#
        )
        let parody = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:love live" })
        let tagID = try #require(parody.id)
        let appDataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            tagVisualProfileRepository: context.visualProfiles,
            tagVisualAssetService: TagVisualAssetService(appDataRoot: appDataRoot)
        )
        let store = CatalogStore(service: service)
        let request = TagVisualAssetTarget(
            tagID: tagID,
            namespace: "parody",
            name: "love live",
            rawValue: "parody:love live"
        )
        let firstImageData = try testPNGData(size: NSSize(width: 900, height: 500), color: .systemPink)

        store.importDroppedTagForegroundImage(imageData: firstImageData, tag: request)

        let firstProfile = try #require(try context.visualProfiles.profile(tagID: tagID))
        #expect(firstProfile.foregroundAssetPath == "TagAssets/parody/love-live-\(tagID)/show.png")
        #expect(firstProfile.foregroundScale == 1)
        #expect(firstProfile.foregroundOffsetX == 0)
        #expect(firstProfile.foregroundOffsetY == 0)
        #expect(firstProfile.backgroundColorSource == .image)
        #expect(store.loadError == nil)

        _ = try context.visualProfiles.upsert(
            TagVisualProfile(
                tagID: tagID,
                foregroundAssetPath: firstProfile.foregroundAssetPath,
                backgroundColorHex: "#112233FF",
                backgroundColorSource: .manual
            )
        )
        let secondImageData = try testPNGData(size: NSSize(width: 900, height: 500), color: .systemGreen)

        store.importDroppedTagForegroundImage(imageData: secondImageData, tag: request)

        let replacedProfile = try #require(try context.visualProfiles.profile(tagID: tagID))
        #expect(replacedProfile.foregroundAssetPath == firstProfile.foregroundAssetPath)
        #expect(replacedProfile.backgroundColorHex == "#112233FF")
        #expect(replacedProfile.backgroundColorSource == .manual)
    }

    @MainActor
    @Test("store quick imports dropped tag background images")
    func storeQuickImportsDroppedTagBackgroundImages() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Dropped Background",
            hash: "dropped-background-hash",
            filepath: "/tmp/dropped-background.cbz",
            tags: #"["parody:love live"]"#
        )
        let parody = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "parody:love live" })
        let tagID = try #require(parody.id)
        let appDataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            tagVisualProfileRepository: context.visualProfiles,
            tagVisualAssetService: TagVisualAssetService(appDataRoot: appDataRoot)
        )
        let store = CatalogStore(service: service)
        let request = TagVisualAssetTarget(
            tagID: tagID,
            namespace: "parody",
            name: "love live",
            rawValue: "parody:love live"
        )
        let existingProfile = try context.visualProfiles.upsert(
            TagVisualProfile(
                tagID: tagID,
                foregroundAssetPath: "TagAssets/parody/love-live-\(tagID)/show.png",
                foregroundScale: 1.35,
                foregroundOffsetX: 0.12,
                foregroundOffsetY: -0.08,
                backgroundScale: 1.8,
                backgroundOffsetX: -0.14,
                backgroundOffsetY: 0.2,
                backgroundColorHex: "#445566FF",
                backgroundColorSource: .generated
            )
        )
        let imageData = try testPNGData(size: NSSize(width: 900, height: 500), color: .systemBlue)

        store.importDroppedTagImage(kind: .background, imageData: imageData, tag: request)

        let profile = try #require(try context.visualProfiles.profile(tagID: tagID))
        #expect(profile.foregroundAssetPath == existingProfile.foregroundAssetPath)
        #expect(profile.foregroundScale == existingProfile.foregroundScale)
        #expect(profile.foregroundOffsetX == existingProfile.foregroundOffsetX)
        #expect(profile.foregroundOffsetY == existingProfile.foregroundOffsetY)
        #expect(profile.backgroundAssetPath == "TagAssets/parody/love-live-\(tagID)/bg.jpg")
        #expect(profile.backgroundScale == existingProfile.backgroundScale)
        #expect(profile.backgroundOffsetX == existingProfile.backgroundOffsetX)
        #expect(profile.backgroundOffsetY == existingProfile.backgroundOffsetY)
        #expect(profile.backgroundColorSource == .image)
        #expect(profile.backgroundColorHex != existingProfile.backgroundColorHex)
        #expect(profile.updatedAt >= existingProfile.updatedAt)
        #expect(store.loadError == nil)
    }

    @MainActor
    @Test("store toggles marked state for detail favorite button")
    func storeTogglesMarkedStateForDetailFavoriteButton() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags
            )
        )
        store.refresh()

        store.toggleMarked(for: book)
        #expect(store.book(id: book.id)?.mark == true)
        #expect(try context.books.fetch(id: try #require(book.databaseID))?.mark == true)

        let updated = try #require(store.book(id: book.id))
        store.toggleMarked(for: updated)
        #expect(store.book(id: book.id)?.mark == false)
    }

    @MainActor
    @Test("store records read count for reader launch")
    func storeRecordsReadCountForReaderLaunch() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags
            )
        )
        store.refresh()

        store.recordRead(for: book)

        #expect(store.book(id: book.id)?.readCount == 1)
        #expect(store.book(id: book.id)?.lastReadAt != nil)
        #expect(store.recentlyViewedBooks.map(\.id) == [book.id])
        #expect(try context.books.fetch(id: try #require(book.databaseID))?.readCount == 1)
        #expect(try context.books.fetch(id: try #require(book.databaseID))?.lastReadAt != nil)
    }

    @Test("record read requires database id")
    func recordReadRequiresDatabaseID() throws {
        let context = try makeContext()
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags
        )

        #expect(throws: NyaEHError.self) {
            _ = try service.recordRead(for: sampleBook())
        }
    }

    private func sampleBook(
        title: String = "Sample Book",
        hash: String = "sha1-sample",
        filepath: String = "/tmp/sample.cbz",
        tags: String = "[\"language:chinese\"]"
    ) -> LibraryBook {
        LibraryBook(
            title: title,
            hash: hash,
            filepath: filepath,
            type: .archive,
            fileCount: 42,
            bundleSize: 123_456,
            mtime: 1_775_657_594_420,
            status: .unscanned,
            date: 1_775_657_594_420,
            tags: tags
        )
    }

    private func testCoverVector(
        bookID: LibraryBook.DatabaseID,
        values: [Float]
    ) -> CoverFeatureVector {
        CoverFeatureVector(
            bookID: bookID,
            coverHash: "cover-\(bookID)",
            visionRevision: 1,
            elementType: 1,
            elementCount: values.count,
            featureData: values.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }

    @discardableResult
    private func insertBook(
        _ context: RepositoryContext,
        title: String,
        hash: String,
        filepath: String,
        tags: String
    ) throws -> LibraryBook {
        let book = try context.books.insert(
            sampleBook(title: title, hash: hash, filepath: filepath, tags: tags)
        )
        try context.tags.rebuildTags(forBookID: try #require(book.databaseID), tagsJSON: tags)
        return book
    }

    private func bumpUpdatedAt(
        _ context: RepositoryContext,
        bookID: LibraryBook.DatabaseID,
        updatedAt: Int64
    ) throws {
        try context.database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE library_books SET updated_at = ? WHERE id = ?",
                arguments: [updatedAt, bookID]
            )
        }
    }

    private func makeContext() throws -> RepositoryContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: directory.appendingPathComponent("NyaEH.sqlite").path)
        return RepositoryContext(
            database: database,
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            metadata: SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue),
            tags: SQLiteTagRepository(dbQueue: database.dbQueue),
            collections: SQLiteCollectionRepository(dbQueue: database.dbQueue),
            versionGroups: SQLiteVersionGroupRepository(dbQueue: database.dbQueue),
            versionLabelSuggestions: SQLiteVersionLabelSuggestionRepository(dbQueue: database.dbQueue),
            versionLabels: SQLiteBookVersionLabelRepository(dbQueue: database.dbQueue),
            readingStates: SQLiteBookReadingStateRepository(dbQueue: database.dbQueue),
            versionRecommendations: SQLiteVersionRecommendationRepository(dbQueue: database.dbQueue),
            collectionRecommendations: SQLiteCollectionRecommendationRepository(dbQueue: database.dbQueue),
            workCharacters: SQLiteWorkCharacterRepository(dbQueue: database.dbQueue),
            workDetails: SQLiteWorkDetailRepository(dbQueue: database.dbQueue),
            visualProfiles: SQLiteTagVisualProfileRepository(dbQueue: database.dbQueue)
        )
    }

    private func testPNGData(size: NSSize, color: NSColor) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func testJPEGData(size: NSSize, color: NSColor) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()

        return try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]))
    }

    private func testURLResponse(url: URL, statusCode: Int = 200) -> URLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ) ?? URLResponse(
            url: url,
            mimeType: nil,
            expectedContentLength: -1,
            textEncodingName: nil
        )
    }

    private func testTransparentPNGData(size: NSSize) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.systemPink.withAlphaComponent(0.5).setFill()
        NSRect(
            x: size.width * 0.2,
            y: size.height * 0.2,
            width: size.width * 0.6,
            height: size.height * 0.6
        ).fill()
        image.unlockFocus()

        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func testSparseTransparentPNGData(size: NSSize) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.systemBlue.setFill()
        NSRect(
            x: size.width * 0.45,
            y: size.height * 0.35,
            width: size.width * 0.2,
            height: size.height * 0.3
        ).fill()
        image.unlockFocus()

        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func testPhotoLikePNGData(size: NSSize) throws -> Data {
        let width = Int(size.width)
        let height = Int(size.height)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let bytesPerRow = bitmap.bytesPerRow
        let samplesPerPixel = bitmap.samplesPerPixel
        let data = try #require(bitmap.bitmapData)
        var randomState: UInt32 = 0xC0FFEE

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * samplesPerPixel
                randomState = randomState &* 1_664_525 &+ 1_013_904_223
                data[offset] = UInt8(truncatingIfNeeded: randomState >> 16)
                randomState = randomState &* 1_664_525 &+ 1_013_904_223
                data[offset + 1] = UInt8(truncatingIfNeeded: randomState >> 16)
                randomState = randomState &* 1_664_525 &+ 1_013_904_223
                data[offset + 2] = UInt8(truncatingIfNeeded: randomState >> 16)
                data[offset + 3] = 255
            }
        }

        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func alpha(atX x: Int, y: Int, in bitmap: NSBitmapImageRep) -> CGFloat {
        bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1
    }
}

private struct RepositoryContext {
    let database: DatabaseManager
    let books: SQLiteLibraryBookRepository
    let metadata: SQLiteGalleryMetadataRepository
    let tags: SQLiteTagRepository
    let collections: SQLiteCollectionRepository
    let versionGroups: SQLiteVersionGroupRepository
    let versionLabelSuggestions: SQLiteVersionLabelSuggestionRepository
    let versionLabels: SQLiteBookVersionLabelRepository
    let readingStates: SQLiteBookReadingStateRepository
    let versionRecommendations: SQLiteVersionRecommendationRepository
    let collectionRecommendations: SQLiteCollectionRecommendationRepository
    let workCharacters: SQLiteWorkCharacterRepository
    let workDetails: SQLiteWorkDetailRepository
    let visualProfiles: SQLiteTagVisualProfileRepository
}

private struct FakeCoverFeatureQueryGenerator: CoverFeatureQueryGenerating {
    let values: [Float]
    let visionRevision = 1

    func featureQuery(forImageData data: Data) throws -> CoverFeatureQuery {
        CoverFeatureQuery(
            visionRevision: visionRevision,
            elementType: 1,
            elementCount: values.count,
            featureData: values.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }
}

private final class FakeCoverVectorSearch: CoverVectorSearch, @unchecked Sendable {
    private let indexedIDs: Set<LibraryBook.DatabaseID>
    private let neighbors: [LibraryBook.DatabaseID: [CoverVectorNeighbor]]

    init(
        indexedBookIDs: Set<LibraryBook.DatabaseID>? = nil,
        neighbors: [LibraryBook.DatabaseID: [CoverVectorNeighbor]]
    ) {
        if let indexedBookIDs {
            indexedIDs = indexedBookIDs
        } else {
            indexedIDs = Set(neighbors.keys)
                .union(neighbors.values.flatMap { $0.map(\.bookID) })
        }
        self.neighbors = neighbors
    }

    func indexedBookIDs() throws -> Set<LibraryBook.DatabaseID> {
        indexedIDs
    }

    func nearestNeighbors(bookID: LibraryBook.DatabaseID, limit: Int) throws -> [CoverVectorNeighbor] {
        Array((neighbors[bookID] ?? []).prefix(limit))
    }

    func nearestNeighbors(query: CoverFeatureQuery, limit: Int) throws -> [CoverVectorNeighbor] {
        []
    }
}

private final class SpyCoverVectorRepository: CoverVectorRepository, @unchecked Sendable {
    private(set) var deletedBookIDs: [LibraryBook.DatabaseID] = []
    private(set) var prunedBookIDSets: [Set<LibraryBook.DatabaseID>] = []

    func indexedBookIDs() throws -> Set<LibraryBook.DatabaseID> {
        []
    }

    func nearestNeighbors(bookID: LibraryBook.DatabaseID, limit: Int) throws -> [CoverVectorNeighbor] {
        []
    }

    func nearestNeighbors(query: CoverFeatureQuery, limit: Int) throws -> [CoverVectorNeighbor] {
        []
    }

    func fetchEntry(bookID: LibraryBook.DatabaseID) throws -> CoverVectorEntry? {
        nil
    }

    func upsertVector(_ vector: CoverFeatureVector) throws {}

    func markFailure(bookID: LibraryBook.DatabaseID, coverHash: String?, message: String) throws {}

    func deleteVector(bookID: LibraryBook.DatabaseID) throws {
        deletedBookIDs.append(bookID)
    }

    func pruneOrphanedVectors(existingBookIDs: Set<LibraryBook.DatabaseID>) throws -> Int {
        prunedBookIDSets.append(existingBookIDs)
        return 0
    }

    func clear() throws {}

    func storedVectorCount() throws -> Int {
        0
    }

    func storedFailureCount() throws -> Int {
        0
    }
}

private final class CountingTagRepository: TagRepository {
    private let base: any TagRepository
    private(set) var fetchAllTagsCallCount = 0

    init(base: any TagRepository) {
        self.base = base
    }

    func rebuildTags(forBookID bookID: LibraryBook.DatabaseID, tagsJSON: String) throws {
        try base.rebuildTags(forBookID: bookID, tagsJSON: tagsJSON)
    }

    func rebuildAllTags(from books: [LibraryBook]) throws {
        try base.rebuildAllTags(from: books)
    }

    func indexedBookTagCount() throws -> Int {
        try base.indexedBookTagCount()
    }

    func summaries(namespace: String?) throws -> [TagSummary] {
        try base.summaries(namespace: namespace)
    }

    func summaries(namespace: String?, languageCode: String?) throws -> [TagSummary] {
        try base.summaries(namespace: namespace, languageCode: languageCode)
    }

    func topSummaries(namespaces: [String], limit: Int, languageCode: String?) throws -> [TagSummary] {
        try base.topSummaries(namespaces: namespaces, limit: limit, languageCode: languageCode)
    }

    func tags(forBookID bookID: LibraryBook.DatabaseID) throws -> [NyaEHCore.Tag] {
        try base.tags(forBookID: bookID)
    }

    func bookIDs(namespace: String, name: String) throws -> [LibraryBook.DatabaseID] {
        try base.bookIDs(namespace: namespace, name: name)
    }

    func followedTagIDs() throws -> Set<NyaEHCore.Tag.DatabaseID> {
        try base.followedTagIDs()
    }

    func setFollowed(tagID: NyaEHCore.Tag.DatabaseID, isFollowed: Bool) throws {
        try base.setFollowed(tagID: tagID, isFollowed: isFollowed)
    }

    func upsertTranslation(tagID: NyaEHCore.Tag.DatabaseID, languageCode: String, translatedName: String) throws {
        try base.upsertTranslation(tagID: tagID, languageCode: languageCode, translatedName: translatedName)
    }

    func fetchAllTags() throws -> [NyaEHCore.Tag] {
        fetchAllTagsCallCount += 1
        return try base.fetchAllTags()
    }

    func materializeTranslations(
        _ translations: [ExternalTagTranslation],
        languageCode: String,
        source: String,
        sourceRevision: String
    ) throws -> Int {
        try base.materializeTranslations(
            translations,
            languageCode: languageCode,
            source: source,
            sourceRevision: sourceRevision
        )
    }

    func translation(for tag: NyaEHCore.Tag, languageCode: String) throws -> TagResolvedTranslation? {
        try base.translation(for: tag, languageCode: languageCode)
    }
}

private actor OrganizationExecutionGate {
    private var startCount = 0
    private var paused: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func pause() async {
        startCount += 1
        let ready = startWaiters.filter { $0.0 <= startCount }
        startWaiters.removeAll { $0.0 <= startCount }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { paused.append($0) }
    }

    func waitForStarts(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func releaseNext() {
        guard !paused.isEmpty else { return }
        paused.removeFirst().resume()
    }
}

private actor CollectionOrderCommitGate {
    private var sleepCount = 0
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func sleep(_: UInt64) async throws {
        sleepCount += 1
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForSleepCount(_ targetCount: Int) async {
        while sleepCount < targetCount {
            await Task.yield()
        }
    }

    func resumeAll() {
        let pendingContinuations = continuations
        continuations = []
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}

private final class StubSemanticTitleVectorSearch: SemanticTitleVectorSearch, @unchecked Sendable {
    private let profile = SemanticEmbeddingProfile(
        modelIdentifier: "test-cjk",
        revision: 1,
        dimension: 512,
        maximumSequenceLength: 256,
        preprocessingVersion: ContextualTitleEmbeddingService.preprocessingVersion,
        poolingVersion: 1
    )
    private let neighbors: [LibraryBook.DatabaseID: [SemanticTitleVectorNeighbor]]

    init(neighbors: [LibraryBook.DatabaseID: [SemanticTitleVectorNeighbor]]) {
        self.neighbors = neighbors
    }

    func activeProfile() throws -> SemanticEmbeddingProfile? {
        profile
    }

    func indexedBookIDs() throws -> Set<LibraryBook.DatabaseID> {
        Set(neighbors.keys)
    }

    func nearestNeighbors(
        bookID: LibraryBook.DatabaseID,
        among candidateBookIDs: Set<LibraryBook.DatabaseID>,
        limit: Int
    ) throws -> [SemanticTitleVectorNeighbor] {
        Array((neighbors[bookID] ?? []).filter { candidateBookIDs.contains($0.bookID) }.prefix(limit))
    }
}

private let legacyV2SchemaSQL = """
    CREATE TABLE grdb_migrations (
        identifier TEXT NOT NULL PRIMARY KEY
    );

    CREATE TABLE gallery_metadata (
        hash TEXT PRIMARY KEY,
        gallery_id INTEGER,
        gallery_token TEXT,
        title TEXT,
        title_jpn TEXT,
        status TEXT NOT NULL,
        rating REAL,
        tags TEXT NOT NULL DEFAULT '[]',
        pages INTEGER,
        posted INTEGER,
        filesize INTEGER,
        category TEXT,
        url TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );

    CREATE TABLE library_books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        cover_path TEXT,
        hash TEXT NOT NULL,
        filepath TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL,
        file_count INTEGER,
        bundle_size INTEGER,
        mtime INTEGER,
        cover_hash TEXT,
        status TEXT NOT NULL,
        date INTEGER NOT NULL,
        rating REAL,
        tags TEXT NOT NULL DEFAULT '[]',
        title_jpn TEXT,
        pages INTEGER,
        posted INTEGER,
        filesize INTEGER,
        category TEXT,
        url TEXT,
        mark INTEGER NOT NULL DEFAULT 0,
        hidden_book INTEGER NOT NULL DEFAULT 0,
        read_count INTEGER NOT NULL DEFAULT 0,
        exist INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );

    CREATE TABLE import_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_path TEXT NOT NULL,
        status TEXT NOT NULL,
        message TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE INDEX idx_library_books_hash ON library_books(hash);
    CREATE INDEX idx_library_books_title ON library_books(title);
    CREATE INDEX idx_library_books_status ON library_books(status);
    CREATE INDEX idx_library_books_mark ON library_books(mark);
    CREATE INDEX idx_library_books_hidden_book ON library_books(hidden_book);
    CREATE INDEX idx_gallery_metadata_status ON gallery_metadata(status);
    CREATE INDEX idx_gallery_metadata_gallery ON gallery_metadata(gallery_id, gallery_token);
    CREATE INDEX idx_import_jobs_status ON import_jobs(status);
    """
