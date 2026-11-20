import Foundation
import Testing
@testable import NyaEHCore

@Suite("cover vector repository")
struct CoverVectorRepositoryTests {
    @Test("stores vectors and returns nearest neighbors")
    func storesVectorsAndReturnsNearestNeighbors() throws {
        let repository = try makeRepository()
        try repository.upsertVector(vector(bookID: 1, coverHash: "cover-a", values: [0, 0, 0, 0]))
        try repository.upsertVector(vector(bookID: 2, coverHash: "cover-b", values: [0.1, 0, 0, 0]))
        try repository.upsertVector(vector(bookID: 3, coverHash: "cover-c", values: [9, 9, 9, 9]))

        let neighbors = try repository.nearestNeighbors(bookID: 1, limit: 2)

        #expect(neighbors.map(\.bookID) == [2, 3])
        #expect(try repository.storedVectorCount() == 3)
        #expect(try repository.indexedBookIDs() == [1, 2, 3])
    }

    @Test("queries nearest neighbors with an external vector without storing it")
    func queriesExternalVectorWithoutStoringIt() throws {
        let repository = try makeRepository()
        try repository.upsertVector(vector(bookID: 1, coverHash: "cover-a", values: [0, 0, 0, 0]))
        try repository.upsertVector(vector(bookID: 2, coverHash: "cover-b", values: [0.5, 0, 0, 0]))
        try repository.upsertVector(vector(bookID: 3, coverHash: "cover-c", values: [4, 4, 4, 4]))
        let queryValues: [Float] = [0.2, 0, 0, 0]
        let query = CoverFeatureQuery(
            visionRevision: 1,
            elementType: 1,
            elementCount: queryValues.count,
            featureData: queryValues.withUnsafeBufferPointer { Data(buffer: $0) }
        )

        let neighbors = try repository.nearestNeighbors(query: query, limit: 2)

        #expect(neighbors.map(\.bookID) == [1, 2])
        #expect(abs(neighbors[0].distance - 0.04) < 0.0001)
        #expect(abs(neighbors[1].distance - 0.09) < 0.0001)
        #expect(try repository.storedVectorCount() == 3)
    }

    @Test("rejects an external vector with a different shape")
    func rejectsExternalVectorWithDifferentShape() throws {
        let repository = try makeRepository()
        try repository.upsertVector(vector(bookID: 1, coverHash: "cover-a", values: [0, 0, 0, 0]))
        let queryValues: [Float] = [0, 0, 0]
        let query = CoverFeatureQuery(
            visionRevision: 1,
            elementType: 1,
            elementCount: queryValues.count,
            featureData: queryValues.withUnsafeBufferPointer { Data(buffer: $0) }
        )

        #expect(throws: NyaEHError.self) {
            _ = try repository.nearestNeighbors(query: query, limit: 1)
        }
    }

    @Test("marks failures and clears rebuildable cache")
    func marksFailuresAndClearsRebuildableCache() throws {
        let repository = try makeRepository()
        try repository.upsertVector(vector(bookID: 1, coverHash: "cover-a", values: [0, 0, 0, 0]))
        try repository.markFailure(bookID: 2, coverHash: "cover-b", message: "decode failed")

        let failedEntry = try #require(try repository.fetchEntry(bookID: 2))
        #expect(failedEntry.failureMessage == "decode failed")
        #expect(try repository.storedVectorCount() == 1)
        #expect(try repository.storedFailureCount() == 1)

        try repository.clear()

        #expect(try repository.storedVectorCount() == 0)
        #expect(try repository.storedFailureCount() == 0)
        #expect(try repository.fetchEntry(bookID: 1) == nil)
        #expect(try repository.fetchEntry(bookID: 2) == nil)
    }

    @Test("rejects vectors with a different element count until cache is cleared")
    func rejectsMismatchedVectorShapeUntilCleared() throws {
        let repository = try makeRepository()
        try repository.upsertVector(vector(bookID: 1, coverHash: "cover-a", values: [0, 0, 0, 0]))

        #expect(throws: NyaEHError.self) {
            try repository.upsertVector(vector(bookID: 2, coverHash: "cover-b", values: [0, 0, 0]))
        }

        try repository.clear()
        try repository.upsertVector(vector(bookID: 2, coverHash: "cover-b", values: [0, 0, 0]))

        #expect(try repository.storedVectorCount() == 1)
    }

    @Test("prunes orphaned vector entries and embeddings")
    func prunesOrphanedVectorEntriesAndEmbeddings() throws {
        let repository = try makeRepository()
        try repository.upsertVector(vector(bookID: 1, coverHash: "cover-a", values: [0, 0, 0, 0]))
        try repository.upsertVector(vector(bookID: 2, coverHash: "cover-b", values: [1, 0, 0, 0]))
        try repository.markFailure(bookID: 3, coverHash: "cover-c", message: "missing cover")

        let pruned = try repository.pruneOrphanedVectors(existingBookIDs: [1])

        #expect(pruned == 2)
        #expect(try repository.fetchEntry(bookID: 1) != nil)
        #expect(try repository.fetchEntry(bookID: 2) == nil)
        #expect(try repository.fetchEntry(bookID: 3) == nil)
        #expect(try repository.storedVectorCount() == 1)
        #expect(try repository.storedFailureCount() == 0)
        #expect(try repository.nearestNeighbors(bookID: 1, limit: 3).isEmpty)
    }

    private func makeRepository() throws -> SQLiteCoverVectorRepository {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteCoverVectorRepository(path: directory.appendingPathComponent("CoverVectors.sqlite").path)
    }

    private func vector(bookID: LibraryBook.DatabaseID, coverHash: String, values: [Float]) -> CoverFeatureVector {
        CoverFeatureVector(
            bookID: bookID,
            coverHash: coverHash,
            visionRevision: 1,
            elementType: 1,
            elementCount: values.count,
            featureData: values.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }
}
