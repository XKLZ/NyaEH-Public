// 本文件负责从外部书库导入元数据与合集，只按已扫描书籍的 hash 保守合并。

import Foundation
import GRDB

struct ExternalLibraryImportProgress: Equatable, Sendable {
    var phase: String
    var completed: Int
    var total: Int

    var fractionCompleted: Double {
        guard total > 0 else {
            return 0
        }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct ExternalLibraryImportResult: Equatable, Sendable {
    var backupURL: URL
    var metadataImported: Int
    var booksUpdated: Int
    var collectionsCreated: Int
    var collectionMembersImported: Int
    var skippedDuplicateSourceHashes: Int
    var skippedDuplicateTargetHashes: Int
    var skippedMissingHash: Int
    var skippedUnmatchedBooks: Int
    var skippedCollectionMembers: Int
}

enum ExternalLibraryImportSource: String, CaseIterable, Identifiable, Sendable {
    case thisApp
    case exhentaiMangaManager

    var id: String { rawValue }
}

final class ExternalLibraryImportService {
    private let dbQueue: any DatabaseWriter
    private let backups: LibraryBackupService
    private let fileManager: FileManager

    init(
        dbQueue: any DatabaseWriter,
        backups: LibraryBackupService,
        fileManager: FileManager = .default
    ) {
        self.dbQueue = dbQueue
        self.backups = backups
        self.fileManager = fileManager
    }

    func importExhentaiMangaManager(
        from folderURL: URL,
        progress: @escaping @Sendable (ExternalLibraryImportProgress) -> Void = { _ in }
    ) throws -> ExternalLibraryImportResult {
        // 导入会先备份当前主库，并且只更新 hash 唯一且已扫描的目标书籍；
        // 源库或目标库重复 hash 都保守跳过，避免把外部脏数据写进多个本地记录。
        progress(.init(phase: "Validating import files", completed: 0, total: 7))
        let source = ExhentaiMangaManagerSource(folderURL: folderURL)
        try validate(source: source)

        progress(.init(phase: "Reading source databases", completed: 1, total: 7))
        let mangas = try loadMangas(from: source.databaseURL)
        let metadataRows = try loadMetadata(from: source.metadataURL)
        let collections = try loadCollections(from: source.collectionURL)

        progress(.init(phase: "Creating database backup", completed: 2, total: 7))
        return try backups.protectedOperation(.preImport) { snapshot in
            try importValidated(mangas: mangas, metadataRows: metadataRows, collections: collections,
                                backupURL: snapshot.packageURL, progress: progress)
        }
    }

    private func importValidated(mangas: [ExternalManga], metadataRows: [ExternalMetadata], collections: [ExternalCollection],
                                 backupURL: URL, progress: @escaping @Sendable (ExternalLibraryImportProgress) -> Void) throws -> ExternalLibraryImportResult {
        progress(.init(phase: "Indexing hashes", completed: 3, total: 7))
        let sourceDuplicateHashes = duplicatedHashes(in: mangas.map(\.hash))
        let metadataByHash = Dictionary(
            uniqueKeysWithValues: metadataRows.compactMap { metadata -> (String, ExternalMetadata)? in
                guard let hash = normalizedHash(metadata.hash) else {
                    return nil
                }
                return (hash, metadata)
            }
        )

        progress(.init(phase: "Importing metadata", completed: 4, total: 7))
        let result = try dbQueue.write { db in
            let targetBooks = try loadTargetBooks(in: db)
            let targetDuplicateHashes = duplicatedHashes(in: targetBooks.map(\.hash))
            let targetBooksByHash = Dictionary(
                uniqueKeysWithValues: targetBooks
                    .filter { !targetDuplicateHashes.contains($0.hash) }
                    .map { ($0.hash, $0) }
            )

            var importedBookIDs: [String: LibraryBook.DatabaseID] = [:]
            var updatedBookIDs: [LibraryBook.DatabaseID] = []
            var metadataImported = 0
            var booksUpdated = 0
            var skippedMissingHash = 0
            var skippedUnmatchedBooks = 0

            for manga in mangas {
                guard let hash = normalizedHash(manga.hash) else {
                    skippedMissingHash += 1
                    continue
                }
                guard !sourceDuplicateHashes.contains(hash), !targetDuplicateHashes.contains(hash) else {
                    continue
                }
                guard var book = targetBooksByHash[hash], let bookID = book.databaseID else {
                    skippedUnmatchedBooks += 1
                    continue
                }

                let metadata = metadataByHash[hash]
                try upsertGalleryMetadata(metadata: metadata, manga: manga, hash: hash, in: db)
                metadataImported += 1

                if merge(manga: manga, metadata: metadata, into: &book) {
                    try update(book: book, in: db)
                    updatedBookIDs.append(bookID)
                    booksUpdated += 1
                }
                importedBookIDs[hash] = bookID
            }

            progress(.init(phase: "Importing collections", completed: 5, total: 7))
            let collectionResult = try importCollections(
                collections,
                importedBookIDs: importedBookIDs,
                in: db
            )

            progress(.init(phase: "Rebuilding tag index", completed: 6, total: 7))
            try rebuildTags(bookIDs: updatedBookIDs, in: db)

            return ExternalLibraryImportResult(
                backupURL: backupURL,
                metadataImported: metadataImported,
                booksUpdated: booksUpdated,
                collectionsCreated: collectionResult.collectionsCreated,
                collectionMembersImported: collectionResult.membersImported,
                skippedDuplicateSourceHashes: sourceDuplicateHashes.count,
                skippedDuplicateTargetHashes: targetDuplicateHashes.count,
                skippedMissingHash: skippedMissingHash,
                skippedUnmatchedBooks: skippedUnmatchedBooks,
                skippedCollectionMembers: collectionResult.membersSkipped
            )
        }

        progress(.init(phase: "Finished", completed: 7, total: 7))
        return result
    }

    private func validate(source: ExhentaiMangaManagerSource) throws {
        for url in [source.metadataURL, source.databaseURL, source.collectionURL] {
            guard fileManager.fileExists(atPath: url.path) else {
                throw NyaEHError.importFileMissing(url.lastPathComponent)
            }
        }

        try DatabaseQueue(path: source.metadataURL.path).read { db in
            guard try db.tableExists("Metadata") else {
                throw NyaEHError.importInvalidSource("metadata.sqlite does not contain Metadata.")
            }
        }
        try DatabaseQueue(path: source.databaseURL.path).read { db in
            guard try db.tableExists("Mangas") else {
                throw NyaEHError.importInvalidSource("database.sqlite does not contain Mangas.")
            }
        }

    }

    private func loadMangas(from url: URL) throws -> [ExternalManga] {
        try DatabaseQueue(path: url.path).read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, hash, status, rating, tags, title_jpn, filecount,
                           posted, filesize, category, url, mark, hiddenBook,
                           readCount, createdAt, updatedAt
                    FROM Mangas
                    """
            ).map(ExternalManga.init(row:))
        }
    }

    private func loadMetadata(from url: URL) throws -> [ExternalMetadata] {
        try DatabaseQueue(path: url.path).read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT hash, title, status, rating, tags, title_jpn, filecount,
                           posted, filesize, category, url, mark, createdAt, updatedAt
                    FROM Metadata
                    """
            ).map(ExternalMetadata.init(row:))
        }
    }

    private func loadCollections(from url: URL) throws -> [ExternalCollection] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ExternalCollection].self, from: data)
    }

    private func loadTargetBooks(in db: Database) throws -> [LibraryBook] {
        try Row.fetchAll(
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
                """
        )
        .map(SQLiteLibraryBookRepository.book(from:))
        .compactMap { book in
            guard normalizedHash(book.hash) != nil else {
                return nil
            }
            var normalized = book
            normalized.hash = normalizedHash(book.hash)!
            return normalized
        }
    }

    private func upsertGalleryMetadata(
        metadata: ExternalMetadata?,
        manga: ExternalManga,
        hash: String,
        in db: Database
    ) throws {
        let source = metadata.map(ExternalMetadataOrManga.metadata) ?? .manga(manga)
        let gallery = galleryParts(from: source.url)
        let now = Timestamp.nowMilliseconds()
        try db.execute(
            sql: """
                INSERT INTO gallery_metadata (
                    hash, gallery_id, gallery_token, title, title_jpn, status,
                    rating, tags, pages, posted, filesize, category, url,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(hash) DO UPDATE SET
                    gallery_id = COALESCE(gallery_metadata.gallery_id, excluded.gallery_id),
                    gallery_token = COALESCE(gallery_metadata.gallery_token, excluded.gallery_token),
                    title = COALESCE(NULLIF(gallery_metadata.title, ''), excluded.title),
                    title_jpn = COALESCE(NULLIF(gallery_metadata.title_jpn, ''), excluded.title_jpn),
                    status = CASE WHEN gallery_metadata.status = ? THEN excluded.status ELSE gallery_metadata.status END,
                    rating = COALESCE(gallery_metadata.rating, excluded.rating),
                    tags = CASE WHEN gallery_metadata.tags = '[]' OR gallery_metadata.tags = '' THEN excluded.tags ELSE gallery_metadata.tags END,
                    pages = COALESCE(gallery_metadata.pages, excluded.pages),
                    posted = COALESCE(gallery_metadata.posted, excluded.posted),
                    filesize = COALESCE(gallery_metadata.filesize, excluded.filesize),
                    category = COALESCE(NULLIF(gallery_metadata.category, ''), excluded.category),
                    url = COALESCE(NULLIF(gallery_metadata.url, ''), excluded.url),
                    updated_at = excluded.updated_at
                """,
            arguments: [
                hash,
                gallery.id,
                gallery.token,
                source.title,
                source.titleJpn,
                status(from: source.status).rawValue,
                source.rating,
                normalizedTagsJSON(from: source.tags),
                source.filecount,
                source.posted,
                source.filesize,
                source.category,
                source.url,
                source.createdAtMilliseconds ?? now,
                now,
                BookStatus.unscanned.rawValue
            ]
        )
    }

    private func merge(manga: ExternalManga, metadata: ExternalMetadata?, into book: inout LibraryBook) -> Bool {
        var changed = false
        let source = metadata.map(ExternalMetadataOrManga.metadata) ?? .manga(manga)

        changed = fill(&book.titleJpn, with: source.titleJpn) || changed
        changed = fill(&book.rating, with: source.rating) || changed
        changed = fillTags(&book.tags, with: normalizedTagsJSON(from: source.tags)) || changed
        changed = fill(&book.pages, with: source.filecount) || changed
        changed = fill(&book.posted, with: source.posted) || changed
        changed = fill(&book.filesize, with: source.filesize) || changed
        changed = fill(&book.category, with: source.category) || changed
        changed = fill(&book.url, with: source.url) || changed

        let importedStatus = status(from: source.status)
        if book.status == .unscanned, importedStatus == .correct {
            book.status = .correct
            changed = true
        }

        if book.mark != manga.mark {
            book.mark = manga.mark
            changed = true
        }

        if book.readCount < manga.readCount {
            book.readCount = manga.readCount
            changed = true
        }

        return changed
    }

    private func update(book: LibraryBook, in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE library_books
                SET title = ?,
                    rating = ?,
                    tags = ?,
                    title_jpn = ?,
                    pages = ?,
                    posted = ?,
                    filesize = ?,
                    category = ?,
                    url = ?,
                    status = ?,
                    mark = ?,
                    read_count = ?,
                    updated_at = ?
                WHERE id = ?
                """,
            arguments: [
                book.title,
                book.rating,
                book.tags,
                book.titleJpn,
                book.pages,
                book.posted,
                book.filesize,
                book.category,
                book.url,
                book.status.rawValue,
                book.mark ? 1 : 0,
                book.readCount,
                Timestamp.nowMilliseconds(),
                book.databaseID
            ]
        )
    }

    private func importCollections(
        _ collections: [ExternalCollection],
        importedBookIDs: [String: LibraryBook.DatabaseID],
        in db: Database
    ) throws -> (collectionsCreated: Int, membersImported: Int, membersSkipped: Int) {
        var collectionsCreated = 0
        var membersImported = 0
        var membersSkipped = 0

        for collection in collections {
            let title = collection.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                continue
            }

            let orderedBookIDs = collection.list.compactMap { item -> LibraryBook.DatabaseID? in
                guard item.hasPrefix("book:") else {
                    membersSkipped += 1
                    return nil
                }
                let hash = String(item.dropFirst("book:".count))
                guard let normalized = normalizedHash(hash), let bookID = importedBookIDs[normalized] else {
                    membersSkipped += 1
                    return nil
                }
                return bookID
            }

            var seen = Set<LibraryBook.DatabaseID>()
            let uniqueBookIDs = orderedBookIDs.filter { seen.insert($0).inserted }
            guard !uniqueBookIDs.isEmpty else {
                continue
            }

            let collectionID: Int64
            if let existingID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM book_collections WHERE name = ? COLLATE NOCASE LIMIT 1",
                arguments: [title]
            ) {
                collectionID = existingID
            } else {
                let now = Timestamp.nowMilliseconds()
                try db.execute(
                    sql: "INSERT INTO book_collections (name, created_at, updated_at) VALUES (?, ?, ?)",
                    arguments: [title, now, now]
                )
                collectionID = db.lastInsertedRowID
                collectionsCreated += 1
            }

            var processed = Set<Int64>()
            for bookID in uniqueBookIDs where !processed.contains(bookID) {
                let members = try SeriesMembership.members(db, bookID: bookID)
                processed.formUnion(members.map(\.id))
                let existingCollections = Set(members.compactMap(\.collectionID))
                guard existingCollections.isEmpty || existingCollections == [collectionID] else {
                    membersSkipped += 1
                    continue
                }
                try SeriesMembership.assign(db, members: members, to: collectionID)
                if existingCollections.isEmpty { membersImported += 1 }
            }
        }

        return (collectionsCreated, membersImported, membersSkipped)
    }

    private func rebuildTags(bookIDs: [LibraryBook.DatabaseID], in db: Database) throws {
        for bookID in Set(bookIDs) {
            guard let row = try Row.fetchOne(db, sql: "SELECT tags FROM library_books WHERE id = ?", arguments: [bookID]) else {
                continue
            }
            let tagsJSON: String = row["tags"]
            let tags = TagParser.parseJSON(tagsJSON)
            let derived = TagParser.derivedState(from: tags)

            try db.execute(sql: "DELETE FROM book_tags WHERE book_id = ?", arguments: [bookID])
            for tag in tags {
                let tagID = try upsert(tag: tag, in: db)
                try db.execute(
                    sql: "INSERT OR IGNORE INTO book_tags (book_id, tag_id) VALUES (?, ?)",
                    arguments: [bookID, tagID]
                )
            }

            try db.execute(
                sql: """
                    UPDATE library_books
                    SET language_code = ?,
                        is_translated = ?,
                        is_full_color = ?,
                        censorship = ?,
                        has_extraneous_ads = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    derived.languageCode,
                    derived.isTranslated ? 1 : 0,
                    derived.isFullColor ? 1 : 0,
                    derived.censorship,
                    derived.hasExtraneousAds ? 1 : 0,
                    Timestamp.nowMilliseconds(),
                    bookID
                ]
            )
        }
    }

    private func upsert(tag: Tag, in db: Database) throws -> Tag.DatabaseID {
        if let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM tags WHERE raw_value = ?",
            arguments: [tag.rawValue]
        ) {
            return id
        }

        let now = Timestamp.nowMilliseconds()
        try db.execute(
            sql: "INSERT INTO tags (namespace, name, raw_value, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [tag.namespace, tag.name, tag.rawValue, now, now]
        )
        return db.lastInsertedRowID
    }

    private func duplicatedHashes(in hashes: [String?]) -> Set<String> {
        var counts: [String: Int] = [:]
        for hash in hashes.compactMap(normalizedHash) {
            counts[hash, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    private func normalizedHash(_ hash: String?) -> String? {
        let trimmed = (hash ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func status(from externalStatus: String?) -> BookStatus {
        externalStatus == "tagged" ? .correct : .unscanned
    }

    private func fill(_ field: inout String?, with value: String?) -> Bool {
        guard field?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
              let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        field = value
        return true
    }

    private func fill<T>(_ field: inout T?, with value: T?) -> Bool {
        guard field == nil, let value else {
            return false
        }
        field = value
        return true
    }

    private func fillTags(_ field: inout String, with value: String) -> Bool {
        guard field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || field == "[]" else {
            return false
        }
        guard value != "[]" else {
            return false
        }
        field = value
        return true
    }

    private func normalizedTagsJSON(from tagsJSON: String?) -> String {
        guard let data = tagsJSON?.data(using: .utf8) else {
            return "[]"
        }

        if let grouped = try? JSONDecoder().decode([String: [String]].self, from: data) {
            let tags = grouped
                .flatMap { namespace, names in
                    names.map { "\(namespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
                }
                .filter { !$0.hasSuffix(":") }
                .sorted()
            return encodedTags(tags)
        }

        if let tags = try? JSONDecoder().decode([String].self, from: data) {
            return encodedTags(tags)
        }

        return "[]"
    }

    private func encodedTags(_ tags: [String]) -> String {
        var seen = Set<String>()
        let normalized = tags.compactMap { tag -> String? in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
        guard let data = try? JSONEncoder().encode(normalized),
              let encoded = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return encoded
    }

    private func galleryParts(from urlString: String?) -> (id: Int64?, token: String?) {
        guard let urlString else {
            return (nil, nil)
        }
        let pattern = #"/g/(\d+)/([^/]+)/?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: urlString,
                range: NSRange(urlString.startIndex..<urlString.endIndex, in: urlString)
              ),
              let idRange = Range(match.range(at: 1), in: urlString),
              let tokenRange = Range(match.range(at: 2), in: urlString) else {
            return (nil, nil)
        }
        return (Int64(urlString[idRange]), String(urlString[tokenRange]))
    }


}

private struct ExhentaiMangaManagerSource {
    var folderURL: URL
    var metadataURL: URL { folderURL.appendingPathComponent("metadata.sqlite") }
    var databaseURL: URL { folderURL.appendingPathComponent("database.sqlite") }
    var collectionURL: URL { folderURL.appendingPathComponent("collectionList.json") }
}

private struct ExternalManga {
    var id: String
    var title: String?
    var hash: String?
    var status: String?
    var rating: Double?
    var tags: String?
    var titleJpn: String?
    var filecount: Int?
    var posted: Int64?
    var filesize: Int64?
    var category: String?
    var url: String?
    var mark: Bool
    var hiddenBook: Bool
    var readCount: Int
    var createdAtMilliseconds: Int64?
    var updatedAtMilliseconds: Int64?

    init(row: Row) {
        id = row["id"]
        title = row["title"]
        hash = row["hash"]
        status = row["status"]
        rating = row["rating"]
        tags = row["tags"]
        titleJpn = row["title_jpn"]
        filecount = row["filecount"]
        posted = row["posted"]
        filesize = row["filesize"]
        category = row["category"]
        url = row["url"]
        mark = (Int.fromDatabaseValue(row["mark"]) ?? 0) == 1
        hiddenBook = (Int.fromDatabaseValue(row["hiddenBook"]) ?? 0) == 1
        readCount = row["readCount"] ?? 0
        createdAtMilliseconds = Self.milliseconds(from: row["createdAt"])
        updatedAtMilliseconds = Self.milliseconds(from: row["updatedAt"])
    }

    private static func milliseconds(from value: String?) -> Int64? {
        ExternalDateParser.milliseconds(from: value)
    }
}

private struct ExternalMetadata {
    var hash: String?
    var title: String?
    var status: String?
    var rating: Double?
    var tags: String?
    var titleJpn: String?
    var filecount: Int?
    var posted: Int64?
    var filesize: Int64?
    var category: String?
    var url: String?
    var mark: Bool
    var createdAtMilliseconds: Int64?
    var updatedAtMilliseconds: Int64?

    init(row: Row) {
        hash = row["hash"]
        title = row["title"]
        status = row["status"]
        rating = row["rating"]
        tags = row["tags"]
        titleJpn = row["title_jpn"]
        filecount = row["filecount"]
        posted = row["posted"]
        filesize = row["filesize"]
        category = row["category"]
        url = row["url"]
        mark = (Int.fromDatabaseValue(row["mark"]) ?? 0) == 1
        createdAtMilliseconds = ExternalDateParser.milliseconds(from: row["createdAt"])
        updatedAtMilliseconds = ExternalDateParser.milliseconds(from: row["updatedAt"])
    }
}

private enum ExternalMetadataOrManga {
    case metadata(ExternalMetadata)
    case manga(ExternalManga)

    var title: String? {
        switch self {
        case .metadata(let metadata): metadata.title
        case .manga(let manga): manga.title
        }
    }

    var status: String? {
        switch self {
        case .metadata(let metadata): metadata.status
        case .manga(let manga): manga.status
        }
    }

    var rating: Double? {
        switch self {
        case .metadata(let metadata): metadata.rating
        case .manga(let manga): manga.rating
        }
    }

    var tags: String? {
        switch self {
        case .metadata(let metadata): metadata.tags
        case .manga(let manga): manga.tags
        }
    }

    var titleJpn: String? {
        switch self {
        case .metadata(let metadata): metadata.titleJpn
        case .manga(let manga): manga.titleJpn
        }
    }

    var filecount: Int? {
        switch self {
        case .metadata(let metadata): metadata.filecount
        case .manga(let manga): manga.filecount
        }
    }

    var posted: Int64? {
        switch self {
        case .metadata(let metadata): metadata.posted
        case .manga(let manga): manga.posted
        }
    }

    var filesize: Int64? {
        switch self {
        case .metadata(let metadata): metadata.filesize
        case .manga(let manga): manga.filesize
        }
    }

    var category: String? {
        switch self {
        case .metadata(let metadata): metadata.category
        case .manga(let manga): manga.category
        }
    }

    var url: String? {
        switch self {
        case .metadata(let metadata): metadata.url
        case .manga(let manga): manga.url
        }
    }

    var createdAtMilliseconds: Int64? {
        switch self {
        case .metadata(let metadata): metadata.createdAtMilliseconds
        case .manga(let manga): manga.createdAtMilliseconds
        }
    }
}

private struct ExternalCollection: Decodable {
    var id: String
    var title: String
    var list: [String]
}

private enum ExternalDateParser {
    static func milliseconds(from value: String?) -> Int64? {
        guard let value else {
            return nil
        }
        if let date = databaseFormatter.date(from: value) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        return nil
    }

    private static let databaseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }()

}
