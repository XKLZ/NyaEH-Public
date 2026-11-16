// 本文件把封面图片转换成 Vision feature print，供可重建的封面相似度缓存使用。

import AppKit
import Foundation
import Vision

protocol CoverFeaturePrintGenerating: Sendable {
    var visionRevision: Int { get }
    func featureVector(for book: LibraryBook) throws -> CoverFeatureVector
}

protocol CoverFeatureQueryGenerating: Sendable {
    var visionRevision: Int { get }
    func featureQuery(forImageData data: Data) throws -> CoverFeatureQuery
}

struct CoverFeaturePrintService: CoverFeaturePrintGenerating, CoverFeatureQueryGenerating {
    let visionRevision: Int

    init(visionRevision: Int = Int(VNGenerateImageFeaturePrintRequestRevision1)) {
        self.visionRevision = visionRevision
    }

    func featureVector(for book: LibraryBook) throws -> CoverFeatureVector {
        guard let bookID = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }
        guard let coverHash = nonEmptyString(book.coverHash),
              let coverPath = nonEmptyString(book.coverPath) else {
            throw NyaEHError.coverVectorCoverMissing
        }
        let coverURL = URL(fileURLWithPath: coverPath)
        guard FileManager.default.fileExists(atPath: coverURL.path) else {
            throw NyaEHError.coverVectorCoverMissing
        }

        let query = try featureQuery(handler: VNImageRequestHandler(url: coverURL, options: [:]))

        return CoverFeatureVector(
            bookID: bookID,
            coverHash: coverHash,
            visionRevision: query.visionRevision,
            elementType: query.elementType,
            elementCount: query.elementCount,
            featureData: query.featureData
        )
    }

    func featureQuery(forImageData data: Data) throws -> CoverFeatureQuery {
        guard !data.isEmpty else {
            throw NyaEHError.coverVectorGenerationFailed
        }
        return try featureQuery(handler: VNImageRequestHandler(data: data, options: [:]))
    }

    private func featureQuery(handler: VNImageRequestHandler) throws -> CoverFeatureQuery {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = visionRevision
        request.imageCropAndScaleOption = .scaleFit
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw NyaEHError.coverVectorGenerationFailed
        }

        let featureData = observation.data
        let elementSize = VNElementTypeSize(observation.elementType)
        guard elementSize == MemoryLayout<Float>.size,
              featureData.count == observation.elementCount * MemoryLayout<Float>.size else {
            throw NyaEHError.coverVectorElementTypeUnsupported
        }

        return CoverFeatureQuery(
            visionRevision: visionRevision,
            elementType: Int(observation.elementType.rawValue),
            elementCount: observation.elementCount,
            featureData: featureData
        )
    }
}

struct CoverVectorIndexService: @unchecked Sendable {
    let repository: CoverVectorRepository
    let featureGenerator: CoverFeaturePrintGenerating

    func stats(for books: [LibraryBook]) throws -> CoverVectorIndexStats {
        let eligible = eligibleBooks(books)
        var missing = 0
        var stale = 0
        for book in eligible {
            guard let bookID = book.databaseID else {
                continue
            }
            guard let entry = try repository.fetchEntry(bookID: bookID),
                  entry.featureData != nil else {
                missing += 1
                continue
            }
            if isStale(entry, for: book) {
                stale += 1
            }
        }
        return CoverVectorIndexStats(
            vectorCount: try repository.storedVectorCount(),
            failureCount: try repository.storedFailureCount(),
            missingCount: missing,
            staleCount: stale,
            totalBooksWithCovers: eligible.count
        )
    }

    func rebuild(
        books: [LibraryBook],
        phase: String,
        progress: @escaping @Sendable (CoverVectorIndexProgress) -> Void
    ) throws -> CoverVectorIndexStats {
        pruneOrphanedVectors(for: books)
        try repository.clear()
        let stats = try index(
            books: eligibleBooks(books),
            phase: phase,
            progress: progress
        )
        pruneOrphanedVectors(for: books)
        return stats
    }

    func updateMissingOrStale(
        books: [LibraryBook],
        phase: String,
        progress: @escaping @Sendable (CoverVectorIndexProgress) -> Void
    ) throws -> CoverVectorIndexStats {
        pruneOrphanedVectors(for: books)
        var targets: [LibraryBook] = []
        for book in eligibleBooks(books) {
            guard let bookID = book.databaseID else {
                continue
            }
            guard let entry = try repository.fetchEntry(bookID: bookID),
                  entry.featureData != nil,
                  !isStale(entry, for: book) else {
                targets.append(book)
                continue
            }
        }
        let stats = try index(books: targets, phase: phase, progress: progress)
        pruneOrphanedVectors(for: books)
        return stats
    }

    func clear() throws {
        try repository.clear()
    }

    func distanceReport(
        books: [LibraryBook],
        referenceThreshold: Double,
        thresholds: [Double] = [4, 12, 20, 40, 80, 120, 160, 200, 240, 300],
        nearestLimit: Int = 3,
        pairLimit: Int = 40
    ) throws -> String {
        let indexedIDs = try repository.indexedBookIDs()
        let booksByID = Dictionary(
            uniqueKeysWithValues: books.compactMap { book -> (LibraryBook.DatabaseID, LibraryBook)? in
                guard let id = book.databaseID, indexedIDs.contains(id) else {
                    return nil
                }
                return (id, book)
            }
        )
        let ids = booksByID.keys.sorted()
        guard ids.count >= 2 else {
            return "Cover distance report\nIndexed books: \(ids.count)\nNot enough indexed covers to compare."
        }

        var pairs: [CoverDistancePair: Double] = [:]
        let queryLimit = max(ids.count - 1, nearestLimit)
        for id in ids {
            let neighbors = try repository.nearestNeighbors(bookID: id, limit: queryLimit)
            for neighbor in neighbors where booksByID[neighbor.bookID] != nil {
                let pair = CoverDistancePair(id, neighbor.bookID)
                pairs[pair] = min(pairs[pair] ?? neighbor.distance, neighbor.distance)
            }
        }

        let sortedPairs = pairs
            .map { (pair: $0.key, distance: $0.value) }
            .sorted { lhs, rhs in
                if lhs.distance == rhs.distance {
                    return lhs.pair.lhs < rhs.pair.lhs
                }
                return lhs.distance < rhs.distance
            }
        let distances = sortedPairs.map(\.distance)
        let suggestedThreshold = Self.suggestedDistanceThreshold(distances: distances)

        var lines: [String] = []
        lines.append("Cover distance report")
        lines.append("Indexed books: \(ids.count)")
        lines.append("Pair count: \(sortedPairs.count)")
        lines.append("Reference threshold: \(Self.distanceText(referenceThreshold))")
        lines.append("Preset thresholds: strict 12.00 (L2 3.46), balanced 20.00 (L2 4.47), loose 40.00 (L2 6.32)")
        if let suggestedThreshold {
            lines.append("Suggested threshold: \(Self.distanceText(suggestedThreshold))")
        }

        lines.append("")
        lines.append("Threshold counts (squared distance)")
        for threshold in thresholds.sorted() {
            let count = distances.filter { $0 <= threshold }.count
            lines.append("<= \(Self.distanceText(threshold)): \(count)")
        }

        lines.append("")
        lines.append("Nearest pairs (distanceSquared / distanceL2)")
        for entry in sortedPairs.prefix(pairLimit) {
            lines.append(
                "\(Self.distanceText(entry.distance))  \(Self.bookLabel(booksByID[entry.pair.lhs]))  <->  \(Self.bookLabel(booksByID[entry.pair.rhs]))"
            )
        }

        lines.append("")
        lines.append("Nearest per book")
        for id in ids {
            let nearest = sortedPairs
                .filter { $0.pair.lhs == id || $0.pair.rhs == id }
                .prefix(nearestLimit)
                .map { entry -> String in
                    let otherID = entry.pair.lhs == id ? entry.pair.rhs : entry.pair.lhs
                    return "\(Self.bookLabel(booksByID[otherID])):\(Self.distanceText(entry.distance))"
                }
                .joined(separator: ", ")
            lines.append("\(Self.bookLabel(booksByID[id])) -> \(nearest)")
        }

        return lines.joined(separator: "\n")
    }

    private func index(
        books: [LibraryBook],
        phase: String,
        progress: @escaping @Sendable (CoverVectorIndexProgress) -> Void
    ) throws -> CoverVectorIndexStats {
        var failed = 0
        progress(CoverVectorIndexProgress(phase: phase, completed: 0, total: max(books.count, 1), failed: 0))
        for (index, book) in books.enumerated() {
            guard let bookID = book.databaseID else {
                continue
            }
            do {
                let vector = try featureGenerator.featureVector(for: book)
                try repository.upsertVector(vector)
            } catch {
                failed += 1
                try repository.markFailure(
                    bookID: bookID,
                    coverHash: book.coverHash,
                    message: error.localizedDescription
                )
            }
            progress(CoverVectorIndexProgress(phase: phase, completed: index + 1, total: max(books.count, 1), failed: failed))
            if Task.isCancelled {
                break
            }
        }
        return try stats(for: books)
    }

    private func eligibleBooks(_ books: [LibraryBook]) -> [LibraryBook] {
        books.filter { book in
            book.databaseID != nil
                && book.exist
                && nonEmptyString(book.coverPath) != nil
                && nonEmptyString(book.coverHash) != nil
        }
    }

    private func pruneOrphanedVectors(for books: [LibraryBook]) {
        let existingBookIDs = Set(books.compactMap(\.databaseID))
        _ = try? repository.pruneOrphanedVectors(existingBookIDs: existingBookIDs)
    }

    private func isStale(_ entry: CoverVectorEntry, for book: LibraryBook) -> Bool {
        entry.coverHash != book.coverHash
            || entry.visionRevision != featureGenerator.visionRevision
            || entry.featureData == nil
    }

    private static func suggestedDistanceThreshold(distances: [Double]) -> Double? {
        guard distances.count >= 2 else {
            return distances.first
        }
        let searchCount = min(distances.count - 1, 50)
        var bestIndex = 0
        var bestGap = distances[1] - distances[0]
        for index in 1..<searchCount {
            let gap = distances[index + 1] - distances[index]
            if gap > bestGap {
                bestGap = gap
                bestIndex = index
            }
        }
        return ceil(distances[bestIndex])
    }

    private static func bookLabel(_ book: LibraryBook?) -> String {
        guard let book else {
            return "unknown"
        }
        let id = book.databaseID.map(String.init) ?? "?"
        let hash = String(book.hash.prefix(8))
        let title = BookTitleFormatter.compactTitle(book.title)
        return "#\(id) \(hash) \(title)"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func distanceText(_ value: Double) -> String {
        "\(format(value)) (L2 \(format(sqrt(max(value, 0)))))"
    }
}

private struct CoverDistancePair: Hashable {
    var lhs: LibraryBook.DatabaseID
    var rhs: LibraryBook.DatabaseID

    init(_ lhs: LibraryBook.DatabaseID, _ rhs: LibraryBook.DatabaseID) {
        self.lhs = min(lhs, rhs)
        self.rhs = max(lhs, rhs)
    }
}

private func nonEmptyString(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
