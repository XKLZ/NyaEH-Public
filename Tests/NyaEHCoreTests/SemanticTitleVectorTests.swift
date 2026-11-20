import Foundation
import GRDB
import Testing
@testable import NyaEHCore

@Suite("semantic title vectors")
struct SemanticTitleVectorTests {
    @Test("mean pools and L2 normalizes contextual token vectors")
    func meanPoolsAndNormalizes() throws {
        let values = try ContextualTitleVectorMath.meanPooledNormalized(
            [[1, 0, 0], [1, 2, 0]],
            expectedDimension: 3
        )

        #expect(values.count == 3)
        #expect(abs(values[0] - Float(1 / sqrt(2.0))) < 0.0001)
        #expect(abs(values[1] - Float(1 / sqrt(2.0))) < 0.0001)
        #expect(values[2] == 0)
    }

    @Test("empty or malformed contextual output is rejected")
    func rejectsMalformedTokenVectors() {
        #expect(throws: NyaEHError.self) {
            _ = try ContextualTitleVectorMath.meanPooledNormalized([], expectedDimension: 3)
        }
        #expect(throws: NyaEHError.self) {
            _ = try ContextualTitleVectorMath.meanPooledNormalized([[1, 2]], expectedDimension: 3)
        }
    }

    @Test("generation activation is atomic and nearest-neighbor queries stay in candidate scope")
    func generationAndNearestNeighbors() throws {
        let repository = try makeRepository()
        let profile = profile(dimension: 4)
        let firstGeneration = try repository.beginGeneration(profile: profile)
        try repository.upsertVector(
            vector(bookID: 1, values: [1, 0, 0, 0], profile: profile),
            generationID: firstGeneration
        )
        try repository.upsertVector(
            vector(bookID: 2, values: [0.98, 0.2, 0, 0], profile: profile),
            generationID: firstGeneration
        )
        try repository.upsertVector(
            vector(bookID: 3, values: [0, 1, 0, 0], profile: profile),
            generationID: firstGeneration
        )

        #expect(try repository.indexedBookIDs().isEmpty)
        try repository.activateGeneration(firstGeneration)

        let neighbors = try repository.nearestNeighbors(bookID: 1, among: [1, 2], limit: 3)
        #expect(neighbors.map(\.bookID) == [2])
        #expect(neighbors[0].distance < 0.1)

        let secondGeneration = try repository.beginGeneration(profile: profile)
        try repository.upsertVector(
            vector(bookID: 4, values: [1, 0, 0, 0], profile: profile),
            generationID: secondGeneration
        )
        try repository.discardGeneration(secondGeneration)

        #expect(try repository.indexedBookIDs() == [1, 2, 3])
        #expect(try repository.activeProfile() == profile)

        let replacementGeneration = try repository.beginGeneration(profile: profile)
        try repository.upsertVector(
            vector(bookID: 4, values: [1, 0, 0, 0], profile: profile),
            generationID: replacementGeneration
        )
        try repository.activateGeneration(replacementGeneration)

        #expect(try repository.indexedBookIDs() == [4])
        #expect(try repository.storedVectorCount() == 1)
    }

    @Test("input hashes change with source text and duplicate title variants are removed")
    func inputHashAndDeduplication() throws {
        let duplicate = LibraryBook(
            databaseID: 10,
            title: "秘封陵辱 Vol.2",
            hash: "hash",
            filepath: "/tmp/book.cbz",
            titleJpn: "秘封陵辱 Vol.2"
        )
        let changed = LibraryBook(
            databaseID: 10,
            title: "東方陵辱 Vol.3",
            hash: "hash",
            filepath: "/tmp/book.cbz"
        )

        let duplicateInputs = SemanticTitleInputBuilder.inputs(for: duplicate)
        let changedInput = try #require(SemanticTitleInputBuilder.inputs(for: changed).first)

        #expect(duplicateInputs.count == 1)
        #expect(duplicateInputs[0].text == "秘封陵辱")
        #expect(duplicateInputs[0].sourceHash != changedInput.sourceHash)
    }

    @Test("preprocessing v3 indexes clean unnumbered titles and invalidates v2 profiles")
    func preprocessingV3IndexesUnnumberedTitles() throws {
        let unnumbered = LibraryBook(
            databaseID: 11,
            title: "愛奴陵辱",
            hash: "unnumbered",
            filepath: "/tmp/unnumbered.cbz",
            titleJpn: "愛奴陵辱"
        )
        let special = LibraryBook(
            databaseID: 12,
            title: "愛奴陵辱 総集編",
            hash: "special",
            filepath: "/tmp/special.cbz"
        )

        let inputs = SemanticTitleInputBuilder.inputs(for: unnumbered)
        #expect(inputs.count == 1)
        #expect(inputs[0].text == "愛奴陵辱")
        #expect(SemanticTitleInputBuilder.inputs(for: special).isEmpty)
        #expect(ContextualTitleEmbeddingService.preprocessingVersion == 3)

        let v2 = SemanticEmbeddingProfile(
            modelIdentifier: "test-cjk",
            revision: 1,
            dimension: 512,
            maximumSequenceLength: 256,
            preprocessingVersion: 2,
            poolingVersion: 1
        )
        let v3 = SemanticEmbeddingProfile(
            modelIdentifier: "test-cjk",
            revision: 1,
            dimension: 512,
            maximumSequenceLength: 256,
            preprocessingVersion: 3,
            poolingVersion: 1
        )
        #expect(!SemanticSeriesConfiguration.diagnostic.supports(v2))
        #expect(SemanticSeriesConfiguration.diagnostic.supports(v3))
        #expect(SemanticSeriesConfiguration.precisionFirst.supports(v3))
        #expect(SemanticSeriesConfiguration.precisionFirst.maximumSquaredDistance == 0.2767)
        #expect(SemanticSeriesConfiguration.precisionFirst.mutualNeighborLimit == 3)
    }

    @Test("development builder creates an active index when the source cache is missing")
    func developmentBuilderCreatesMissingIndex() async throws {
        let repository = try makeRepository()
        let profile = profile(dimension: 4)
        let service = SemanticTitleVectorIndexService(
            repository: repository,
            generator: StubContextualTitleEmbeddingGenerator(profile: profile)
        )
        let books = [
            LibraryBook(
                databaseID: 1,
                title: "作品 Vol.1",
                hash: "one",
                filepath: "/tmp/one.cbz"
            ),
            LibraryBook(
                databaseID: 2,
                title: "作品 Vol.2",
                hash: "two",
                filepath: "/tmp/two.cbz"
            )
        ]

        let stats = try await service.rebuild(
            books: books,
            phase: "test",
            progress: { _ in }
        )

        #expect(stats.activeProfile == profile)
        #expect(stats.vectorCount == 2)
        #expect(stats.failureCount == 0)
        #expect(stats.missingCount == 0)
        #expect(try repository.indexedBookIDs() == [1, 2])
    }

    @Test("development builder failure leaves no active generation")
    func developmentBuilderFailureLeavesNoActiveGeneration() async throws {
        let repository = try makeRepository()
        let service = SemanticTitleVectorIndexService(
            repository: repository,
            generator: StubContextualTitleEmbeddingGenerator(
                profile: profile(dimension: 4),
                failsPreparation: true
            )
        )
        let book = LibraryBook(
            databaseID: 1,
            title: "作品 Vol.1",
            hash: "one",
            filepath: "/tmp/one.cbz"
        )

        do {
            _ = try await service.rebuild(
                books: [book],
                phase: "test",
                progress: { _ in }
            )
            Issue.record("Expected semantic model preparation to fail.")
        } catch {
            #expect(error is StubContextualTitleEmbeddingError)
        }

        #expect(try repository.activeGenerationID() == nil)
        #expect(try repository.storedVectorCount() == 0)
    }

    @Test("opt-in on-device semantic series calibration report")
    func semanticSeriesCalibrationReport() throws {
        guard ProcessInfo.processInfo.environment["NYAEH_RUN_SEMANTIC_SERIES_TESTS"] == "1" else {
            return
        }
        let root = ProcessInfo.processInfo.environment["NYAEH_SEMANTIC_SERIES_APP_SUPPORT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".nyaeh-dev/Application Support/NyaEH", isDirectory: true)
        let libraryURL = root.appendingPathComponent("NyaEH.sqlite")
        let vectorsURL = root.appendingPathComponent("SemanticTitleVectors.sqlite")
        guard FileManager.default.fileExists(atPath: libraryURL.path),
              FileManager.default.fileExists(atPath: vectorsURL.path) else {
            print("Build the semantic title index before running calibration: \(root.path)")
            Issue.record("Semantic series calibration cache is missing.")
            return
        }

        let database = try DatabaseQueue(path: libraryURL.path)
        let bookRepository = SQLiteLibraryBookRepository(dbQueue: database)
        let vectorRepository = try SQLiteSemanticTitleVectorRepository(path: vectorsURL.path)
        let indexedIDs = try vectorRepository.indexedBookIDs()
        guard !indexedIDs.isEmpty else {
            Issue.record("Semantic series calibration requires a nonempty active vector generation.")
            return
        }
        let service = CollectionRecommendationService(
            bookRepository: bookRepository,
            recommendationRepository: SQLiteCollectionRecommendationRepository(dbQueue: database),
            semanticVectorSearch: vectorRepository
        )
        let features = try service.recommendationFeatures()
        let featureByID: [LibraryBook.DatabaseID: CollectionBookFeature] = Dictionary(
            uniqueKeysWithValues: features.map { feature in (feature.id, feature) }
        )
        var ranks: [LibraryBook.DatabaseID: [SemanticTitleVectorNeighbor]] = [:]
        for feature in features where indexedIDs.contains(feature.id) {
            let scope = Set(features.filter { feature.sharesCreator(with: $0) }.map { $0.id })
            ranks[feature.id] = try vectorRepository.nearestNeighbors(
                bookID: feature.id,
                among: scope,
                limit: 5
            )
        }

        let positives = features.filter { $0.book.collectionID != nil }
        guard !positives.isEmpty else {
            Issue.record("Semantic series calibration requires curated collection members.")
            return
        }
        func recall(at limit: Int) -> Double {
            let hits = positives.count { feature in
                ranks[feature.id, default: []].prefix(limit).contains { neighbor in
                    featureByID[neighbor.bookID]?.book.collectionID == feature.book.collectionID
                }
            }
            return positives.isEmpty ? 0 : Double(hits) / Double(positives.count)
        }
        let crossLanguagePositives = positives.filter { feature in
            feature.book.titleJpn.map {
                !$0.isEmpty
                    && $0.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
                    != feature.book.title.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            } ?? false
        }
        let crossLanguageHits = crossLanguagePositives.count { feature in
            ranks[feature.id, default: []].prefix(3).contains { neighbor in
                featureByID[neighbor.bookID]?.book.collectionID == feature.book.collectionID
            }
        }
        let crossLanguageRecall = crossLanguagePositives.isEmpty
            ? 0
            : Double(crossLanguageHits) / Double(crossLanguagePositives.count)

        let diagnostics = try service.semanticEdgeDiagnostics()
        let predictions = diagnostics.filter(\.isAccepted)
        let labeledPredictions = predictions.compactMap { edge -> (CollectionSemanticEdgeDiagnostic, Bool)? in
            guard let lhs = featureByID[edge.lhsBookID],
                  let rhs = featureByID[edge.rhsBookID],
                  let leftCollectionID = lhs.book.collectionID,
                  let rightCollectionID = rhs.book.collectionID else {
                return nil
            }
            return (edge, leftCollectionID == rightCollectionID)
        }
        let truePositives = labeledPredictions.count { $0.1 }
        let falsePairs = labeledPredictions.filter { !$0.1 }.map(\.0)
        let unknownCount = predictions.count - labeledPredictions.count
        let precision = labeledPredictions.isEmpty
            ? 1
            : Double(truePositives) / Double(labeledPredictions.count)
        guard !predictions.isEmpty else {
            Issue.record("No mutual Top-3 predictions were available for threshold validation.")
            return
        }
        let hardNegativeCount = features.enumerated().reduce(into: 0) { count, entry in
                let (offset, lhs) = entry
                for rhs in features.dropFirst(offset + 1)
                    where lhs.sharesCreator(with: rhs)
                    && lhs.book.collectionID != nil
                    && rhs.book.collectionID != nil
                    && lhs.book.collectionID != rhs.book.collectionID
                    && (lhs.category == nil || rhs.category == nil || lhs.category == rhs.category)
                    && lhs.ordinalKey != rhs.ordinalKey {
                    count += 1
                }
            }
        let falsePositiveRate = hardNegativeCount == 0
            ? 0
            : Double(falsePairs.count) / Double(hardNegativeCount)

        print("""
            Semantic series calibration
            Indexed books: \(indexedIDs.count)
            Curated collection members: \(positives.count)
            Recall@1: \(String(format: "%.3f", recall(at: 1)))
            Recall@3: \(String(format: "%.3f", recall(at: 3)))
            Recall@5: \(String(format: "%.3f", recall(at: 5)))
            Cross-language Recall@3: \(String(format: "%.3f", crossLanguageRecall)) (\(crossLanguagePositives.count) samples)
            Mutual Top-3 accepted predictions: \(predictions.count)
            Labeled predictions: \(labeledPredictions.count)
            Unknown predictions excluded from precision/FPR: \(unknownCount)
            Labeled precision: \(String(format: "%.3f", precision))
            Hard-negative false-positive rate: \(String(format: "%.3f", falsePositiveRate))
            Explicit false positives: \(falsePairs.count)
            """)
        for edge in falsePairs.prefix(20) {
            print(
                "FALSE\t\(featureByID[edge.lhsBookID]?.book.title ?? "")"
                    + "\t<->\t\(featureByID[edge.rhsBookID]?.book.title ?? "")"
            )
        }
        #expect(precision >= 0.98)
        #expect(falsePositiveRate <= 0.01)
    }

    private func makeRepository() throws -> SQLiteSemanticTitleVectorRepository {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteSemanticTitleVectorRepository(
            path: directory.appendingPathComponent("SemanticTitleVectors.sqlite").path
        )
    }

    private func profile(dimension: Int) -> SemanticEmbeddingProfile {
        SemanticEmbeddingProfile(
            modelIdentifier: "test-cjk",
            revision: 1,
            dimension: dimension,
            maximumSequenceLength: 256,
            preprocessingVersion: ContextualTitleEmbeddingService.preprocessingVersion,
            poolingVersion: 1
        )
    }

    private func vector(
        bookID: LibraryBook.DatabaseID,
        values: [Float],
        profile: SemanticEmbeddingProfile
    ) -> SemanticTitleVector {
        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        let normalized = values.map { $0 / magnitude }
        let input = SemanticTitleInput(
            bookID: bookID,
            sourceKind: .titleJpn,
            text: "series \(bookID)",
            languageCode: "ja",
            sourceHash: "hash-\(bookID)"
        )
        return SemanticTitleVector(
            input: input,
            profile: profile,
            featureData: normalized.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }
}

private enum StubContextualTitleEmbeddingError: Error {
    case preparationFailed
}

private actor StubContextualTitleEmbeddingGenerator: ContextualTitleEmbeddingGenerating {
    let profile: SemanticEmbeddingProfile
    let failsPreparation: Bool

    init(profile: SemanticEmbeddingProfile, failsPreparation: Bool = false) {
        self.profile = profile
        self.failsPreparation = failsPreparation
    }

    func assetState() -> SemanticEmbeddingAssetState {
        .available(profile)
    }

    func requestAssets() throws -> SemanticEmbeddingProfile {
        profile
    }

    func prepareModel() throws -> SemanticEmbeddingProfile {
        if failsPreparation {
            throw StubContextualTitleEmbeddingError.preparationFailed
        }
        return profile
    }

    func vector(for input: SemanticTitleInput) throws -> SemanticTitleVector {
        var values = [Float](repeating: 0, count: profile.dimension)
        values[Int(input.bookID) % profile.dimension] = 1
        return SemanticTitleVector(
            input: input,
            profile: profile,
            featureData: values.withUnsafeBytes { Data($0) }
        )
    }

    func unloadModel() {}
}
