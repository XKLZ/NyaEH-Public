import Foundation
import Testing
@testable import NyaEHCore

@Suite("Import pipeline repository", .serialized)
struct ImportPipelineRepositoryTests {
    @Test("migration creates a persistent inbox item for each unscanned record")
    func reconcileCreatesPersistentInboxItems() throws {
        let context = try makeContext()
        let first = try context.books.insert(makeBook(title: "A", hash: hash("a")))
        let second = try context.books.insert(makeBook(title: "B", hash: hash("b"), hidden: true))

        try context.pipeline.reconcile(books: [first, second])
        let items = try context.pipeline.fetchAllItems()

        #expect(items.count == 2)
        #expect(Set(items.map(\.bookID)) == Set([first.databaseID!, second.databaseID!]))
        #expect(items.allSatisfy { $0.stage == .metadataPending && $0.batchID == nil })
    }

    @Test("batch membership is a snapshot and later scans wait for the next batch")
    func batchBoundaryDoesNotAbsorbLaterBooks() throws {
        let context = try makeContext()
        let first = try context.books.insert(makeBook(title: "A", hash: hash("a")))
        try context.pipeline.reconcile(books: [first])
        let batch = try #require(try context.pipeline.createBatchFromPendingItems())

        let later = try context.books.insert(makeBook(title: "B", hash: hash("b")))
        try context.pipeline.reconcile(books: [first, later])

        let batchItems = try context.pipeline.fetchItems(batchID: batch.id)
        let laterItem = try #require(try context.pipeline.fetchItem(bookID: later.databaseID!))
        #expect(batchItems.map(\.bookID) == [first.databaseID!])
        #expect(laterItem.batchID == nil)
    }

    @Test("restart recovery returns interrupted metadata work to pending")
    func recoveryResetsRunningMetadataItem() throws {
        let context = try makeContext()
        let book = try context.books.insert(makeBook(title: "A", hash: hash("a")))
        try context.pipeline.reconcile(books: [book])
        _ = try context.pipeline.createBatchFromPendingItems()
        var item = try #require(try context.pipeline.fetchItem(bookID: book.databaseID!))
        item.stage = .metadataRunning
        try context.pipeline.updateItem(item)

        try context.pipeline.recoverInterruptedWork()

        let recovered = try #require(try context.pipeline.fetchItem(bookID: book.databaseID!))
        #expect(recovered.stage == .metadataPending)
    }

    @Test("source changes do not rewrite an active batch snapshot")
    func sourceChangePreservesActiveBatchBoundary() throws {
        let context = try makeContext()
        var book = try context.books.insert(makeBook(title: "A", hash: hash("a")))
        try context.pipeline.reconcile(books: [book])
        let batch = try #require(try context.pipeline.createBatchFromPendingItems())

        book.hash = hash("changed")
        book = try context.books.update(book)
        try context.pipeline.reconcile(books: [book])

        let item = try #require(try context.pipeline.fetchItem(bookID: book.databaseID!))
        #expect(item.batchID == batch.id)
        #expect(item.sourceHash == hash("a"))
        #expect(item.stage == .sourceNeedsAttention)
    }

    @Test("completed items re-enter the next wave when source hash changes")
    func completedItemReentersAfterSourceChange() throws {
        let context = try makeContext()
        var book = try context.books.insert(makeBook(title: "A", hash: hash("a")))
        try context.pipeline.reconcile(books: [book])
        var item = try #require(try context.pipeline.fetchItem(bookID: book.databaseID!))
        item.stage = .completed
        item.completedAt = Timestamp.nowMilliseconds()
        try context.pipeline.updateItem(item)

        book.hash = hash("changed")
        book = try context.books.update(book)
        try context.pipeline.reconcile(books: [book])

        let reset = try #require(try context.pipeline.fetchItem(bookID: book.databaseID!))
        #expect(reset.batchID == nil)
        #expect(reset.sourceHash == hash("changed"))
        #expect(reset.stage == .metadataPending)
        #expect(reset.completedAt == nil)
    }

    private func makeContext() throws -> ImportPipelineTestContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: root.appendingPathComponent("NyaEH.sqlite").path)
        return ImportPipelineTestContext(
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            pipeline: SQLiteImportPipelineRepository(dbQueue: database.dbQueue)
        )
    }

    private func makeBook(title: String, hash: String, hidden: Bool = false) -> LibraryBook {
        LibraryBook(
            title: title,
            hash: hash,
            filepath: "/tmp/\(title).zip",
            type: .archive,
            status: .unscanned,
            hiddenBook: hidden,
            exist: true
        )
    }

    private func hash(_ seed: String) -> String {
        String(repeating: seed.first.map(String.init) ?? "0", count: 40)
    }
}

private struct ImportPipelineTestContext {
    let books: SQLiteLibraryBookRepository
    let pipeline: SQLiteImportPipelineRepository
}
