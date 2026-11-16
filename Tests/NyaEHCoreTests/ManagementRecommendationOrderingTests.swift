import Testing
@testable import NyaEHCore

struct ManagementRecommendationOrderingTests {
    @Test("series suggestions form a stable partition after search filtering")
    func seriesSearchAndStableOrder() {
        let collections = [
            BookCollection(databaseID: 1, name: "Match first"),
            BookCollection(databaseID: 2, name: "Match second"),
            BookCollection(databaseID: 3, name: "Other"),
            BookCollection(databaseID: 4, name: "Match fourth"),
            BookCollection(databaseID: 5, name: "Match fifth"),
            BookCollection(name: "Match unsaved")
        ]
        let counts: [Int64: Int] = [2: 1, 3: 8, 4: 6]
        let matches = collections.filter { $0.name.hasPrefix("Match") }
        let ordered = ManagementRecommendationOrdering.prioritized(matches) {
            $0.databaseID.flatMap { counts[$0] } ?? 0
        }

        // Counts do not reorder either partition; unsaved groups have no suggestions.
        #expect(ordered.map(\.id) == ["2", "4", "1", "5", "Match unsaved"])
        #expect(collections.map(\.id) == ["1", "2", "3", "4", "5", "Match unsaved"])
    }

    @Test("version suggestion updates restore source order without replacing selected identity")
    func versionCountsChange() {
        let groups = (1...5).map { BookVersionGroup(databaseID: Int64($0)) }
        let selectedID = groups[2].id
        var counts: [Int64: Int] = [2: 1, 4: 3]
        func orderedIDs() -> [String] {
            ManagementRecommendationOrdering.prioritized(groups) {
                $0.databaseID.flatMap { counts[$0] } ?? 0
            }.map(\.id)
        }

        #expect(orderedIDs() == ["2", "4", "1", "3", "5"])
        counts[2] = 0
        counts[3] = 1
        #expect(orderedIDs() == ["3", "4", "1", "2", "5"])
        #expect(orderedIDs().contains(selectedID))
        counts.removeAll()
        #expect(orderedIDs() == groups.map(\.id))
    }

    @Test("empty and uniformly recommended lists preserve source order")
    func unchangedPartitions() {
        #expect(ManagementRecommendationOrdering.prioritized([Int]()) { _ in 1 }.isEmpty)
        let source = [3, 1, 4, 2]
        #expect(ManagementRecommendationOrdering.prioritized(source) { _ in 1 } == source)
        #expect(ManagementRecommendationOrdering.prioritized(source) { _ in 0 } == source)
    }
}
