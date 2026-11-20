import Foundation

struct WorkCharacterPair: Hashable, Sendable {
    let workID: Tag.DatabaseID
    let characterID: Tag.DatabaseID
}

enum WorkCharacterClaimSource: String, Sendable {
    case manual
    case indexed
    case automatic
}

enum WorkCharacterManualDecision: String, Sendable {
    case confirmed
    case excluded
}

struct WorkCharacterTagAddition: Sendable {
    let book: LibraryBook
    let didChange: Bool
    let isClassified: Bool
}

struct WorkCharacterCandidate: Identifiable, Sendable {
    let character: TagDisplaySummary
    let decision: WorkCharacterManualDecision?
    let hasIndexedEvidence: Bool
    let automaticBookCount: Int

    var id: Tag.DatabaseID { character.id }
}

struct WorkCharacterClaim: Equatable, Sendable {
    let source: WorkCharacterClaimSource
    let evidence: [WorkCharacterPair]
    var evidenceLabels: [String] = []
}

enum WorkCharacterClaimResolver {
    /// Automatic claims are local to one book. They never enter `indexed` or `confirmed`.
    static func resolve(
        works: Set<Tag.DatabaseID>,
        characters: Set<Tag.DatabaseID>,
        confirmed: Set<WorkCharacterPair>,
        excluded: Set<WorkCharacterPair>,
        indexed: Set<WorkCharacterPair>,
        suppressed: Set<WorkCharacterPair>
    ) -> [WorkCharacterPair: WorkCharacterClaim] {
        let reliable = confirmed.union(indexed).subtracting(excluded)
        var claims: [WorkCharacterPair: WorkCharacterClaim] = [:]
        for pair in reliable where works.contains(pair.workID) && characters.contains(pair.characterID) {
            claims[pair] = WorkCharacterClaim(
                source: confirmed.contains(pair) ? .manual : .indexed,
                evidence: []
            )
        }

        let ambiguousCharacters = Set(Dictionary(grouping: claims.keys, by: \.characterID)
            .filter { $0.value.count > 1 }.map(\.key))
        if !ambiguousCharacters.isEmpty {
            claims = claims.filter { !ambiguousCharacters.contains($0.key.characterID) }
        }

        guard works.count > 1, !claims.isEmpty, ambiguousCharacters.isEmpty else { return claims }
        let matchedWorks = Set(claims.keys.map(\.workID))
        let matchedCharacters = Set(claims.keys.map(\.characterID))
        guard works.subtracting(matchedWorks).count == 1,
              characters.subtracting(matchedCharacters).count == 1,
              let remainingWork = works.subtracting(matchedWorks).first,
              let remainingCharacter = characters.subtracting(matchedCharacters).first else {
            return claims
        }
        let candidate = WorkCharacterPair(workID: remainingWork, characterID: remainingCharacter)
        guard !excluded.contains(candidate), !suppressed.contains(candidate),
              // A character known in another work is not safe to eliminate by omission.
              !reliable.contains(where: { $0.characterID == remainingCharacter && $0.workID != remainingWork }),
              !ambiguousCharacters.contains(remainingCharacter) else {
            return claims
        }
        claims[candidate] = WorkCharacterClaim(
            source: .automatic,
            evidence: claims.keys.sorted {
                $0.workID == $1.workID ? $0.characterID < $1.characterID : $0.workID < $1.workID
            }
        )
        return claims
    }
}
