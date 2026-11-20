// 本文件负责主库与不可重建 TagAssets 的备份、恢复、保留策略和基础一致性检查。

import Foundation
import GRDB

struct LibraryBackupService: @unchecked Sendable {
    static let packageExtension = "nyaehbackup"
    static let databaseFilename = "NyaEH.sqlite"
    static let manifestFilename = "manifest.json"
    static let currentSchemaVersion = 23

    private let databaseManager: DatabaseManager
    private let appDataURL: URL
    private let coverVectorRepository: CoverVectorRepository?
    private let semanticTitleVectorRepository: SemanticTitleVectorRepository?
    private let fileManager: FileManager

    private let trash: (URL) throws -> Void

    init(
        databaseManager: DatabaseManager,
        appDataURL: URL,
        coverVectorRepository: CoverVectorRepository? = nil,
        semanticTitleVectorRepository: SemanticTitleVectorRepository? = nil,
        fileManager: FileManager = .default,
        trash: @escaping (URL) throws -> Void = BackupPackageTrash.move
    ) {
        self.databaseManager = databaseManager
        self.appDataURL = appDataURL
        self.coverVectorRepository = coverVectorRepository
        self.semanticTitleVectorRepository = semanticTitleVectorRepository
        self.trash = trash
        self.fileManager = fileManager
    }

    func export(to url: URL, includeImages: Bool = false) throws -> LibraryBackupResult {
        guard url.pathExtension == Self.packageExtension else { throw LibraryBackupError.invalidPackage }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try BackupInventory.access(root: appDataURL) { inventory in
            guard !inventory.containsDestination(url) else { throw LibraryBackupError.destinationExists }
            let stage = url.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString)
            defer { try? fileManager.removeItem(at: stage) }
            let manifest = try writePackage(at: stage, kind: .manual, includeImages: includeImages)
            if fileManager.fileExists(atPath: url.path) {
                _ = try validate(packageURL: url)
                _ = try fileManager.replaceItemAt(url, withItemAt: stage)
            } else { try fileManager.moveItem(at: stage, to: url) }
            return .init(packageURL: url, manifest: manifest)
        }
    }

    private func publish(_ kind: LibraryBackupKind, in inventory: BackupInventory, now: Date? = nil,
                         schema: Int = Self.currentSchemaVersion) throws -> LibraryBackupResult {
        try inventory.publish(kind: kind, now: now) { url, id, created in
            try writePackage(at: url, kind: kind, id: id, now: created, schema: schema)
        }
    }

    func protectedOperation<T>(_ kind: LibraryBackupKind, schema: Int = Self.currentSchemaVersion,
                               perform: (LibraryBackupResult) throws -> T) throws -> T {
        try BackupInventory.access(root: appDataURL) { inventory in
            let snapshot = try publish(kind, in: inventory, schema: schema)
            defer { try? inventory.rotate(using: trash) }
            return try perform(snapshot)
        }
    }

    private func isDue(_ inventory: BackupInventory) throws -> Bool {
        if inventory.pendingAutomatic { return true }
        let changed = try databaseManager.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT changed_at FROM backup_membership_event WHERE id = 1")
        }
        guard let changed else { return false }
        guard let last = inventory.lastAutomatic else { return true }
        return changed >= Int64((last.timeIntervalSince1970 * 1000).rounded()) + 168 * 3600 * 1000
    }

    func reconcile(now: Date? = nil) throws {
        try BackupInventory.access(root: appDataURL) { inventory in
            if try isDue(inventory) {
                try inventory.markPending()
                do {
                    _ = try publish(.automatic, in: inventory, now: now)
                    try inventory.setIssue(nil)
                } catch {
                    try inventory.setIssue(error.localizedDescription)
                    throw error
                }
            }
            try inventory.rotate(using: trash)
        }
    }

    func listing() throws -> BackupListing {
        try BackupInventory.access(root: appDataURL) { try $0.listing(pending: isDue($0)) }
    }

    func chooseLocation(_ url: URL?) throws {
        try BackupInventory.access(root: appDataURL) { try $0.choose(url) }
        try reconcile()
    }

    func delete(_ ids: Set<UUID>) throws {
        try BackupInventory.access(root: appDataURL) { inventory in
            var failures: [String] = []
            for id in ids {
                do { try inventory.trash(id, using: trash) }
                catch { failures.append(error.localizedDescription) }
            }
            try inventory.rotate(using: trash)
            if !failures.isEmpty {
                throw NSError(domain: "NyaEH.Backups", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: failures.joined(separator: "\n")
                ])
            }
        }
    }

    func validate(packageURL: URL) throws -> LibraryBackupManifest { try Self.validatePackage(packageURL, scratchRoot: appDataURL) }

    static func validatePackage(_ packageURL: URL, scratchRoot: URL) throws -> LibraryBackupManifest {
        let manifest = try BackupInventory.manifest(packageURL)
        guard manifest.formatVersion == LibraryBackupManifest.formatVersion, manifest.schemaVersion <= currentSchemaVersion else {
            throw LibraryBackupError.invalidPackage
        }
        try checkDatabase(at: databaseURL(in: packageURL), scratchRoot: scratchRoot)
        return manifest
    }

    private static func withReader<T>(_ url: URL, scratchRoot: URL, read: (DatabaseQueue) throws -> T) throws -> T {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw LibraryBackupError.invalidPackage }
        var config = Configuration()
        config.readonly = true
        let reader: DatabaseQueue
        do { reader = try DatabaseQueue(path: url.path, configuration: config) }
        catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN || error.resultCode == .SQLITE_READONLY {
            // Old exports retained the WAL header. SQLite on macOS may require writable
            // sidecars just to open these snapshots. Recover on a private copy.
            let fm = FileManager.default
            let staging = scratchRoot.appendingPathComponent(".backup-reader-" + UUID().uuidString)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: staging) }
            let copied = staging.appendingPathComponent(databaseFilename)
            try fm.copyItem(at: url, to: copied)
            let wal = URL(fileURLWithPath: url.path + "-wal")
            if fm.fileExists(atPath: wal.path) {
                guard wal.resolvingSymlinksInPath().path == wal.path else { throw LibraryBackupError.invalidPackage }
                try fm.copyItem(at: wal, to: URL(fileURLWithPath: copied.path + "-wal"))
            }
            let queue = try DatabaseQueue(path: copied.path)
            return try read(queue)
        }
        return try read(reader)
    }

    private static func checkDatabase(at url: URL, scratchRoot: URL) throws {
        try withReader(url, scratchRoot: scratchRoot) { queue in try queue.read { db in
            guard try db.tableExists("library_books"), try db.tableExists("grdb_migrations") else { throw LibraryBackupError.invalidPackage }
            let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            guard integrity == ["ok"] else { throw LibraryBackupError.integrityCheckFailed(integrity.joined(separator: ", ")) }
            let references = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            guard references.isEmpty else { throw LibraryBackupError.foreignKeyCheckFailed(references.count) }
        } }
    }

    private static func databaseURL(in package: URL) -> URL {
        let current = package.appendingPathComponent(databaseFilename)
        return FileManager.default.fileExists(atPath: current.path) ? current : package.appendingPathComponent(LegacyNaming.databaseFilename)
    }

    func restore(from url: URL) throws -> LibraryBackupResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try BackupInventory.access(root: appDataURL) { try restore(url, inventory: $0) }
    }

    func restore(id: UUID) throws -> LibraryBackupResult {
        try BackupInventory.access(root: appDataURL) { inventory in
            try inventory.withEntry(id) { try restore($0, inventory: inventory) }
        }
    }

    private func restore(_ url: URL, inventory: BackupInventory) throws -> LibraryBackupResult {
        let manifest: LibraryBackupManifest
        let source: URL
        if url.pathExtension == "sqlite" {
            try Self.checkDatabase(at: url, scratchRoot: appDataURL)
            source = url
            manifest = try Self.withReader(url, scratchRoot: appDataURL) { try databaseManifest(source: $0, kind: .preImport) }
            guard manifest.schemaVersion <= Self.currentSchemaVersion else { throw LibraryBackupError.invalidPackage }
        } else {
            manifest = try validate(packageURL: url)
            source = Self.databaseURL(in: url)
        }
        let rollback = try publish(.preRestore, in: inventory)
        defer { try? inventory.rotate(using: trash) }
        let assets = appDataURL.appendingPathComponent("TagAssets")
        let staging = appDataURL.appendingPathComponent(".restore-" + UUID().uuidString)
        let previous = staging.appendingPathComponent("previous")
        let incoming = staging.appendingPathComponent("incoming")
        var movedPrevious = false
        var keepStaging = false
        defer { if !keepStaging { try? fileManager.removeItem(at: staging) } }
        if manifest.includesTagAssets {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let packaged = url.appendingPathComponent("TagAssets")
            try Self.checkAssetTree(packaged)
            try fileManager.copyItem(at: packaged, to: incoming)
        }
        do {
            try Self.withReader(source, scratchRoot: appDataURL) { try $0.backup(to: databaseManager.dbQueue) }
            try DatabaseMigrator.nyaeh.migrate(databaseManager.dbQueue)
            // A restored book set is not a new scan or deletion in this installation.
            try databaseManager.dbQueue.write { try $0.execute(sql: "DELETE FROM backup_membership_event") }
            if manifest.includesTagAssets {
                if fileManager.fileExists(atPath: assets.path) {
                    try fileManager.moveItem(at: assets, to: previous)
                    movedPrevious = true
                }
                try fileManager.moveItem(at: incoming, to: assets)
            }
            try? semanticTitleVectorRepository?.clear()
            return .init(packageURL: url, manifest: manifest)
        } catch {
            keepStaging = true
            try Self.withReader(Self.databaseURL(in: rollback.packageURL), scratchRoot: appDataURL) { try $0.backup(to: databaseManager.dbQueue) }
            if movedPrevious { try fileManager.moveItem(at: previous, to: assets) }
            keepStaging = false
            throw error
        }
    }

    private static func checkAssetTree(_ root: URL) throws {
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { throw LibraryBackupError.invalidPackage }
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw LibraryBackupError.invalidPackage }
            if values.isDirectory == true { try checkAssetTree(child) }
            else if values.isRegularFile != true { throw LibraryBackupError.invalidPackage }
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
        try protectedOperation(.preRepair) { _ in
            try repairAfterBackup(books: books, tagRepository: tagRepository, labelRepository: labelRepository)
        }
    }

    private func repairAfterBackup(books: [LibraryBook], tagRepository: TagRepository?, labelRepository: BookVersionLabelRepository?) throws -> DataHealthReport {
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

    private func databaseManifest(source: any DatabaseReader, kind: LibraryBackupKind) throws -> LibraryBackupManifest {
        let version = try source.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").compactMap { id in
                id.first == "v" ? Int(id.dropFirst().prefix { $0.isNumber }) : nil
            }.max() ?? 0
        }
        return .init(formatVersion: 1, appName: "NyaEH", appVersion: "legacy", schemaVersion: version,
                     createdAt: 0, kind: kind, includesTagAssets: false, excludedAssets: [])
    }

    private func writePackage(at url: URL, kind: LibraryBackupKind, id: UUID? = nil, now: Date = Date(),
                              schema: Int = Self.currentSchemaVersion, includeImages: Bool = false) throws -> LibraryBackupManifest {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        let db = try DatabaseQueue(path: url.appendingPathComponent(Self.databaseFilename).path)
        try databaseManager.dbQueue.backup(to: db)
        var includes = false
        if includeImages {
            let paths = try db.read { db in
                try String.fetchAll(db, sql: """
                    SELECT foreground_asset_path FROM tag_visual_profiles WHERE foreground_asset_path IS NOT NULL
                    UNION SELECT background_asset_path FROM tag_visual_profiles WHERE background_asset_path IS NOT NULL
                    """)
            }
            for path in paths where !path.isEmpty {
                let source = appDataURL.appendingPathComponent(path)
                guard path.hasPrefix("TagAssets/"), !path.split(separator: "/").contains(".."),
                      source.standardizedFileURL.path == source.resolvingSymlinksInPath().path,
                      try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryBackupError.invalidPackage }
                let destination = url.appendingPathComponent(path)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                includes = true
            }
        }
        try db.close()
        // SQLite backup can copy a WAL database header into an initially empty
        // destination. Reopen before switching modes so SQLite reads that header.
        let databaseURL = url.appendingPathComponent(Self.databaseFilename)
        let finalizer = try DatabaseQueue(path: databaseURL.path)
        try finalizer.writeWithoutTransaction { db in
            guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete" else {
                throw LibraryBackupError.invalidPackage
            }
        }
        try finalizer.close()
        // macOS can retain an empty WAL or a shared-memory file after closing.
        // This is an unpublished staging directory; both connections are closed.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) { try fileManager.removeItem(at: sidecar) }
        }
        let m = LibraryBackupManifest(formatVersion: 1, appName: "NyaEH",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            schemaVersion: schema, createdAt: Int64((now.timeIntervalSince1970 * 1000).rounded()), kind: kind,
            includesTagAssets: includes, excludedAssets: ["source archives", "rebuildable caches", "credentials", "preferences"] + (includes ? [] : ["TagAssets"]), backupID: id)
        try JSONEncoder().encode(m).write(to: url.appendingPathComponent(Self.manifestFilename), options: .atomic)
        return m
    }

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
