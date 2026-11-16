// 本文件协调系统上下文模型与可重建标题向量缓存，完整重建使用 generation 原子切换。

import Foundation

struct SemanticTitleVectorIndexService: Sendable {
    let repository: SemanticTitleVectorRepository
    let generator: ContextualTitleEmbeddingGenerating

    func assetState() async -> SemanticEmbeddingAssetState {
        await generator.assetState()
    }

    func requestAssets() async throws -> SemanticEmbeddingProfile {
        try await generator.requestAssets()
    }

    func stats(for books: [LibraryBook]) async throws -> SemanticTitleVectorIndexStats {
        let assetState = await generator.assetState()
        let eligible = eligibleBooks(books)
        let activeProfile = try repository.activeProfile()
        var missing = 0
        var stale = 0
        for book in eligible {
            guard let bookID = book.databaseID else {
                continue
            }
            let inputs = SemanticTitleInputBuilder.inputs(for: book)
            let entries = try repository.activeEntries(bookID: bookID)
            if entries.isEmpty {
                missing += 1
            } else if isStale(entries: entries, inputs: inputs) {
                stale += 1
            }
        }
        return SemanticTitleVectorIndexStats(
            assetState: assetState,
            vectorCount: try repository.storedVectorCount(),
            failureCount: try repository.storedFailureCount(),
            missingCount: missing,
            staleCount: stale,
            eligibleBookCount: eligible.count,
            activeProfile: activeProfile
        )
    }

    func rebuild(
        books: [LibraryBook],
        phase: String,
        progress: @escaping @Sendable (SemanticTitleVectorIndexProgress) -> Void
    ) async throws -> SemanticTitleVectorIndexStats {
        let profile = try await generator.prepareModel()
        let generationID = try repository.beginGeneration(profile: profile)
        do {
            let eligible = eligibleBooks(books)
            try await index(
                books: eligible,
                profile: profile,
                generationID: generationID,
                phase: phase,
                progress: progress,
                replacesExistingEntries: false
            )
            try Task.checkCancellation()
            try repository.activateGeneration(generationID)
            _ = try repository.pruneOrphanedVectors(existingBookIDs: Set(books.compactMap(\.databaseID)))
            await generator.unloadModel()
            return try await stats(for: books)
        } catch {
            try? repository.discardGeneration(generationID)
            await generator.unloadModel()
            throw error
        }
    }

    func updateMissingOrStale(
        books: [LibraryBook],
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        phase: String,
        progress: @escaping @Sendable (SemanticTitleVectorIndexProgress) -> Void
    ) async throws -> SemanticTitleVectorIndexStats {
        let profile = try await generator.prepareModel()
        guard let generationID = try repository.activeGenerationID(),
              try repository.activeProfile() == profile else {
            return try await rebuild(books: books, phase: phase, progress: progress)
        }
        var targets: [LibraryBook] = []
        for book in eligibleBooks(books) {
            guard let bookID = book.databaseID,
                  focusBookIDs.isEmpty || focusBookIDs.contains(bookID) else {
                continue
            }
            let inputs = SemanticTitleInputBuilder.inputs(for: book)
            let entries = try repository.activeEntries(bookID: bookID)
            if entries.isEmpty || isStale(entries: entries, inputs: inputs) {
                targets.append(book)
            }
        }
        try await index(
            books: targets,
            profile: profile,
            generationID: generationID,
            phase: phase,
            progress: progress,
            replacesExistingEntries: true
        )
        _ = try repository.pruneOrphanedVectors(existingBookIDs: Set(books.compactMap(\.databaseID)))
        await generator.unloadModel()
        return try await stats(for: books)
    }

    func clear() throws {
        try repository.clear()
    }

    private func index(
        books: [LibraryBook],
        profile: SemanticEmbeddingProfile,
        generationID: Int64,
        phase: String,
        progress: @escaping @Sendable (SemanticTitleVectorIndexProgress) -> Void,
        replacesExistingEntries: Bool
    ) async throws {
        var completed = 0
        var failed = 0
        progress(.init(phase: phase, completed: 0, total: max(books.count, 1), failed: 0))
        for book in books {
            try Task.checkCancellation()
            guard let bookID = book.databaseID else {
                continue
            }
            if replacesExistingEntries {
                try repository.deleteEntries(bookID: bookID, generationID: generationID)
            }
            for input in SemanticTitleInputBuilder.inputs(for: book) {
                do {
                    let vector = try await generator.vector(for: input)
                    guard vector.profile == profile else {
                        throw NyaEHError.semanticTitleSchemaMismatch
                    }
                    try repository.upsertVector(vector, generationID: generationID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed += 1
                    try repository.markFailure(
                        input: input,
                        profile: profile,
                        generationID: generationID,
                        message: error.localizedDescription
                    )
                }
            }
            completed += 1
            progress(.init(
                phase: phase,
                completed: completed,
                total: max(books.count, 1),
                failed: failed
            ))
        }
    }

    private func eligibleBooks(_ books: [LibraryBook]) -> [LibraryBook] {
        books.filter {
            $0.databaseID != nil
                && $0.exist
                && $0.isPrimaryVersion
                && !SemanticTitleInputBuilder.inputs(for: $0).isEmpty
        }
    }

    private func isStale(
        entries: [SemanticTitleVectorEntry],
        inputs: [SemanticTitleInput]
    ) -> Bool {
        let current = Dictionary(uniqueKeysWithValues: inputs.map { ($0.sourceKind, $0.sourceHash) })
        let stored = Dictionary(uniqueKeysWithValues: entries.map { ($0.sourceKind, $0.sourceHash) })
        return current != stored || entries.contains { $0.featureData == nil }
    }
}
