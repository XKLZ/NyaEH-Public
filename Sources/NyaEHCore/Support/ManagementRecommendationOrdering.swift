/// Display-only stable partition. Never changes persisted group order or selection.
enum ManagementRecommendationOrdering {
    static func prioritized<Item>(_ items: [Item], pendingCount: (Item) -> Int) -> [Item] {
        var suggested: [Item] = []
        var remaining: [Item] = []
        for item in items {
            if pendingCount(item) > 0 {
                suggested.append(item)
            } else {
                remaining.append(item)
            }
        }
        return suggested + remaining
    }
}
