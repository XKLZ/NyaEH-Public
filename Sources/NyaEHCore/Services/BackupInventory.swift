// The inventory belongs to this installation, outside the database that a restore replaces.
import Darwin
import Foundation
import GRDB

struct BackupEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: LibraryBackupKind
    var createdAt: Date
    var bytes: Int64
    var includesImages: Bool
    var locationID: UUID?
    var legacy: Bool
    var inode: UInt64
    var sequence = 0
    var pendingRemoval = false
}

struct BackupListing: Sendable {
    var entries: [BackupEntry] = []
    var paths: [UUID: String] = [:]
    var destination = ""
    var pending = false
    var issue: String?
}

struct BackupLocation: Codable {
    var id: UUID
    var path: String
    var bookmark: Data
    var volume: String
    var inode: UInt64
}

private struct BackupRegister: Codable {
    var libraryID = UUID()
    var lastAutomatic: Date?
    var lastAutomaticSequence = 0
    var nextSequence = 0
    var destination: UUID?
    var locations: [BackupLocation] = []
    var entries: [BackupEntry] = []
    var pendingAutomatic = false
    var writing: [BackupEntry] = []
    var issue: String?
}

final class BackupInventory {
    private let root: URL
    private let fm = FileManager.default
    private var state: BackupRegister
    private var local: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    private var register: URL { root.appendingPathComponent("backup-inventory.json") }
    var lastAutomatic: Date? { state.lastAutomatic }
    var pendingAutomatic: Bool { state.pendingAutomatic }
    func markPending() throws {
        if !state.pendingAutomatic { state.pendingAutomatic = true; try save() }
    }

    func containsDestination(_ url: URL) -> Bool {
        let list = listing(pending: false)
        let path = url.resolvingSymlinksInPath().path
        return list.entries.contains { item in
            guard let folder = list.paths[item.id] else { return false }
            let package = URL(fileURLWithPath: folder).appendingPathComponent(item.name).path
            return path == package || path.hasPrefix(package + "/") || package.hasPrefix(path + "/")
        }
    }

    // A separate open-file description per caller serializes also across two app processes.
    static func access<T>(root: URL, _ body: (BackupInventory) throws -> T) throws -> T {
        let fd = open(root.appendingPathComponent(".backup-inventory.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        let inventory = try BackupInventory(root: root)
        try inventory.recoverPublication()
        return try body(inventory)
    }

    private init(root: URL) throws {
        self.root = root
        state = BackupRegister()
        if fm.fileExists(atPath: register.path) {
            state = try JSONDecoder().decode(BackupRegister.self, from: Data(contentsOf: register))
        } else {
            try discoverLegacy()
            try save()
        }
    }

    static let didChange = Notification.Name("NyaEH.backupInventoryChanged")

    private func save() throws {
        try JSONEncoder().encode(state).write(to: register, options: .atomic)
        NotificationCenter.default.post(name: Self.didChange, object: root)
    }

    func setIssue(_ text: String?) throws {
        guard state.issue != text else { return }
        state.issue = text
        try save()
    }

    private func discoverLegacy() throws {
        guard fm.fileExists(atPath: local.path) else { return }
        for url in try fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { continue }
            let name = url.lastPathComponent
            if url.pathExtension == LibraryBackupService.packageExtension,
               let m = try? Self.manifest(url), m.appName == "NyaEH" || m.appName == "TreeC",
               m.kind != .manual, m.backupID == nil, name.hasPrefix(m.kind.rawValue + "-") {
                if let item = try? entry(url, kind: m.kind, date: Date(timeIntervalSince1970: Double(m.createdAt)/1000), images: m.includesTagAssets) {
                    state.entries.append(item)
                }
            } else if name.range(of: #"^(NyaEH|TreeC)-[0-9]{8}-[0-9]{6}\.sqlite$"#, options: .regularExpression) != nil {
                let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                state.entries.append(try entry(url, kind: .preImport, date: date, images: false))
            }
        }
        for item in state.entries.sorted(by: { $0.createdAt > $1.createdAt }) where [.daily, .weekly].contains(item.kind) {
            if (try? LibraryBackupService.validatePackage(local.appendingPathComponent(item.name), scratchRoot: root)) != nil {
                state.lastAutomatic = item.createdAt
                break
            }
        }
    }

    private func entry(_ url: URL, kind: LibraryBackupKind, date: Date, images: Bool) throws -> BackupEntry {
        .init(id: UUID(), name: url.lastPathComponent, kind: kind, createdAt: date, bytes: try Self.bytes(url),
              includesImages: images, legacy: true, inode: try inode(url))
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard let value = attrs[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return value.uint64Value
    }

    static func manifest(_ url: URL) throws -> LibraryBackupManifest {
        try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
    }

    private static func bytes(_ url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let v = try url.resourceValues(forKeys: keys)
        guard v.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
        if v.isRegularFile == true { return Int64(v.fileSize ?? 0) }
        guard v.isDirectory == true else { throw CocoaError(.fileReadUnknown) }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
            .reduce(0) { try $0 + bytes($1) }
    }

    func choose(_ url: URL?) throws {
        guard let url else { state.destination = nil; try save(); return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        try validateQADestination(url)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let identity = try directoryIdentity(url)
        let id = state.locations.first { $0.volume == identity.volume && $0.inode == identity.inode }?.id ?? UUID()
        state.locations.removeAll { $0.id == id }
        state.locations.append(.init(id: id, path: url.path, bookmark: data, volume: identity.volume, inode: identity.inode))
        state.destination = id
        try save()
    }

    private func directoryIdentity(_ url: URL) throws -> (volume: String, inode: UInt64) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .volumeURLKey])
        guard values.isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        // Some network shares have no volume UUID; the scoped bookmark still resolves
        // the volume, and we additionally check its mount path and directory identity.
        let volume = values.volumeUUIDString ?? values.volume?.path
        guard let volume else { throw CocoaError(.fileReadUnknown) }
        return (volume, try inode(url))
    }

    private func validateQADestination(_ url: URL) throws {
        if let runtime = try TestRuntime.current.get(), runtime.profile == "qa" {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(runtime.dataRoot.path + "/") || path.hasPrefix(runtime.sourceRoot.deletingLastPathComponent().path + "/") else {
                throw TestRuntime.failure("Select a folder inside this QA session.")
            }
        }
    }

    private func withDirectory<T>(_ id: UUID?, create: Bool = false, _ body: (URL) throws -> T) throws -> T {
        guard let id else {
            if create { try fm.createDirectory(at: local, withIntermediateDirectories: true) }
            guard local.resolvingSymlinksInPath().path == local.standardizedFileURL.path else { throw CocoaError(.fileReadInvalidFileName) }
            return try body(local)
        }
        guard let index = state.locations.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileReadNoSuchFile) }
        var stale = false
        let base = try URL(resolvingBookmarkData: state.locations[index].bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        let granted = base.startAccessingSecurityScopedResource()
        defer { if granted { base.stopAccessingSecurityScopedResource() } }
        try validateQADestination(base)
        let identity = try directoryIdentity(base)
        guard identity.volume == state.locations[index].volume, identity.inode == state.locations[index].inode else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if stale || base.path != state.locations[index].path {
            state.locations[index].bookmark = try base.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            state.locations[index].path = base.path
            try save()
        }
        let folder = base.appendingPathComponent("NyaEH-" + state.libraryID.uuidString, isDirectory: true)
        guard folder.resolvingSymlinksInPath().path == folder.standardizedFileURL.path else { throw CocoaError(.fileReadInvalidFileName) }
        if create, !fm.fileExists(atPath: folder.path) { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
        return try body(folder)
    }

    func publish(kind: LibraryBackupKind, now: Date?, writer: (URL, UUID, Date) throws -> LibraryBackupManifest) throws -> LibraryBackupResult {
        let id = UUID()
        let location = kind == .automatic ? state.destination : nil
        guard !state.writing.contains(where: { $0.locationID == location }) else { throw CocoaError(.fileWriteUnknown) }
        return try withDirectory(location, create: true) { directory in
            let name = kind.rawValue + "-" + id.uuidString + ".nyaehbackup"
            let url = directory.appendingPathComponent(name, isDirectory: true)
            state.nextSequence += 1
            var item = BackupEntry(id: id, name: name, kind: kind, createdAt: now ?? Date(), bytes: 0,
                                   includesImages: false, locationID: location, legacy: false, inode: 0, sequence: state.nextSequence)
            state.writing.append(item)
            try save()
            let stage = directory.appendingPathComponent(".writing-" + id.uuidString)
            let manifest: LibraryBackupManifest
            do {
                manifest = try writer(stage, id, item.createdAt)
                item.createdAt = now ?? Date()
                item.bytes = try Self.bytes(stage)
                item.inode = try inode(stage)
                state.writing.removeAll { $0.id == id }
                state.writing.append(item)
                try save()
                try fm.moveItem(at: stage, to: url)
            } catch {
                try? fm.removeItem(at: stage)
                state.writing.removeAll { $0.id == item.id }
                try save()
                throw error
            }
            try complete(item)
            return .init(packageURL: url, manifest: manifest)
        }
    }

    private func complete(_ item: BackupEntry) throws {
        state.entries.append(item)
        if item.kind == .automatic, item.sequence > state.lastAutomaticSequence {
            state.lastAutomatic = item.createdAt
            state.lastAutomaticSequence = item.sequence
            state.pendingAutomatic = false
        }
        state.writing.removeAll { $0.id == item.id }
        try save()
    }

    private func recoverPublication() throws {
        for item in state.writing { try recover(item) }
    }

    private func recover(_ item: BackupEntry) throws {
        do {
            try withDirectory(item.locationID) { folder in
                let url = folder.appendingPathComponent(item.name)
                if fm.fileExists(atPath: url.path) {
                    try check(item, url)
                    try complete(item)
                } else {
                    let stage = folder.appendingPathComponent(".writing-" + item.id.uuidString)
                    if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
                    state.writing.removeAll { $0.id == item.id }
                    try save()
                }
            }
        } catch {
            try setIssue(error.localizedDescription)
        }
    }

    private func check(_ item: BackupEntry, _ url: URL) throws {
        guard item.name == url.lastPathComponent, ![".", ".."].contains(item.name),
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
              try inode(url) == item.inode else { throw CocoaError(.fileReadInvalidFileName) }
        if !item.legacy, try Self.manifest(url).backupID != item.id { throw CocoaError(.fileReadCorruptFile) }
    }

    func withEntry<T>(_ id: UUID, _ body: (URL) throws -> T) throws -> T {
        guard let item = state.entries.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        return try withDirectory(item.locationID) { folder in
            let url = folder.appendingPathComponent(item.name)
            try check(item, url)
            return try body(url)
        }
    }

    func trash(_ id: UUID, using move: (URL) throws -> Void) throws {
        guard let item = state.entries.first(where: { $0.id == id }) else { return }
        try withDirectory(item.locationID) { folder in
            let url = folder.appendingPathComponent(item.name)
            do { try check(item, url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                // If the registered folder is accessible, a missing entry may already
                // have reached Trash just before the register was saved.
                _ = try fm.contentsOfDirectory(atPath: folder.path)
                return
            }
            try move(url)
        }
        state.entries.removeAll { $0.id == id }
        try save()
    }

    func rotate(using move: (URL) throws -> Void) throws {
        // A disk can reconnect after newer local snapshots were published.
        let ordered = state.entries.filter { !$0.legacy }.sorted { $0.sequence > $1.sequence }
        let excess = ordered.dropFirst(2)
        for item in ordered.prefix(2) where item.pendingRemoval {
            if let index = state.entries.firstIndex(where: { $0.id == item.id }) {
                state.entries[index].pendingRemoval = false
                try save()
            }
        }
        for item in excess {
            do { try trash(item.id, using: move) }
            catch {
                if let index = state.entries.firstIndex(where: { $0.id == item.id }) {
                    state.entries[index].pendingRemoval = true
                    try setIssue(error.localizedDescription)
                    try save()
                }
            }
        }
        if !state.pendingAutomatic && state.writing.isEmpty && !state.entries.contains(where: \.pendingRemoval) {
            try setIssue(nil)
        }
    }

    func listing(pending: Bool) -> BackupListing {
        func path(_ id: UUID?) -> String {
            guard let id, let loc = state.locations.first(where: { $0.id == id }) else { return local.path }
            return URL(fileURLWithPath: loc.path).appendingPathComponent("NyaEH-" + state.libraryID.uuidString).path
        }
        var listing = BackupListing(entries: state.entries.sorted { $0.createdAt > $1.createdAt },
                                    destination: path(state.destination), pending: pending, issue: state.issue)
        for item in state.entries { listing.paths[item.id] = path(item.locationID) }
        return listing
    }
}
