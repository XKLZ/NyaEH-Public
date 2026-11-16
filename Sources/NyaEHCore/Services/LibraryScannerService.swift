// 本文件负责扫描本地 .zip/.cbz 书库，提取文件状态、代表 hash、页数和可复用封面缓存。

import CryptoKit
import Foundation
import ZIPFoundation

protocol ArchiveReading {
    func inspectArchive(at archiveURL: URL) throws -> ArchiveInspection
}

struct ArchiveInspection: Equatable {
    var imageCount: Int
    var representativeImageSHA1: String
    var coverImageData: Data?
    var languageCode: String?

    init(
        imageCount: Int,
        representativeImageSHA1: String,
        coverImageData: Data?,
        languageCode: String? = nil
    ) {
        self.imageCount = imageCount
        self.representativeImageSHA1 = representativeImageSHA1
        self.coverImageData = coverImageData
        self.languageCode = languageCode
    }
}

struct LibraryScanResult: Equatable, Sendable {
    var scanned = 0
    var inserted = 0
    var updated = 0
    var missing = 0
    var broken = 0
}

struct LibraryScanProgress: Equatable, Sendable {
    var phase: String
    var completed: Int
    var total: Int

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct LibraryScannerService {
    private static let supportedArchiveExtensions: Set<String> = ["zip", "cbz"]

    private let repository: LibraryBookRepository
    private let fileManager: FileManager
    private let archiveReader: any ArchiveReading
    private let coverCache: (any CoverCaching)?
    private let maxConcurrentArchiveInspections: Int

    init(
        repository: LibraryBookRepository,
        fileManager: FileManager = .default,
        archiveReader: any ArchiveReading = HybridArchiveReader(),
        coverCache: (any CoverCaching)? = try? CoverCacheService.appDefault(),
        maxConcurrentArchiveInspections: Int = 3
    ) {
        self.repository = repository
        self.fileManager = fileManager
        self.archiveReader = archiveReader
        self.coverCache = coverCache
        self.maxConcurrentArchiveInspections = min(3, max(1, maxConcurrentArchiveInspections))
    }

    func scan(
        rootURL: URL,
        progress: @escaping @Sendable (LibraryScanProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> LibraryScanResult {
        let progressReporter = ScanProgressReporter(progress: progress)
        // 扫描阶段只读取 archive 元信息和低优先级语言 hint；E-Hentai/ExHentai 元数据或手动编辑仍是后续权威来源。
        let accessGranted = rootURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        progressReporter.send(.init(phase: "Indexing library", completed: 0, total: 1), force: true)
        let existingBooks = try repository.fetchAll()
        let existingByPath = Dictionary(uniqueKeysWithValues: existingBooks.map { ($0.filepath, $0) })
        let archiveURLs = archiveURLs(in: rootURL)
        let discoveredPaths = Set(archiveURLs.map(\.path))
        let missingByHash = Dictionary(
            grouping: existingBooks.filter {
                !$0.exist || $0.status == .missing || !discoveredPaths.contains($0.filepath)
            },
            by: \.hash
        )
        var result = LibraryScanResult(scanned: archiveURLs.count)
        var seenFilepaths = Set<String>()
        var claimedMovedBookIDs = Set<LibraryBook.DatabaseID>()
        var inserts: [LibraryBook] = []
        var updates: [LibraryBook] = []

        let outcomes = LockedScanOutcomes(count: archiveURLs.count)
        let worker = UncheckedSendableBox(self)
        let operationQueue = OperationQueue()
        operationQueue.name = "NyaEH.LibraryScanner"
        operationQueue.qualityOfService = .utility
        operationQueue.maxConcurrentOperationCount = maxConcurrentArchiveInspections

        for (index, archiveURL) in archiveURLs.enumerated() {
            guard !isCancelled() else { throw CancellationError() }
            let filepath = archiveURL.path
            seenFilepaths.insert(filepath)

            do {
                let localFile = try localFileInfo(for: archiveURL)
                if var existing = existingByPath[filepath],
                   canSkipArchiveRead(for: existing, localFile: localFile) {
                    // 文件大小、mtime 和封面缓存仍有效时跳过 archive 解压，避免刷新书库时重复读取大压缩包。
                    if !existing.exist {
                        existing.exist = true
                        existing.status = .unscanned
                        updates.append(existing)
                        result.updated += 1
                    }
                    continue
                }
                operationQueue.addOperation {
                    if isCancelled() {
                        outcomes.store(.failure(CancellationError()), at: index)
                    } else {
                        outcomes.store(
                            Result { try worker.value.scannedBook(from: archiveURL, localFile: localFile) },
                            at: index
                        )
                    }
                    let completed = outcomes.incrementCompleted()
                    progressReporter.send(
                        .init(phase: "Scanning archives", completed: completed, total: archiveURLs.count)
                    )
                }
            } catch {
                outcomes.store(.failure(error), at: index)
            }
        }

        operationQueue.waitUntilAllOperationsAreFinished()
        guard !isCancelled() else { throw CancellationError() }

        // Worker 完成顺序不影响业务结果；始终按排序后的路径提交，移动匹配和测试均保持确定性。
        for (index, archiveURL) in archiveURLs.enumerated() {
            guard let outcome = outcomes.value(at: index) else { continue }
            let filepath = archiveURL.path
            switch outcome {
            case let .success(scanned):
                if var existing = existingByPath[filepath] {
                    let previousStatus = existing.status
                    let contentChanged = existing.hash.caseInsensitiveCompare(scanned.hash) != .orderedSame
                    let shouldApplyLanguageHint = shouldApplyArchiveLanguageHint(to: existing)
                    existing.hash = scanned.hash
                    existing.coverPath = scanned.coverPath
                    existing.coverHash = scanned.coverHash
                    existing.type = scanned.type
                    existing.fileCount = scanned.fileCount
                    existing.bundleSize = scanned.bundleSize
                    existing.mtime = scanned.mtime
                    existing.exist = true
                    if contentChanged {
                        resetMetadataAfterContentChange(
                            scannedTitle: scanned.title,
                            languageCode: scanned.languageCode,
                            book: &existing
                        )
                    } else {
                        // 重新打包或封面缓存变化但代表 SHA1 未变时，已有权威元数据仍然有效。
                        existing.status = successStatus(afterRescanning: previousStatus)
                    }
                    if !contentChanged && shouldApplyLanguageHint {
                        applyArchiveLanguageHint(scanned.languageCode, to: &existing)
                    }
                    updates.append(existing)
                    result.updated += 1
                } else if let moved = uniquelyMatchedMissingBook(
                    hash: scanned.hash,
                    missingByHash: missingByHash,
                    claimedBookIDs: claimedMovedBookIDs
                ) {
                    var inherited = moved
                    inherited.filepath = scanned.filepath
                    inherited.hash = scanned.hash
                    inherited.coverPath = scanned.coverPath
                    inherited.coverHash = scanned.coverHash
                    inherited.type = scanned.type
                    inherited.fileCount = scanned.fileCount
                    inherited.bundleSize = scanned.bundleSize
                    inherited.mtime = scanned.mtime
                    inherited.status = successStatus(afterRescanning: moved.status)
                    inherited.exist = true
                    if shouldApplyArchiveLanguageHint(to: moved) {
                        applyArchiveLanguageHint(scanned.languageCode, to: &inherited)
                    }
                    if let id = moved.databaseID { claimedMovedBookIDs.insert(id) }
                    updates.append(inherited)
                    result.updated += 1
                } else {
                    inserts.append(scanned)
                    result.inserted += 1
                }
            case let .failure(error):
                if error is CancellationError { throw error }
                result.broken += 1
                if var existing = existingByPath[filepath] {
                    applyBrokenScan(to: &existing)
                    updates.append(existing)
                } else if let brokenBook = try? brokenScannedBook(from: archiveURL) {
                    inserts.append(brokenBook)
                }
            }
        }

        guard !isCancelled() else { throw CancellationError() }
        progressReporter.send(
            .init(phase: "Saving scan changes", completed: archiveURLs.count, total: archiveURLs.count),
            force: true
        )
        let commit = try repository.applyScanChanges(
            inserts: inserts,
            updates: updates,
            seenFilepaths: seenFilepaths
        )
        result.missing = commit.newlyMissing
        progressReporter.send(
            .init(phase: "Scan complete", completed: archiveURLs.count, total: archiveURLs.count),
            force: true
        )
        return result
    }

    func imageFileCount(in archiveURL: URL) throws -> Int {
        try archiveReader.inspectArchive(at: archiveURL).imageCount
    }

    func representativeImageSHA1(in archiveURL: URL) throws -> String {
        try archiveReader.inspectArchive(at: archiveURL).representativeImageSHA1
    }

    func rescanBook(_ book: LibraryBook) throws -> LibraryBook {
        guard book.databaseID != nil else {
            throw NyaEHError.bookHasNoID
        }

        let archiveURL = URL(fileURLWithPath: book.filepath)
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            var missing = book
            missing.status = .missing
            missing.exist = false
            _ = try repository.updateFromScan(missing)
            throw NyaEHError.sourceFileMissing(archiveURL.path)
        }

        let accessGranted = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let scanned = try scannedBook(from: archiveURL)
            var updated = book
            let contentChanged = book.hash.caseInsensitiveCompare(scanned.hash) != .orderedSame
            updated.hash = scanned.hash
            updated.coverPath = scanned.coverPath
            updated.coverHash = scanned.coverHash
            updated.type = scanned.type
            updated.fileCount = scanned.fileCount
            updated.bundleSize = scanned.bundleSize
            updated.mtime = scanned.mtime
            updated.exist = true
            if contentChanged {
                resetMetadataAfterContentChange(
                    scannedTitle: scanned.title,
                    languageCode: scanned.languageCode,
                    book: &updated
                )
            } else {
                updated.status = successStatus(afterRescanning: book.status)
            }
            if !contentChanged, shouldApplyArchiveLanguageHint(to: book) {
                applyArchiveLanguageHint(scanned.languageCode, to: &updated)
            }
            return try repository.updateFromScan(updated)
        } catch {
            var broken = book
            applyBrokenScan(to: &broken)
            _ = try repository.updateFromScan(broken)
            throw error
        }
    }

    private func scannedBook(
        from archiveURL: URL,
        localFile suppliedLocalFile: LocalArchiveFileInfo? = nil
    ) throws -> LibraryBook {
        let inspection = try archiveReader.inspectArchive(at: archiveURL)
        let localFile = try suppliedLocalFile ?? localFileInfo(for: archiveURL)
        let cachedCover = try inspection.coverImageData.flatMap { try coverCache?.cacheCover(originalData: $0) }
        let now = Timestamp.nowMilliseconds()
        let tagsJSON = Self.tagsJSON(languageCode: inspection.languageCode)

        return LibraryBook(
            title: archiveURL.deletingPathExtension().lastPathComponent,
            coverPath: cachedCover?.path,
            hash: inspection.representativeImageSHA1,
            filepath: archiveURL.path,
            type: .archive,
            fileCount: inspection.imageCount,
            bundleSize: localFile.bundleSize,
            mtime: localFile.mtime,
            coverHash: cachedCover?.hash,
            status: .unscanned,
            date: now,
            tags: tagsJSON,
            languageCode: inspection.languageCode ?? "unknown",
            exist: true,
            createdAt: now,
            updatedAt: now
        )
    }

    private func brokenScannedBook(from archiveURL: URL) throws -> LibraryBook {
        var book = try scannedBookWithoutArchiveEntries(from: archiveURL)
        applyBrokenScan(to: &book)
        return book
    }

    private func scannedBookWithoutArchiveEntries(from archiveURL: URL) throws -> LibraryBook {
        let localFile = try localFileInfo(for: archiveURL)
        let now = Timestamp.nowMilliseconds()

        return LibraryBook(
            title: archiveURL.deletingPathExtension().lastPathComponent,
            hash: "broken:\(archiveURL.path)",
            filepath: archiveURL.path,
            type: .archive,
            bundleSize: localFile.bundleSize,
            mtime: localFile.mtime,
            status: .broken,
            date: now,
            tags: "[]",
            exist: fileManager.fileExists(atPath: archiveURL.path),
            createdAt: now,
            updatedAt: now
        )
    }

    private func applyBrokenScan(to book: inout LibraryBook) {
        book.status = .broken
        book.exist = fileManager.fileExists(atPath: book.filepath)
        book.updatedAt = Timestamp.nowMilliseconds()
    }

    private func successStatus(afterRescanning currentStatus: BookStatus) -> BookStatus {
        switch currentStatus {
        case .missing, .broken:
            return .unscanned
        case .unscanned, .correct:
            return currentStatus
        }
    }

    private func resetMetadataAfterContentChange(
        scannedTitle: String,
        languageCode: String?,
        book: inout LibraryBook
    ) {
        // Hash 改变表示当前 archive 不能继续信任旧 gallery 镜像；用户组织和阅读状态仍保留。
        book.title = scannedTitle
        book.titleJpn = nil
        book.rating = nil
        book.tags = Self.tagsJSON(languageCode: languageCode)
        book.pages = nil
        book.posted = nil
        book.filesize = nil
        book.category = nil
        book.url = nil
        book.status = .unscanned
        book.languageCode = languageCode ?? "unknown"
        book.isTranslated = false
        book.isFullColor = false
        book.censorship = "unknown"
        book.hasExtraneousAds = false
    }

    private func archiveURLs(in rootURL: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL else {
                return nil
            }

            let ext = url.pathExtension.lowercased()
            guard Self.supportedArchiveExtensions.contains(ext) else {
                return nil
            }

            return url
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func uniquelyMatchedMissingBook(
        hash: String,
        missingByHash: [String: [LibraryBook]],
        claimedBookIDs: Set<LibraryBook.DatabaseID>
    ) -> LibraryBook? {
        let candidates = (missingByHash[hash] ?? []).filter { book in
            guard let id = book.databaseID else { return false }
            return !claimedBookIDs.contains(id)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func localFileInfo(for archiveURL: URL) throws -> LocalArchiveFileInfo {
        let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
        let bundleSize = (attributes[.size] as? NSNumber)?.int64Value
        let mtime = (attributes[.modificationDate] as? Date).map {
            Int64(($0.timeIntervalSince1970 * 1000).rounded())
        }
        return LocalArchiveFileInfo(bundleSize: bundleSize, mtime: mtime)
    }

    private func canSkipArchiveRead(for book: LibraryBook, localFile: LocalArchiveFileInfo) -> Bool {
        book.bundleSize == localFile.bundleSize
            && book.mtime == localFile.mtime
            && !book.hash.isEmpty
            && book.fileCount != nil
            && book.coverHash != nil
            && coverCache?.cachedCoverExists(path: book.coverPath) == true
    }

    private func shouldApplyArchiveLanguageHint(to book: LibraryBook) -> Bool {
        let languageCode = book.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return book.status == .unscanned && (languageCode.isEmpty || languageCode == "unknown")
    }

    private func applyArchiveLanguageHint(_ languageCode: String?, to book: inout LibraryBook) {
        guard let languageCode else {
            return
        }
        book.languageCode = languageCode
        book.tags = Self.tagsJSON(languageCode: languageCode, existingTagsJSON: book.tags)
    }

    private static func tagsJSON(languageCode: String?, existingTagsJSON: String = "[]") -> String {
        guard let languageCode else {
            return existingTagsJSON
        }

        let languageTag = "language:\(languageCode)"
        let existingTags = (try? JSONDecoder().decode([String].self, from: Data(existingTagsJSON.utf8))) ?? []
        var normalizedTags: [String] = []
        var seen = Set<String>()

        for tag in existingTags + [languageTag] {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                continue
            }
            normalizedTags.append(trimmed)
        }

        guard let data = try? JSONEncoder().encode(normalizedTags),
              let json = String(data: data, encoding: .utf8) else {
            return existingTagsJSON
        }
        return json
    }
}

private final class ScanProgressReporter: @unchecked Sendable {
    private let progress: @Sendable (LibraryScanProgress) -> Void
    private let lock = NSLock()
    private var lastSentAt = ContinuousClock.now

    init(progress: @escaping @Sendable (LibraryScanProgress) -> Void) {
        self.progress = progress
    }

    func send(_ value: LibraryScanProgress, force: Bool = false) {
        lock.lock()
        let now = ContinuousClock.now
        let shouldSend = force || lastSentAt.duration(to: now) >= .milliseconds(100)
        if shouldSend { lastSentAt = now }
        lock.unlock()
        if shouldSend { progress(value) }
    }
}

private final class LockedScanOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<LibraryBook, Error>?]
    private var completed = 0

    init(count: Int) {
        outcomes = Array(repeating: nil, count: count)
    }

    func store(_ outcome: Result<LibraryBook, Error>, at index: Int) {
        lock.withLock {
            outcomes[index] = outcome
        }
    }

    func value(at index: Int) -> Result<LibraryBook, Error>? {
        lock.withLock { outcomes[index] }
    }

    func incrementCompleted() -> Int {
        lock.withLock {
            completed += 1
            return completed
        }
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private struct LocalArchiveFileInfo {
    var bundleSize: Int64?
    var mtime: Int64?
}

struct HybridArchiveReader: ArchiveReading {
    private let primary: any ArchiveReading
    private let fallback: any ArchiveReading

    init(
        primary: any ArchiveReading = ZIPFoundationArchiveReader(),
        fallback: any ArchiveReading = SystemZipArchiveReader()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    func inspectArchive(at archiveURL: URL) throws -> ArchiveInspection {
        do {
            return try primary.inspectArchive(at: archiveURL)
        } catch {
            return try fallback.inspectArchive(at: archiveURL)
        }
    }
}

struct ZIPFoundationArchiveReader: ArchiveReading {
    func inspectArchive(at archiveURL: URL) throws -> ArchiveInspection {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let entries = imageEntries(in: archive)
        let entry = try representativeImageEntry(from: entries)
        let coverEntry = entries[ArchiveImagePath.coverIndex]
        let hash = try sha1(for: entry, in: archive)
        let coverData = try? data(for: coverEntry, in: archive)
        let languageCode = infoJSONEntry(in: archive).flatMap { entry in
            try? data(for: entry, in: archive)
        }.flatMap(ArchiveInfoLanguageParser.languageCode(from:))
        return ArchiveInspection(
            imageCount: entries.count,
            representativeImageSHA1: hash,
            coverImageData: coverData,
            languageCode: languageCode
        )
    }

    private func imageEntries(in archive: Archive) -> [Entry] {
        archive.compactMap { entry in
            guard ArchiveImagePath.isSupported(entry.path) else {
                return nil
            }
            return entry
        }
        .sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func representativeImageEntry(from entries: [Entry]) throws -> Entry {
        guard !entries.isEmpty else {
            throw NyaEHError.archiveContainsNoImages
        }

        return entries[ArchiveImagePath.representativeIndex(forImageCount: entries.count)]
    }

    private func infoJSONEntry(in archive: Archive) -> Entry? {
        let entries = archive.filter { entry in
            URL(fileURLWithPath: entry.path).lastPathComponent.lowercased() == "info.json"
        }
        return entries.first { $0.path.lowercased() == "info.json" }
            ?? entries.sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }.first
    }

    private func sha1(for entry: Entry, in archive: Archive) throws -> String {
        var hasher = Insecure.SHA1()

        _ = try archive.extract(entry) { data in
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func data(for entry: Entry, in archive: Archive) throws -> Data {
        var output = Data()
        _ = try archive.extract(entry) { data in
            output.append(data)
        }
        return output
    }
}

struct SystemZipArchiveReader: ArchiveReading {
    private let zipinfoPath: String
    private let unzipPath: String

    init(zipinfoPath: String = "/usr/bin/zipinfo", unzipPath: String = "/usr/bin/unzip") {
        self.zipinfoPath = zipinfoPath
        self.unzipPath = unzipPath
    }

    func inspectArchive(at archiveURL: URL) throws -> ArchiveInspection {
        let paths = try imagePaths(in: archiveURL)
        guard !paths.isEmpty else {
            throw NyaEHError.archiveContainsNoImages
        }

        let representativePath = paths[ArchiveImagePath.representativeIndex(forImageCount: paths.count)]
        let data = try extractData(from: archiveURL, entryPath: representativePath)
        let coverPath = paths[ArchiveImagePath.coverIndex]
        let coverData = try? extractData(from: archiveURL, entryPath: coverPath)
        let languageCode = infoJSONPath(in: archiveURL).flatMap { path in
            try? extractData(from: archiveURL, entryPath: path)
        }.flatMap(ArchiveInfoLanguageParser.languageCode(from:))
        return ArchiveInspection(
            imageCount: paths.count,
            representativeImageSHA1: sha1Hex(data),
            coverImageData: coverData,
            languageCode: languageCode
        )
    }

    private func imagePaths(in archiveURL: URL) throws -> [String] {
        let output = try runProcess(
            executablePath: zipinfoPath,
            arguments: ["-1", archiveURL.path]
        )

        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter(ArchiveImagePath.isSupported)
            .sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    private func allPaths(in archiveURL: URL) throws -> [String] {
        let output = try runProcess(
            executablePath: zipinfoPath,
            arguments: ["-1", archiveURL.path]
        )

        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func infoJSONPath(in archiveURL: URL) -> String? {
        guard let paths = try? allPaths(in: archiveURL) else {
            return nil
        }
        let infoPaths = paths.filter {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "info.json"
        }
        return infoPaths.first { $0.lowercased() == "info.json" }
            ?? infoPaths.sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }.first
    }

    private func extractData(from archiveURL: URL, entryPath: String) throws -> Data {
        try runProcessForData(
            executablePath: unzipPath,
            arguments: ["-p", archiveURL.path, entryPath]
        )
    }

    private func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func runProcess(executablePath: String, arguments: [String]) throws -> String {
        let data = try runProcessForData(executablePath: executablePath, arguments: arguments)
        return String(decoding: data, as: UTF8.self)
    }

    private func runProcessForData(executablePath: String, arguments: [String]) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: errorOutput, as: UTF8.self)
            throw NyaEHError.unreadableArchive(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }
}

private enum ArchiveInfoLanguageParser {
    static func languageCode(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let galleryInfo = root["gallery_info"] as? [String: Any]
        else {
            return nil
        }

        if let language = normalizedLanguageCode(galleryInfo["language"]) {
            return language
        }

        guard let tags = galleryInfo["tags"] as? [String: Any],
              let languages = tags["language"] as? [Any] else {
            return nil
        }

        return languages.compactMap(normalizedLanguageCode).first
    }

    private static func normalizedLanguageCode(_ value: Any?) -> String? {
        guard let rawLanguage = value as? String else {
            return nil
        }

        let language = rawLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !language.isEmpty, language != "unknown" else {
            return nil
        }

        let pattern = #"^[a-z0-9][a-z0-9 _-]{0,63}$"#
        guard language.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        return language
    }
}

private enum ArchiveImagePath {
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "bmp", "avif"
    ]

    static func isSupported(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    static func representativeIndex(forImageCount count: Int) -> Int {
        count >= 8 ? 7 : 0
    }

    static var coverIndex: Int {
        0
    }
}
