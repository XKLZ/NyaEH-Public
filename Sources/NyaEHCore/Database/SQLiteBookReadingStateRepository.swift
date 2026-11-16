// 本文件使用 SQLite 保存阅读页码、总页数和完成时间。

import GRDB

final class SQLiteBookReadingStateRepository: BookReadingStateRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetch(bookID: LibraryBook.DatabaseID) throws -> BookReadingState? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT book_id, current_page_index, total_pages, updated_at, completed_at
                    FROM book_reading_state
                    WHERE book_id = ?
                    """,
                arguments: [bookID]
            ).map(Self.state(from:))
        }
    }

    func fetchAll() throws -> [BookReadingState] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT book_id, current_page_index, total_pages, updated_at, completed_at
                    FROM book_reading_state
                    ORDER BY updated_at DESC, book_id ASC
                    """
            ).map(Self.state(from:))
        }
    }

    func save(_ state: BookReadingState) throws -> BookReadingState {
        try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM library_books WHERE id = ?) AND NOT EXISTS(SELECT 1 FROM library_deletion_operations WHERE book_id = ? AND stage <> 'needsAttention')", arguments: [state.bookID, state.bookID]) == true else { return state }
            var saved = state
            saved.currentPageIndex = max(saved.currentPageIndex, 0)
            saved.totalPages = max(saved.totalPages, 0)
            if saved.totalPages > 0 {
                saved.currentPageIndex = min(saved.currentPageIndex, saved.totalPages - 1)
            }
            saved.updatedAt = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    INSERT INTO book_reading_state (
                        book_id, current_page_index, total_pages, updated_at, completed_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(book_id) DO UPDATE SET
                        current_page_index = excluded.current_page_index,
                        total_pages = excluded.total_pages,
                        updated_at = excluded.updated_at,
                        completed_at = excluded.completed_at
                    """,
                arguments: [
                    saved.bookID,
                    saved.currentPageIndex,
                    saved.totalPages,
                    saved.updatedAt,
                    saved.completedAt
                ]
            )
            return saved
        }
    }

    func reset(bookID: LibraryBook.DatabaseID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM book_reading_state WHERE book_id = ?", arguments: [bookID])
        }
    }

    private static func state(from row: Row) -> BookReadingState {
        BookReadingState(
            bookID: row["book_id"],
            currentPageIndex: row["current_page_index"],
            totalPages: row["total_pages"],
            updatedAt: row["updated_at"],
            completedAt: row["completed_at"]
        )
    }
}
