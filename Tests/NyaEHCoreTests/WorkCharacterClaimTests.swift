import Testing
@testable import NyaEHCore

struct WorkCharacterClaimTests {
    private func pair(_ work: Int64, _ character: Int64) -> WorkCharacterPair {
        WorkCharacterPair(workID: work, characterID: character)
    }

    @Test("one reliable pair claims the remaining pair on a multi-work book")
    func twoByTwo() {
        let known = pair(1, 11)
        let inferred = pair(2, 12)
        let claims = WorkCharacterClaimResolver.resolve(
            works: [1, 2], characters: [11, 12],
            confirmed: [], excluded: [], indexed: [known], suppressed: []
        )
        #expect(claims[known]?.source == .indexed)
        #expect(claims[inferred]?.source == .automatic)
        #expect(claims[inferred]?.evidence == [known])
    }

    @Test("several reliable relationships can leave exactly one candidate")
    func largerUniqueRemainder() {
        let claims = WorkCharacterClaimResolver.resolve(
            works: [1, 2, 3], characters: [11, 12, 13, 14],
            confirmed: [pair(1, 11)], excluded: [],
            indexed: [pair(1, 12), pair(2, 13)], suppressed: []
        )
        #expect(claims[pair(3, 14)]?.source == .automatic)
        #expect(claims[pair(1, 11)]?.source == .manual)
    }

    @Test("multiple remaining candidates, conflicting known character, and suppression stay unclaimed")
    func ambiguityAndSuppression() {
        let seed = pair(1, 11)
        let ambiguous = WorkCharacterClaimResolver.resolve(
            works: [1, 2], characters: [11, 12, 13],
            confirmed: [seed], excluded: [], indexed: [], suppressed: []
        )
        #expect(ambiguous.count == 1)

        let conflicting = WorkCharacterClaimResolver.resolve(
            works: [1, 2], characters: [11, 12],
            confirmed: [seed], excluded: [], indexed: [pair(3, 12)], suppressed: []
        )
        #expect(conflicting[pair(2, 12)] == nil)

        let suppressed = WorkCharacterClaimResolver.resolve(
            works: [1, 2], characters: [11, 12],
            confirmed: [seed], excluded: [], indexed: [], suppressed: [pair(2, 12)]
        )
        #expect(suppressed[pair(2, 12)] == nil)
    }

    @Test("manual exclusion overrides indexed evidence and automatic claims do not seed another book")
    func sourcePrecedenceAndNoCascade() {
        let known = pair(1, 11)
        let first = WorkCharacterClaimResolver.resolve(
            works: [1, 2], characters: [11, 12],
            confirmed: [], excluded: [], indexed: [known], suppressed: []
        )
        #expect(first[pair(2, 12)]?.source == .automatic)
        let second = WorkCharacterClaimResolver.resolve(
            works: [2, 3], characters: [12, 13],
            confirmed: [], excluded: [], indexed: [known], suppressed: []
        )
        #expect(second.isEmpty)
        let excluded = WorkCharacterClaimResolver.resolve(
            works: [1, 2], characters: [11, 12],
            confirmed: [], excluded: [known], indexed: [known], suppressed: []
        )
        #expect(excluded.isEmpty)
    }

    @Test("one character known in two tagged works stays unclassified in their crossover")
    func sharedCharacterAmbiguity() {
        let claims = WorkCharacterClaimResolver.resolve(
            works: [1, 2], characters: [11],
            confirmed: [pair(1, 11), pair(2, 11)], excluded: [], indexed: [], suppressed: []
        )
        #expect(claims.isEmpty)
    }
}
