// 本文件实现 library_books 的 SQLite 读写，是扫描、元数据同步、筛选和组织状态的持久化核心。

import Foundation
import GRDB

final class SQLiteLibraryBookRepository: LibraryBookRepository {
    let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetchAll() throws -> [LibraryBook] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, cover_path, hash, filepath, type, file_count,
                           bundle_size, mtime, cover_hash, status, date, rating, tags,
                           title_jpn, pages, posted, filesize, category, url,
                           collection_id, collection_order, version_group_id,
                           is_primary_version, version_label,
                           language_code, is_translated, is_full_color, censorship,
                           has_extraneous_ads, mark,
                           hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    FROM library_books
                    ORDER BY date DESC, title COLLATE NOCASE ASC
                    """
            )
            return rows.map(Self.book(from:))
        }
    }

    func fetch(id: LibraryBook.DatabaseID) throws -> LibraryBook? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, title, cover_path, hash, filepath, type, file_count,
                           bundle_size, mtime, cover_hash, status, date, rating, tags,
                           title_jpn, pages, posted, filesize, category, url,
                           collection_id, collection_order, version_group_id,
                           is_primary_version, version_label,
                           language_code, is_translated, is_full_color, censorship,
                           has_extraneous_ads, mark,
                           hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    FROM library_books
                    WHERE id = ?
                    """,
                arguments: [id]
            )
            return row.map(Self.book(from:))
        }
    }

    func fetchByHash(_ hash: String) throws -> [LibraryBook] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, cover_path, hash, filepath, type, file_count,
                           bundle_size, mtime, cover_hash, status, date, rating, tags,
                           title_jpn, pages, posted, filesize, category, url,
                           collection_id, collection_order, version_group_id,
                           is_primary_version, version_label,
                           language_code, is_translated, is_full_color, censorship,
                           has_extraneous_ads, mark,
                           hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    FROM library_books
                    WHERE hash = ?
                    ORDER BY date DESC
                    """,
                arguments: [hash]
            )
            return rows.map(Self.book(from:))
        }
    }

    func fetchByFilepath(_ filepath: String) throws -> LibraryBook? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, title, cover_path, hash, filepath, type, file_count,
                           bundle_size, mtime, cover_hash, status, date, rating, tags,
                           title_jpn, pages, posted, filesize, category, url,
                           collection_id, collection_order, version_group_id,
                           is_primary_version, version_label,
                           language_code, is_translated, is_full_color, censorship,
                           has_extraneous_ads, mark,
                           hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    FROM library_books
                    WHERE filepath = ?
                    """,
                arguments: [filepath]
            )
            return row.map(Self.book(from:))
        }
    }

    func fetchByCollectionID(_ collectionID: BookCollection.DatabaseID) throws -> [LibraryBook] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, cover_path, hash, filepath, type, file_count,
                           bundle_size, mtime, cover_hash, status, date, rating, tags,
                           title_jpn, pages, posted, filesize, category, url,
                           collection_id, collection_order, version_group_id,
                           is_primary_version, version_label,
                           language_code, is_translated, is_full_color, censorship,
                           has_extraneous_ads, mark,
                           hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    FROM library_books
                    WHERE collection_id = ?
                    ORDER BY collection_order ASC, date DESC, title COLLATE NOCASE ASC
                    """,
                arguments: [collectionID]
            )
            return rows.map(Self.book(from:))
        }
    }

    func fetchByVersionGroupID(_ versionGroupID: BookVersionGroup.DatabaseID) throws -> [LibraryBook] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, cover_path, hash, filepath, type, file_count,
                           bundle_size, mtime, cover_hash, status, date, rating, tags,
                           title_jpn, pages, posted, filesize, category, url,
                           collection_id, collection_order, version_group_id,
                           is_primary_version, version_label,
                           language_code, is_translated, is_full_color, censorship,
                           has_extraneous_ads, mark,
                           hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    FROM library_books
                    WHERE version_group_id = ?
                    ORDER BY is_primary_version DESC, date DESC, title COLLATE NOCASE ASC
                    """,
                arguments: [versionGroupID]
            )
            return rows.map(Self.book(from:))
        }
    }

    func insert(_ book: LibraryBook) throws -> LibraryBook {
        try dbQueue.write { db in try Self.insert(book, in: db) }
    }

    private static func insert(_ book: LibraryBook, in db: Database) throws -> LibraryBook {
        var saved = book
        saved.createdAt = book.createdAt
        saved.updatedAt = Timestamp.nowMilliseconds()
        try db.execute(
                sql: """
                    INSERT INTO library_books (
                        title, cover_path, hash, filepath, type, file_count,
                        bundle_size, mtime, cover_hash, status, date, rating, tags,
                        title_jpn, pages, posted, filesize, category, url,
                        collection_id, collection_order, version_group_id,
                        is_primary_version, version_label,
                        language_code, is_translated, is_full_color, censorship,
                        has_extraneous_ads, mark,
                        hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: Self.arguments(for: saved, includeID: false)
        )
        saved.databaseID = db.lastInsertedRowID
        return saved
    }

    func update(_ book: LibraryBook) throws -> LibraryBook {
        guard book.databaseID != nil else {
            throw NyaEHError.bookHasNoID
        }

        return try dbQueue.write { db in try Self.update(book, in: db) }
    }

    private static func update(_ book: LibraryBook, in db: Database) throws -> LibraryBook {
        guard book.databaseID != nil else { throw NyaEHError.bookHasNoID }
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM library_books WHERE id = ?) AND NOT EXISTS(SELECT 1 FROM library_deletion_operations WHERE book_id = ? AND stage <> 'needsAttention')", arguments: [book.databaseID, book.databaseID]) == true else {
            throw LibraryDeletionError.bookUnavailable
        }
        var updated = book
        updated.updatedAt = Timestamp.nowMilliseconds()
        try db.execute(
                sql: """
                    UPDATE library_books
                    SET title = ?,
                        cover_path = ?,
                        hash = ?,
                        filepath = ?,
                        type = ?,
                        file_count = ?,
                        bundle_size = ?,
                        mtime = ?,
                        cover_hash = ?,
                        status = ?,
                        date = ?,
                        rating = ?,
                        tags = ?,
                        title_jpn = ?,
                        pages = ?,
                        posted = ?,
                        filesize = ?,
                        category = ?,
                        url = ?,
                        collection_id = ?,
                        collection_order = ?,
                        version_group_id = ?,
                        is_primary_version = ?,
                        version_label = ?,
                        language_code = ?,
                        is_translated = ?,
                        is_full_color = ?,
                        censorship = ?,
                        has_extraneous_ads = ?,
                        mark = ?,
                        hidden_book = ?,
                        is_user_hidden = ?,
                        read_count = ?,
                        last_read_at = ?,
                        exist = ?,
                        created_at = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: Self.arguments(for: updated, includeID: true)
        )
        return updated
    }

    func updateMetadata(_ book: LibraryBook) throws -> LibraryBook {
        try dbQueue.write { db in
            let current = try Self.writableBook(book.databaseID, in: db)
            // Metadata fetched for earlier archive contents must not attach to a replacement.
            guard book.hash.caseInsensitiveCompare(current.hash) == .orderedSame else { return current }
            try Self.writeMetadata(book, in: db)
            return try Self.writableBook(book.databaseID, in: db)
        }
    }

    private static func writeMetadata(_ book: LibraryBook, in db: Database) throws {
        try db.execute(sql: """
            UPDATE library_books SET title = ?, title_jpn = ?, status = ?, rating = ?, tags = ?,
                pages = ?, posted = ?, filesize = ?, category = ?, url = ?, language_code = ?,
                is_translated = ?, is_full_color = ?, censorship = ?, has_extraneous_ads = ?, updated_at = ?
            WHERE id = ?
            """, arguments: [book.title, book.titleJpn, book.status.rawValue, book.rating, book.tags,
                book.pages, book.posted, book.filesize, book.category, book.url, book.languageCode,
                book.isTranslated, book.isFullColor, book.censorship, book.hasExtraneousAds,
                Timestamp.nowMilliseconds(), book.databaseID])
    }

    func updateFromScan(_ book: LibraryBook) throws -> LibraryBook {
        try dbQueue.write { db in try Self.updateFromScan(book, in: db) }
    }

    private static func updateFromScan(_ book: LibraryBook, in db: Database) throws -> LibraryBook {
        let current = try writableBook(book.databaseID, in: db)
        if book.status == .missing || book.status == .broken {
            try db.execute(sql: "UPDATE library_books SET status = ?, exist = ?, updated_at = ? WHERE id = ?",
                           arguments: [book.status.rawValue, book.exist, Timestamp.nowMilliseconds(), book.databaseID])
        } else {
            let hashChanged = book.hash.caseInsensitiveCompare(current.hash) != .orderedSame
            let status: BookStatus = hashChanged || current.status == .missing || current.status == .broken
                ? .unscanned : current.status
            try db.execute(sql: """
                UPDATE library_books SET hash = ?, filepath = ?, cover_path = ?, cover_hash = ?,
                    type = ?, file_count = ?, bundle_size = ?, mtime = ?, exist = ?, status = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [book.hash, book.filepath, book.coverPath, book.coverHash, book.type.rawValue,
                    book.fileCount, book.bundleSize, book.mtime, book.exist, status.rawValue, Timestamp.nowMilliseconds(),
                    book.databaseID])
            if hashChanged {
                try writeMetadata(book, in: db)
            } else if current.status == .unscanned && book.status == .unscanned
                        && ["", "unknown"].contains(current.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                        && current.languageCode != book.languageCode {
                try db.execute(sql: "UPDATE library_books SET language_code = ?, tags = ? WHERE id = ?",
                               arguments: [book.languageCode, book.tags, book.databaseID])
            }
        }
        return try writableBook(book.databaseID, in: db)
    }

    func setMarked(_ marked: Bool, bookID: LibraryBook.DatabaseID) throws -> LibraryBook {
        try dbQueue.write { db in
            let current = try Self.writableBook(bookID, in: db)
            if let groupID = current.versionGroupID {
                try db.execute(sql: "UPDATE library_books SET mark = ?, updated_at = ? WHERE version_group_id = ?",
                               arguments: [marked, Timestamp.nowMilliseconds(), groupID])
            } else {
                try db.execute(sql: "UPDATE library_books SET mark = ?, updated_at = ? WHERE id = ?",
                               arguments: [marked, Timestamp.nowMilliseconds(), bookID])
            }
            return try Self.writableBook(bookID, in: db)
        }
    }

    func setUserHidden(_ hidden: Bool, bookID: LibraryBook.DatabaseID) throws -> LibraryBook {
        try dbQueue.write { db in
            _ = try Self.writableBook(bookID, in: db)
            try db.execute(sql: "UPDATE library_books SET is_user_hidden = ?, updated_at = ? WHERE id = ?",
                           arguments: [hidden, Timestamp.nowMilliseconds(), bookID])
            return try Self.writableBook(bookID, in: db)
        }
    }

    private static func writableBook(_ id: LibraryBook.DatabaseID?, in db: Database) throws -> LibraryBook {
        guard let id else { throw NyaEHError.bookHasNoID }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM library_books WHERE id = ? AND NOT EXISTS (
                SELECT 1 FROM library_deletion_operations WHERE book_id = ? AND stage <> 'needsAttention'
            )
            """, arguments: [id, id]) else { throw LibraryDeletionError.bookUnavailable }
        return book(from: row)
    }

    func applyScanChanges(
        inserts: [LibraryBook],
        updates: [LibraryBook],
        seenFilepaths: Set<String>
    ) throws -> LibraryScanCommitResult {
        try dbQueue.write { db in
            try Task.checkCancellation()
            let missingBefore = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM library_books WHERE exist = 0 OR status = ?",
                arguments: [BookStatus.missing.rawValue]
            ) ?? 0
            for book in inserts { _ = try Self.insert(book, in: db) }
            for book in updates { _ = try Self.updateFromScan(book, in: db) }
            try Self.markMissing(except: seenFilepaths, in: db)
            let missingAfter = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM library_books WHERE exist = 0 OR status = ?",
                arguments: [BookStatus.missing.rawValue]
            ) ?? 0
            return .init(
                inserted: inserts.count,
                updated: updates.count,
                newlyMissing: max(0, missingAfter - missingBefore)
            )
        }
    }

    func replaceCollectionOrder(
        bookIDs: [LibraryBook.DatabaseID],
        collectionID: BookCollection.DatabaseID
    ) throws -> [LibraryBook] {
        try dbQueue.write { db in
            try SeriesMembership.replaceOrder(db, bookIDs: bookIDs, collectionID: collectionID)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, cover_path, hash, filepath, type, file_count,
                           bundle_size, mtime, cover_hash, status, date, rating, tags,
                           title_jpn, pages, posted, filesize, category, url,
                           collection_id, collection_order, version_group_id,
                           is_primary_version, version_label,
                           language_code, is_translated, is_full_color, censorship,
                           has_extraneous_ads, mark,
                           hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    FROM library_books
                    WHERE collection_id = ?
                    ORDER BY collection_order ASC, date DESC, title COLLATE NOCASE ASC
                    """,
                arguments: [collectionID]
            )
            return rows.map(Self.book(from:))
        }
    }

    func delete(id: LibraryBook.DatabaseID) throws {
        try dbQueue.write { db in
            try LibraryConsistency.deleteBook(db, id: id)
        }
    }

    func incrementReadCount(bookID: LibraryBook.DatabaseID) throws -> LibraryBook? {
        try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    UPDATE library_books
                    SET read_count = read_count + 1,
                        last_read_at = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    now,
                    now,
                    bookID
                ]
            )

            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, title, cover_path, hash, filepath, type, file_count,
                           bundle_size, mtime, cover_hash, status, date, rating, tags,
                           title_jpn, pages, posted, filesize, category, url,
                           collection_id, collection_order, version_group_id,
                           is_primary_version, version_label,
                           language_code, is_translated, is_full_color, censorship,
                           has_extraneous_ads, mark,
                           hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                    FROM library_books
                    WHERE id = ?
                    """,
                arguments: [bookID]
            )
            return row.map(Self.book(from:))
        }
    }

    func updateStatus(bookID: LibraryBook.DatabaseID, status: BookStatus, exist: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE library_books SET status = ?, exist = ?, updated_at = ? WHERE id = ?",
                arguments: [
                    status.rawValue,
                    exist.databaseValue,
                    Timestamp.nowMilliseconds(),
                    bookID
                ]
            )
        }
    }

    func markMissingExcept(filepaths: Set<String>) throws {
        try dbQueue.write { db in
            try Self.markMissing(except: filepaths, in: db)
        }
    }

    private static func markMissing(except filepaths: Set<String>, in db: Database) throws {
        let now = Timestamp.nowMilliseconds()
        if filepaths.isEmpty {
            try db.execute(
                sql: """
                    UPDATE library_books
                    SET status = ?, exist = 0, updated_at = ?
                    WHERE exist <> 0 OR status <> ?
                    """,
                arguments: [BookStatus.missing.rawValue, now, BookStatus.missing.rawValue]
            )
            return
        }

        // 使用连接本地临时表规避超大书库下 SQLite bind 参数上限，也让缺失检测保持线性。
        try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS nyaeh_scan_seen_paths (
                filepath TEXT PRIMARY KEY
            ) WITHOUT ROWID;
            DELETE FROM nyaeh_scan_seen_paths;
            """)
        let insert = try db.makeStatement(
            sql: "INSERT OR IGNORE INTO nyaeh_scan_seen_paths(filepath) VALUES (?)"
        )
        for filepath in filepaths.sorted() {
            try insert.execute(arguments: [filepath])
        }
        try db.execute(
            sql: """
                UPDATE library_books
                SET status = ?, exist = 0, updated_at = ?
                WHERE (exist <> 0 OR status <> ?)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM nyaeh_scan_seen_paths
                      WHERE nyaeh_scan_seen_paths.filepath = library_books.filepath
                  )
                """,
            arguments: [BookStatus.missing.rawValue, now, BookStatus.missing.rawValue]
        )
        try db.execute(sql: "DROP TABLE nyaeh_scan_seen_paths")
    }

    private static func arguments(for book: LibraryBook, includeID: Bool) -> StatementArguments {
        var arguments: StatementArguments = [
            book.title,
            book.coverPath,
            book.hash,
            book.filepath,
            book.type.rawValue,
            book.fileCount,
            book.bundleSize,
            book.mtime,
            book.coverHash,
            book.status.rawValue,
            book.date,
            book.rating,
            book.tags,
            book.titleJpn,
            book.pages,
            book.posted,
            book.filesize,
            book.category,
            book.url,
            book.collectionID,
            book.collectionOrder,
            book.versionGroupID,
            book.isPrimaryVersion.databaseValue,
            book.versionLabel,
            book.languageCode,
            book.isTranslated.databaseValue,
            book.isFullColor.databaseValue,
            book.censorship,
            book.hasExtraneousAds.databaseValue,
            book.mark.databaseValue,
            book.hiddenBook.databaseValue,
            book.isUserHidden.databaseValue,
            book.readCount,
            book.lastReadAt,
            book.exist.databaseValue,
            book.createdAt,
            book.updatedAt
        ]

        if includeID {
            arguments += [book.databaseID]
        }

        return arguments
    }

    static func book(from row: Row) -> LibraryBook {
        LibraryBook(
            databaseID: row["id"],
            title: row["title"],
            coverPath: row["cover_path"],
            hash: row["hash"],
            filepath: row["filepath"],
            type: BookType(rawValue: row["type"]) ?? .unknown,
            fileCount: row["file_count"],
            bundleSize: row["bundle_size"],
            mtime: row["mtime"],
            coverHash: row["cover_hash"],
            status: BookStatus(rawValue: row["status"]) ?? .unscanned,
            date: row["date"],
            rating: row["rating"],
            tags: row["tags"],
            titleJpn: row["title_jpn"],
            pages: row["pages"],
            posted: row["posted"],
            filesize: row["filesize"],
            category: row["category"],
            url: row["url"],
            collectionID: row["collection_id"],
            collectionOrder: row["collection_order"],
            versionGroupID: row["version_group_id"],
            isPrimaryVersion: Int.fromDatabaseValue(row["is_primary_version"]) != 0,
            versionLabel: row["version_label"],
            languageCode: row["language_code"],
            isTranslated: Int.fromDatabaseValue(row["is_translated"]) == 1,
            isFullColor: Int.fromDatabaseValue(row["is_full_color"]) == 1,
            censorship: row["censorship"],
            hasExtraneousAds: Int.fromDatabaseValue(row["has_extraneous_ads"]) == 1,
            mark: Int.fromDatabaseValue(row["mark"]) == 1,
            hiddenBook: Int.fromDatabaseValue(row["hidden_book"]) == 1,
            isUserHidden: Int.fromDatabaseValue(row["is_user_hidden"]) == 1,
            readCount: row["read_count"],
            lastReadAt: row["last_read_at"],
            exist: Int.fromDatabaseValue(row["exist"]) == 1,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}

private extension Bool {
    var databaseValue: Int {
        self ? 1 : 0
    }
}
