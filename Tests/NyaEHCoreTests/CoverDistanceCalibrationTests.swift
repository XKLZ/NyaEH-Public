import Foundation
import Testing
@testable import NyaEHCore

@Suite("cover distance calibration")
struct CoverDistanceCalibrationTests {
    @Test("generated vectors exercise the squared L2 threshold boundaries")
    func syntheticThresholds() throws {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLiteCoverVectorRepository(path: directory.appendingPathComponent("vectors.sqlite").path)
        let size = 2048
        let distances = [19, 20, 21, 119, 120, 121]
        func vector(ones: Int) -> Data {
            let values = Array(repeating: Float(1), count: ones) + Array(repeating: Float(0), count: size - ones)
            return values.withUnsafeBytes { Data($0) }
        }
        for distance in distances {
            try repository.upsertVector(CoverFeatureVector(
                bookID: Int64(distance), coverHash: "fixture-\(distance)", visionRevision: 1,
                elementType: 1, elementCount: size, featureData: vector(ones: distance)
            ))
        }
        let query = CoverFeatureQuery(visionRevision: 1, elementType: 1, elementCount: size, featureData: vector(ones: 0))
        let results = try repository.nearestNeighbors(query: query, limit: distances.count)
        #expect(results.map(\.bookID) == distances.map(Int64.init))
        for hit in results {
            #expect(abs(hit.distance - Double(hit.bookID)) < 0.001)
        }

        // These integers are the exact squared lengths constructed above, without sqrt roundoff.
        let book = LibraryBook(title: "Fixture", hash: "fixture", filepath: "/fixture.cbz", type: .archive, status: .correct, date: 0)
        let matches = distances.map { CoverImageSearchMatch(book: book, distance: Double($0)) }
        #expect(matches.filter { $0.confidence == .high }.map(\.distance) == [19, 20])
        #expect(matches.filter { $0.distance <= CoverImageSearchConfiguration.maximumDistance }.map(\.distance) == [19, 20, 21, 119, 120])
    }
}
