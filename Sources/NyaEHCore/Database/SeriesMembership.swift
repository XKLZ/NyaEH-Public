import GRDB

/// A standalone book or all the members of a version group occupy one series slot.
enum SeriesMembership {
    struct Member {
        let id: Int64
        let groupID: Int64?
        let collectionID: Int64?
        let order: Int?
        let isPrimary: Bool
        let isHidden: Bool

        init(_ row: Row) {
            id = row["id"]
            groupID = row["version_group_id"]
            collectionID = row["collection_id"]
            order = row["collection_order"]
            isPrimary = row["is_primary_version"]
            isHidden = row["hidden_book"]
        }
    }

    private static let columns = "id, version_group_id, collection_id, collection_order, is_primary_version, hidden_book"

    static func member(_ db: Database, id: Int64) throws -> Member {
        guard let row = try Row.fetchOne(db, sql: "SELECT \(columns) FROM library_books WHERE id = ?", arguments: [id]) else {
            throw LibraryDeletionError.bookUnavailable
        }
        return Member(row)
    }

    static func members(_ db: Database, bookID: Int64) throws -> [Member] {
        let book = try member(db, id: bookID)
        return try book.groupID.map { try members(db, groupID: $0) } ?? [book]
    }

    static func members(_ db: Database, groupID: Int64) throws -> [Member] {
        try Row.fetchAll(db, sql: "SELECT \(columns) FROM library_books WHERE version_group_id = ? ORDER BY id",
                         arguments: [groupID]).map(Member.init)
    }

    static func uniqueCollection(_ members: [Member]) throws -> Int64? {
        let collections = Set(members.compactMap(\.collectionID))
        guard collections.count <= 1 else { throw NyaEHError.versionSeriesConflict }
        return collections.first
    }

    static func existingOrder(in collectionID: Int64, members: [Member]) -> Int? {
        let assigned = members.filter { $0.collectionID == collectionID }
        return assigned.first(where: \.isPrimary)?.order ?? assigned.compactMap(\.order).min()
    }

    static func nextOrder(_ db: Database, collectionID: Int64) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(collection_order) FROM library_books WHERE collection_id = ?",
                          arguments: [collectionID]) ?? -1) + 1
    }

    static func write(_ db: Database, members: [Member], collectionID: Int64?, order: Int?) throws {
        let now = Timestamp.nowMilliseconds()
        for member in members {
            let hidden = collectionID != nil || (member.groupID != nil && !member.isPrimary)
            guard member.collectionID != collectionID || member.order != order || member.isHidden != hidden else { continue }
            try db.execute(sql: """
                UPDATE library_books SET collection_id = ?, collection_order = ?, hidden_book = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [collectionID, order, hidden, now, member.id])
            if collectionID != nil && member.collectionID != collectionID {
                try db.execute(sql: """
                    UPDATE collection_recommendations SET status = 'stale', updated_at = ?
                    WHERE status = 'pending' AND id IN (
                        SELECT recommendation_id FROM collection_recommendation_members WHERE book_id = ?
                    )
                    """, arguments: [now, member.id])
            }
        }
    }

    static func assign(_ db: Database, members: [Member], to collectionID: Int64, order: Int? = nil) throws {
        let resolvedOrder = try order ?? existingOrder(in: collectionID, members: members) ?? nextOrder(db, collectionID: collectionID)
        try write(db, members: members, collectionID: collectionID, order: resolvedOrder)
    }

    static func reconcile(_ db: Database, members: [Member]) throws {
        if let collectionID = try uniqueCollection(members) {
            try assign(db, members: members, to: collectionID)
        } else {
            try write(db, members: members, collectionID: nil, order: nil)
        }
    }

    static func replaceOrder(_ db: Database, bookIDs: [Int64], collectionID: Int64) throws {
        var seen = Set<Int64>()
        var order = 0
        for bookID in bookIDs where !seen.contains(bookID) {
            // A queued reorder may reference a book that has since left the series.
            guard try Int64.fetchOne(db, sql: "SELECT id FROM library_books WHERE id = ? AND collection_id = ?",
                                    arguments: [bookID, collectionID]) != nil else { continue }
            let members = try members(db, bookID: bookID)
            guard try uniqueCollection(members) == collectionID else { continue }
            try assign(db, members: members, to: collectionID, order: order)
            seen.formUnion(members.map(\.id))
            order += 1
        }
    }

    private struct Difference {
        let groupID: Int64
        let members: [Member]
        let collectionIDs: [Int64]
    }

    private static func differences(_ db: Database) throws -> (groups: [Difference], names: [Int64: String]) {
        let names = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, name FROM book_collections")
            .map { ($0["id"] as Int64, $0["name"] as String) })
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(columns) FROM library_books WHERE version_group_id IN (SELECT id FROM book_version_groups)
            ORDER BY id
            """)
        let grouped = Dictionary(grouping: rows.map(Member.init), by: \.groupID)
        let groups = grouped.keys.compactMap { $0 }.sorted().compactMap { groupID -> Difference? in
            guard let members = grouped[groupID] else { return nil }
            let ids = Set(members.compactMap(\.collectionID).filter { names[$0] != nil }).sorted()
            let collectionID = ids.first
            let order = collectionID.flatMap { existingOrder(in: $0, members: members) }
            guard ids.count > 1 || (collectionID != nil && order == nil) || members.contains(where: { member in
                member.collectionID != collectionID || member.order != order
                    || member.isHidden != (collectionID != nil || !member.isPrimary)
            }) else { return nil }
            return Difference(groupID: groupID, members: members, collectionIDs: ids)
        }
        return (groups, names)
    }

    static func issues(_ db: Database) throws -> [DataHealthIssue] {
        let (groups, names) = try differences(db)
        let repairable = groups.filter { $0.collectionIDs.count <= 1 }.count
        var issues = try groups.filter { $0.collectionIDs.count > 1 }.map { group in
            let collections = group.collectionIDs.compactMap { names[$0] }.joined(separator: " / ")
            let title = try String.fetchOne(db, sql: """
                SELECT title FROM library_books WHERE version_group_id = ? ORDER BY is_primary_version DESC, id LIMIT 1
                """, arguments: [group.groupID])
            return DataHealthIssue(id: "version-series-conflict-\(group.groupID)", severity: .warning,
                                   title: title ?? "Version group #\(group.groupID)",
                                   detail: "\(collections). Choose Add to Collection on any version to set the whole group's series.",
                                   repairable: false)
        }
        if repairable > 0 {
            issues.insert(.init(id: "version-series-membership", severity: .warning, title: "Version series membership",
                                detail: "\(repairable) version group(s) have inconsistent series membership or order",
                                repairable: true), at: 0)
        }
        return issues
    }

    static func repair(_ db: Database) throws {
        let (groups, _) = try differences(db)
        for group in groups where group.collectionIDs.count <= 1 {
            if let collectionID = group.collectionIDs.first {
                try assign(db, members: group.members, to: collectionID)
            } else {
                try write(db, members: group.members, collectionID: nil, order: nil)
            }
        }
    }
}
