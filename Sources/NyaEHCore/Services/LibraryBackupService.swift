// 本文件负责主库与不可重建 TagAssets 的备份、恢复、保留策略和基础一致性检查。

import Foundation
import GRDB

struct LibraryBackupService: @unchecked Sendable {
    static let packageExtension = "nyaehbackup"
    static let databaseFilename = "NyaEH.sqlite"
    static let manifestFilename = "manifest.json"
    static let currentSchemaVersion = 22

    private let databaseManager: DatabaseManager
    private let appDataURL: URL
    private let coverVectorRepository: CoverVectorRepository?
    private let semanticTitleVectorRepository: SemanticTitleVectorRepository?
    private let fileManager: FileManager

    init(
        databaseManager: DatabaseManager,
        appDataURL: URL,
        coverVectorRepository: CoverVectorRepository? = nil,
        semanticTitleVectorRepository: SemanticTitleVectorRepository? = nil,
        fileManager: FileManager = .default
    ) {
        self.databaseManager = databaseManager
        self.appDataURL = appDataURL
        self.coverVectorRepository = coverVectorRepository
        self.semanticTitleVectorRepository = semanticTitleVectorRepository
        self.fileManager = fileManager
    }

    func export(to packageURL: URL, kind: LibraryBackupKind = .manual) throws -> LibraryBackupResult {
        try createPackage(at: packageURL, kind: kind, replacingExisting: true)
    }

    func createInternalBackup(kind: LibraryBackupKind, now: Date = Date()) throws -> LibraryBackupResult {
        let directory = appDataURL.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp: String
        switch kind {
        case .daily: stamp = Self.dayFormatter.string(from: now)
        case .weekly: stamp = Self.weekFormatter.string(from: now)
        default: stamp = Self.timestampFormatter.string(from: now)
        }
        let packageURL = directory.appendingPathComponent("\(kind.rawValue)-\(stamp).\(Self.packageExtension)", isDirectory: true)
        let result = try createPackage(at: packageURL, kind: kind, replacingExisting: false)
        try pruneInternalBackups(in: directory)
        return result
    }

    func createAutomaticBackupsIfNeeded(now: Date = Date()) throws {
        let directory = appDataURL.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let dayKey = Self.dayFormatter.string(from: now)
        if !names.contains(where: { $0.hasPrefix("daily-\(dayKey)") }) {
            _ = try createInternalBackup(kind: .daily, now: now)
        }
        let weekKey = Self.weekFormatter.string(from: now)
        if !names.contains(where: { $0.hasPrefix("weekly-\(weekKey)") }) {
            _ = try createInternalBackup(kind: .weekly, now: now)
        }
    }

    func validate(packageURL: URL) throws -> LibraryBackupManifest {
        let manifestURL = packageURL.appendingPathComponent(Self.manifestFilename)
        let databaseURL = databaseURL(in: packageURL)
        let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion == LibraryBackupManifest.formatVersion,
              manifest.schemaVersion <= Self.currentSchemaVersion,
              fileManager.fileExists(atPath: databaseURL.path) else {
            throw LibraryBackupError.invalidPackage
        }
        let queue = try DatabaseQueue(path: databaseURL.path)
        let integrity = try queue.read { db in try String.fetchAll(db, sql: "PRAGMA integrity_check") }
        guard integrity == ["ok"] else {
            throw LibraryBackupError.integrityCheckFailed(integrity.joined(separator: "; "))
        }
        let foreignKeyRows = try queue.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }
        guard foreignKeyRows.isEmpty else {
            throw LibraryBackupError.foreignKeyCheckFailed(foreignKeyRows.count)
        }
        return manifest
    }

    private func databaseURL(in packageURL: URL) -> URL {
        let current = packageURL.appendingPathComponent(Self.databaseFilename)
        if fileManager.fileExists(atPath: current.path) { return current }
        return packageURL.appendingPathComponent(LegacyNaming.databaseFilename)
    }

    func restore(from packageURL: URL) throws -> LibraryBackupResult {
        let manifest = try validate(packageURL: packageURL)
        let rollback = try createInternalBackup(kind: .preRestore)
        do {
            let source = try DatabaseQueue(path: databaseURL(in: packageURL).path)
            try source.backup(to: databaseManager.dbQueue)
            try restoreTagAssets(from: packageURL, includesAssets: manifest.includesTagAssets)
            try DatabaseMigrator.nyaeh.migrate(databaseManager.dbQueue)
            // 语义标题缓存不属于备份。恢复主库后必须丢弃它，防止复用已改变含义的 book ID。
            try? semanticTitleVectorRepository?.clear()
            return LibraryBackupResult(packageURL: packageURL, manifest: manifest)
        } catch {
            let rollbackSource = try DatabaseQueue(path: rollback.packageURL.appendingPathComponent(Self.databaseFilename).path)
            try? rollbackSource.backup(to: databaseManager.dbQueue)
            try? restoreTagAssets(from: rollback.packageURL, includesAssets: rollback.manifest.includesTagAssets)
            try? semanticTitleVectorRepository?.clear()
            throw error
        }
    }

    func healthCheck() throws -> DataHealthReport {
        var issues: [DataHealthIssue] = []
        let integrity = try databaseManager.integrityCheck()
        if integrity != ["ok"] {
            issues.append(.init(id: "sqlite-integrity", severity: .error, title: "SQLite integrity", detail: integrity.joined(separator: "; "), repairable: false))
        }
        let foreignKeys = try databaseManager.foreignKeyCheck()
        if !foreignKeys.isEmpty {
            issues.append(.init(id: "foreign-keys", severity: .error, title: "Foreign keys", detail: "\(foreignKeys.count) violation(s)", repairable: false))
        }

        let counts = try databaseManager.dbQueue.read { db -> (Int, Int, Int, Int, Int, Int) in
            let tagMismatch = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM library_books
                WHERE (SELECT COUNT(*) FROM book_tags WHERE book_tags.book_id = library_books.id)
                    <> json_array_length(CASE WHEN json_valid(library_books.tags) THEN library_books.tags ELSE '[]' END)
                """) ?? 0
            let labelMismatch = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM library_books
                WHERE COALESCE(version_label, '') <> COALESCE((
                    SELECT GROUP_CONCAT(label, ' / ') FROM (
                        SELECT label FROM book_version_labels
                        WHERE book_id = library_books.id ORDER BY position
                    )
                ), '')
                """) ?? 0
            let invalidReading = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM book_reading_state
                WHERE current_page_index < 0 OR total_pages < 0
                   OR (total_pages > 0 AND current_page_index >= total_pages)
                """) ?? 0
            let orphanCollections = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM library_books
                WHERE collection_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM book_collections WHERE id = library_books.collection_id)
                """) ?? 0
            let orphanVersionGroups = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM library_books
                WHERE version_group_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM book_version_groups WHERE id = library_books.version_group_id)
                """) ?? 0
            let orphanRecommendations = (try Int.fetchOne(db, sql: """
                SELECT
                    (SELECT COUNT(*) FROM collection_recommendations
                     WHERE target_collection_id IS NOT NULL
                       AND NOT EXISTS (SELECT 1 FROM book_collections WHERE id = target_collection_id))
                  + (SELECT COUNT(*) FROM version_recommendations
                     WHERE target_version_group_id IS NOT NULL
                       AND NOT EXISTS (SELECT 1 FROM book_version_groups WHERE id = target_version_group_id))
                """)) ?? 0
            return (tagMismatch, labelMismatch, invalidReading, orphanCollections, orphanVersionGroups, orphanRecommendations)
        }
        if counts.0 > 0 {
            issues.append(.init(id: "tag-index", severity: .warning, title: "Tag index", detail: "\(counts.0) book(s) differ from materialized tags", repairable: true))
        }
        if counts.1 > 0 {
            issues.append(.init(id: "version-labels", severity: .warning, title: "Version labels", detail: "\(counts.1) compatibility cache mismatch(es)", repairable: true))
        }
        if counts.2 > 0 {
            issues.append(.init(id: "reading-state", severity: .warning, title: "Reading progress", detail: "\(counts.2) invalid row(s)", repairable: true))
        }
        if counts.3 > 0 {
            issues.append(.init(id: "collection-links", severity: .warning, title: "Collections", detail: "\(counts.3) orphaned book link(s)", repairable: true))
        }
        if counts.4 > 0 {
            issues.append(.init(id: "version-group-links", severity: .warning, title: "Version groups", detail: "\(counts.4) orphaned book link(s)", repairable: true))
        }
        if counts.5 > 0 {
            issues.append(.init(id: "recommendation-links", severity: .warning, title: "Recommendations", detail: "\(counts.5) orphaned recommendation(s)", repairable: true))
        }
        issues += try databaseManager.dbQueue.read { try SeriesMembership.issues($0) }
        let consistencyIssues = try databaseManager.dbQueue.read { db in
            let recommendations = try LibraryConsistency.invalidRecommendationIDs(db, collection: false).count + LibraryConsistency.invalidRecommendationIDs(db, collection: true).count
            let groups = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_version_groups g WHERE (SELECT COUNT(*) FROM library_books WHERE version_group_id = g.id) < 2 OR (SELECT COUNT(*) FROM library_books WHERE version_group_id = g.id AND is_primary_version = 1) <> 1") ?? 0
            let collections = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_collections c WHERE NOT EXISTS(SELECT 1 FROM library_books WHERE collection_id = c.id)") ?? 0
            let deletions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_deletion_operations") ?? 0
            let hidden = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_books WHERE hidden_book <> (collection_id IS NOT NULL OR (version_group_id IS NOT NULL AND is_primary_version = 0)) OR (version_group_id IS NULL AND is_primary_version = 0)") ?? 0
            let batches = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM import_pipeline_batches b WHERE b.status <> 'completed'
                AND (NOT EXISTS(SELECT 1 FROM import_pipeline_items WHERE batch_id = b.id)
                    OR ready_count <> (SELECT COUNT(*) FROM import_pipeline_items WHERE batch_id = b.id AND stage IN ('versionAnalysisPending','versionReviewPending','collectionAnalysisPending','collectionReviewPending','completed'))
                    OR deferred_count <> (SELECT COUNT(*) FROM import_pipeline_items WHERE batch_id = b.id AND stage IN ('metadataDeferred','sourceNeedsAttention')))
                """) ?? 0
            return (recommendations + groups + collections + hidden + batches, deletions)
        }
        if consistencyIssues.0 > 0 {
            issues.append(.init(id: "library-consistency", severity: .warning, title: "Library consistency", detail: "\(consistencyIssues.0) invalid recommendations, groups, visibility flags or import batches", repairable: true))
        }
        if consistencyIssues.1 > 0 {
            issues.append(.init(id: "pending-deletions", severity: .warning, title: "Pending deletion cleanup", detail: "\(consistencyIssues.1) operation(s); uncertain source moves require an explicit retry from book details", repairable: true))
        }
        let orphanCovers = try orphanedFiles(
            directory: appDataURL.appendingPathComponent("Covers", isDirectory: true),
            referencedPaths: referencedAssetPaths(columns: ["cover_path"], table: "library_books")
        )
        if !orphanCovers.isEmpty {
            issues.append(.init(id: "cover-assets", severity: .warning, title: "Cover cache", detail: "\(orphanCovers.count) orphaned file(s)", repairable: true))
        }
        let orphanTagAssets = try orphanedFiles(
            directory: appDataURL.appendingPathComponent(TagVisualAssetService.assetRootDirectoryName, isDirectory: true),
            referencedPaths: referencedTagAssetPaths()
        )
        if !orphanTagAssets.isEmpty {
            issues.append(.init(id: "tag-assets", severity: .warning, title: "TagAssets", detail: "\(orphanTagAssets.count) orphaned file(s)", repairable: true))
        }
        if let coverVectorRepository {
            let existingBookIDs = try databaseManager.dbQueue.read { db in
                Set(try Int64.fetchAll(db, sql: "SELECT id FROM library_books"))
            }
            let orphanVectorCount = try coverVectorRepository.indexedBookIDs().subtracting(existingBookIDs).count
            if orphanVectorCount > 0 {
                issues.append(.init(id: "cover-vectors", severity: .warning, title: "Cover vectors", detail: "\(orphanVectorCount) orphaned vector(s)", repairable: true))
            }
        }
        return DataHealthReport(checkedAt: Timestamp.nowMilliseconds(), issues: issues)
    }

    func repairDerivedData(books: [LibraryBook], tagRepository: TagRepository?, labelRepository: BookVersionLabelRepository?) throws -> DataHealthReport {
        _ = try createInternalBackup(kind: .preRepair)
        for book in books {
            if let bookID = book.databaseID {
                try tagRepository?.rebuildTags(forBookID: bookID, tagsJSON: book.tags)
            }
        }
        try databaseManager.dbQueue.write { db in
            if labelRepository != nil {
                try db.execute(sql: """
                    WITH labels AS MATERIALIZED (
                        SELECT book.id, COALESCE((
                            SELECT GROUP_CONCAT(label, ' / ') FROM (
                                SELECT label FROM book_version_labels WHERE book_id = book.id ORDER BY position
                            )
                        ), '') AS value FROM library_books book
                    )
                    UPDATE library_books SET version_label = labels.value
                    FROM labels WHERE library_books.id = labels.id
                        AND COALESCE(library_books.version_label, '') <> labels.value
                    """)
            }
            try LibraryConsistency.repair(db)
            try SeriesMembership.repair(db)
            try db.execute(sql: """
                DELETE FROM book_reading_state
                WHERE current_page_index < 0 OR total_pages < 0
                   OR (total_pages > 0 AND current_page_index >= total_pages)
                """)
            try db.execute(sql: """
                UPDATE library_books SET collection_id = NULL, collection_order = NULL
                WHERE collection_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM book_collections WHERE id = library_books.collection_id);
                UPDATE library_books SET version_group_id = NULL, is_primary_version = 1
                WHERE version_group_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM book_version_groups WHERE id = library_books.version_group_id);
                DELETE FROM collection_recommendations
                WHERE target_collection_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM book_collections WHERE id = target_collection_id);
                DELETE FROM version_recommendations
                WHERE target_version_group_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM book_version_groups WHERE id = target_version_group_id);
                """)
        }
        try removeOrphanedFiles(
            directory: appDataURL.appendingPathComponent("Covers", isDirectory: true),
            referencedPaths: referencedAssetPaths(columns: ["cover_path"], table: "library_books")
        )
        try removeOrphanedFiles(
            directory: appDataURL.appendingPathComponent(TagVisualAssetService.assetRootDirectoryName, isDirectory: true),
            referencedPaths: referencedTagAssetPaths()
        )
        if let coverVectorRepository {
            let existingBookIDs = try databaseManager.dbQueue.read { db in
                Set(try Int64.fetchAll(db, sql: "SELECT id FROM library_books"))
            }
            _ = try coverVectorRepository.pruneOrphanedVectors(existingBookIDs: existingBookIDs)
        }
        if let semanticTitleVectorRepository {
            let existingBookIDs = try databaseManager.dbQueue.read { db in
                Set(try Int64.fetchAll(db, sql: "SELECT id FROM library_books"))
            }
            _ = try semanticTitleVectorRepository.pruneOrphanedVectors(existingBookIDs: existingBookIDs)
        }
        return try healthCheck()
    }

    private func referencedAssetPaths(columns: [String], table: String) throws -> Set<String> {
        try databaseManager.dbQueue.read { db in
            var paths = Set<String>()
            for column in columns {
                let values = try String.fetchAll(db, sql: "SELECT \(column) FROM \(table) WHERE \(column) IS NOT NULL")
                paths.formUnion(values.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            }
            return paths
        }
    }

    private func referencedTagAssetPaths() throws -> Set<String> {
        let direct = try referencedAssetPaths(
            columns: ["foreground_asset_path", "background_asset_path"],
            table: "tag_visual_profiles"
        )
        var retained = direct
        for path in direct {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    retained.insert(url.standardizedFileURL.path)
                }
            }
        }
        return retained
    }

    private func orphanedFiles(directory: URL, referencedPaths: Set<String>) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path),
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return enumerator.compactMap { value -> URL? in
            guard let url = value as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !referencedPaths.contains(url.standardizedFileURL.path) else { return nil }
            return url
        }
    }

    private func removeOrphanedFiles(directory: URL, referencedPaths: Set<String>) throws {
        for url in try orphanedFiles(directory: directory, referencedPaths: referencedPaths) {
            try fileManager.removeItem(at: url)
        }
    }

    private func createPackage(at packageURL: URL, kind: LibraryBackupKind, replacingExisting: Bool) throws -> LibraryBackupResult {
        if fileManager.fileExists(atPath: packageURL.path) {
            guard replacingExisting else { throw LibraryBackupError.destinationExists }
            try fileManager.removeItem(at: packageURL)
        }
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let destinationQueue = try DatabaseQueue(path: packageURL.appendingPathComponent(Self.databaseFilename).path)
        try databaseManager.dbQueue.backup(to: destinationQueue)

        let sourceAssets = appDataURL.appendingPathComponent(TagVisualAssetService.assetRootDirectoryName, isDirectory: true)
        let includesAssets = fileManager.fileExists(atPath: sourceAssets.path)
        if includesAssets {
            try fileManager.copyItem(at: sourceAssets, to: packageURL.appendingPathComponent(TagVisualAssetService.assetRootDirectoryName, isDirectory: true))
        }
        let manifest = LibraryBackupManifest(
            formatVersion: LibraryBackupManifest.formatVersion,
            appName: "NyaEH",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            schemaVersion: Self.currentSchemaVersion,
            createdAt: Timestamp.nowMilliseconds(),
            kind: kind,
            includesTagAssets: includesAssets,
            excludedAssets: ["source archives", "Covers", "CoverVectors.sqlite", "tag translation cache", "credential files"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: packageURL.appendingPathComponent(Self.manifestFilename), options: .atomic)
        return LibraryBackupResult(packageURL: packageURL, manifest: manifest)
    }

    private func restoreTagAssets(from packageURL: URL, includesAssets: Bool) throws {
        guard includesAssets else { return }
        let source = packageURL.appendingPathComponent(TagVisualAssetService.assetRootDirectoryName, isDirectory: true)
        let destination = appDataURL.appendingPathComponent(TagVisualAssetService.assetRootDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { throw LibraryBackupError.invalidPackage }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func pruneInternalBackups(in directory: URL) throws {
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        try prune(urls.filter { $0.lastPathComponent.hasPrefix("daily-") }, keeping: 7)
        try prune(urls.filter { $0.lastPathComponent.hasPrefix("weekly-") }, keeping: 4)
    }

    private func prune(_ urls: [URL], keeping count: Int) throws {
        let sorted = urls.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for url in sorted.dropFirst(count) {
            try fileManager.removeItem(at: url)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "YYYY-'W'ww"
        return formatter
    }()
}

enum LibraryBackupError: LocalizedError {
    case invalidPackage
    case destinationExists
    case integrityCheckFailed(String)
    case foreignKeyCheckFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPackage: "The selected NyaEH backup package is invalid or newer than this app."
        case .destinationExists: "The backup destination already exists."
        case .integrityCheckFailed(let detail): "The backup database failed integrity check: \(detail)"
        case .foreignKeyCheckFailed(let count): "The backup database contains \(count) foreign-key violation(s)."
        }
    }
}
