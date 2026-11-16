// 本文件封装 Apple NLContextualEmbedding，把 subword 序列稳定地汇聚为本地系列标题向量。

import CryptoKit
import Foundation
import NaturalLanguage

actor ContextualTitleEmbeddingService: ContextualTitleEmbeddingGenerating {
    static let preprocessingVersion = 3
    static let poolingVersion = 1

    private var embedding: NLContextualEmbedding?
    private var isLoaded = false

    func assetState() -> SemanticEmbeddingAssetState {
        guard let embedding = selectedEmbedding() else {
            return .failed(NyaEHError.semanticTitleModelUnavailable.localizedDescription)
        }
        guard embedding.hasAvailableAssets else {
            return .unavailable
        }
        return .available(profile(for: embedding))
    }

    func requestAssets() async throws -> SemanticEmbeddingProfile {
        guard let embedding = selectedEmbedding() else {
            throw NyaEHError.semanticTitleModelUnavailable
        }
        let result = try await embedding.requestAssets()
        guard result == .available, embedding.hasAvailableAssets else {
            throw NyaEHError.semanticTitleAssetsUnavailable
        }
        self.embedding = embedding
        return profile(for: embedding)
    }

    func prepareModel() throws -> SemanticEmbeddingProfile {
        let embedding = try availableEmbedding()
        if !isLoaded {
            try embedding.load()
            isLoaded = true
        }
        return profile(for: embedding)
    }

    func vector(for input: SemanticTitleInput) throws -> SemanticTitleVector {
        let profile = try prepareModel()
        guard let embedding else {
            throw NyaEHError.semanticTitleModelUnavailable
        }
        let language = input.languageCode.map(NLLanguage.init(rawValue:))
        let result = try embedding.embeddingResult(for: input.text, language: language)
        var tokenVectors: [[Double]] = []
        result.enumerateTokenVectors(in: input.text.startIndex..<input.text.endIndex) { vector, _ in
            tokenVectors.append(vector)
            return true
        }
        let normalized = try ContextualTitleVectorMath.meanPooledNormalized(
            tokenVectors,
            expectedDimension: profile.dimension
        )
        return SemanticTitleVector(
            input: input,
            profile: profile,
            featureData: normalized.withUnsafeBytes { Data($0) }
        )
    }

    func unloadModel() {
        embedding?.unload()
        isLoaded = false
    }

    private func selectedEmbedding() -> NLContextualEmbedding? {
        if let embedding {
            return embedding
        }
        let selected = NLContextualEmbedding(language: .japanese)
        embedding = selected
        return selected
    }

    private func availableEmbedding() throws -> NLContextualEmbedding {
        guard let embedding = selectedEmbedding() else {
            throw NyaEHError.semanticTitleModelUnavailable
        }
        guard embedding.hasAvailableAssets else {
            throw NyaEHError.semanticTitleAssetsUnavailable
        }
        return embedding
    }

    private func profile(for embedding: NLContextualEmbedding) -> SemanticEmbeddingProfile {
        SemanticEmbeddingProfile(
            modelIdentifier: embedding.modelIdentifier,
            revision: embedding.revision,
            dimension: embedding.dimension,
            maximumSequenceLength: embedding.maximumSequenceLength,
            preprocessingVersion: Self.preprocessingVersion,
            poolingVersion: Self.poolingVersion
        )
    }
}

enum ContextualTitleVectorMath {
    static func meanPooledNormalized(
        _ tokenVectors: [[Double]],
        expectedDimension: Int
    ) throws -> [Float] {
        guard expectedDimension > 0,
              !tokenVectors.isEmpty,
              tokenVectors.allSatisfy({ $0.count == expectedDimension }) else {
            throw NyaEHError.semanticTitleVectorGenerationFailed
        }
        var mean = Array(repeating: 0.0, count: expectedDimension)
        for vector in tokenVectors {
            for index in mean.indices {
                mean[index] += vector[index]
            }
        }
        let divisor = Double(tokenVectors.count)
        for index in mean.indices {
            mean[index] /= divisor
        }
        let magnitude = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else {
            throw NyaEHError.semanticTitleVectorGenerationFailed
        }
        return mean.map { Float($0 / magnitude) }
    }
}

enum SemanticTitleInputBuilder {
    static func inputs(for book: LibraryBook) -> [SemanticTitleInput] {
        guard let bookID = book.databaseID else {
            return []
        }
        var seen = Set<String>()
        var inputs: [SemanticTitleInput] = []
        let sources: [(SemanticTitleSourceKind, String?)] = [
            (.titleJpn, book.titleJpn),
            (.title, book.title)
        ]
        for (kind, title) in sources {
            guard let title,
                  let analysis = SeriesTitleAnalysis(title: title),
                  analysis.ordinalEvidence != nil || analysis.isCleanUnnumbered else {
                continue
            }
            let text = analysis.semanticStem
            let deduplicationKey = text.folding(
                options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                locale: nil
            )
            guard seen.insert(deduplicationKey).inserted else {
                continue
            }
            let languageCode = languageCode(for: text, sourceKind: kind)
            guard languageCode != nil else {
                continue
            }
            inputs.append(
                SemanticTitleInput(
                    bookID: bookID,
                    sourceKind: kind,
                    text: text,
                    languageCode: languageCode,
                    sourceHash: sourceHash(text: text, sourceKind: kind)
                )
            )
        }
        return inputs
    }

    private static func languageCode(
        for text: String,
        sourceKind: SemanticTitleSourceKind
    ) -> String? {
        if sourceKind == .titleJpn {
            return NLLanguage.japanese.rawValue
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              [.japanese, .simplifiedChinese, .traditionalChinese, .korean].contains(language) else {
            return nil
        }
        return language.rawValue
    }

    private static func sourceHash(text: String, sourceKind: SemanticTitleSourceKind) -> String {
        let source = [
            sourceKind.rawValue,
            String(ContextualTitleEmbeddingService.preprocessingVersion),
            text
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
