import GRDB

extension SQLiteLibraryBookRepository: LibraryDeletionRepository {
    func deletionOperation(bookID: Int64) throws -> LibraryDeletionOperation? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM library_deletion_operations WHERE book_id = ?", arguments: [bookID]).map(Self.deletion(from:))
        }
    }

    func deletionOperations() throws -> [LibraryDeletionOperation] {
        try dbQueue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM library_deletion_operations").map(Self.deletion(from:)) }
    }

    func prepareDeletion(bookID: Int64, identity: String?) throws -> LibraryDeletionOperation {
        try dbQueue.write { db in
            guard let book = try Row.fetchOne(db, sql: "SELECT filepath, cover_path FROM library_books WHERE id = ?", arguments: [bookID]) else { throw LibraryDeletionError.bookUnavailable }
            try db.execute(sql: "INSERT INTO library_deletion_operations(book_id, source_path, source_identity, cover_path, stage, updated_at) VALUES (?, ?, ?, ?, 'prepared', ?) ON CONFLICT(book_id) DO NOTHING", arguments: [bookID, book["filepath"] as String, identity, book["cover_path"] as String?, Timestamp.nowMilliseconds()])
            return Self.deletion(from: try Row.fetchOne(db, sql: "SELECT * FROM library_deletion_operations WHERE book_id = ?", arguments: [bookID])!)
        }
    }

    func updateDeletion(bookID: Int64, stage: String, error: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE library_deletion_operations SET stage = ?, last_error = ?, updated_at = ? WHERE book_id = ?", arguments: [stage, error, Timestamp.nowMilliseconds(), bookID])
        }
    }

    func commitDeletion(bookID: Int64) throws {
        try dbQueue.write { db in
            guard try String.fetchOne(db, sql: "SELECT stage FROM library_deletion_operations WHERE book_id = ?", arguments: [bookID]) == "sourceHandled" else { throw LibraryDeletionError.uncertain }
            try LibraryConsistency.deleteBook(db, id: bookID)
            try db.execute(sql: "UPDATE library_deletion_operations SET stage = 'cleanupPending', last_error = NULL, updated_at = ? WHERE book_id = ?", arguments: [Timestamp.nowMilliseconds(), bookID])
        }
    }

    func finishDeletion(bookID: Int64) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM library_deletion_operations WHERE book_id = ?", arguments: [bookID]) }
    }

    private static func deletion(from row: Row) -> LibraryDeletionOperation {
        .init(bookID: row["book_id"], sourcePath: row["source_path"], sourceIdentity: row["source_identity"], coverPath: row["cover_path"], stage: row["stage"], error: row["last_error"])
    }
}
