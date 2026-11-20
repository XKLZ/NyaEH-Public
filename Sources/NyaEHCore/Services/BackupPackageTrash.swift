import Foundation
import CryptoKit

enum BackupPackageTrash {
    static func move(_ url: URL) throws {
        let fm = FileManager.default
        let runtime = try TestRuntime.current.get()
        var record: [String: Any] = [:]
        var journal: URL?
        if let runtime, runtime.profile == "qa" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(runtime.dataRoot.path + "/") || path.hasPrefix(runtime.sourceRoot.deletingLastPathComponent().path + "/") else {
                throw TestRuntime.failure("Backup is outside this QA session.")
            }
            let attrs = try fm.attributesOfItem(atPath: path)
            record = ["session": runtime.session, "source": path, "device": attrs[.systemNumber] ?? 0,
                      "inode": attrs[.systemFileNumber] ?? 0, "backupFiles": try fileHashes(url)]
            let folder = runtime.dataRoot.appendingPathComponent("trash-records")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let receipt = folder.appendingPathComponent(UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: record).write(to: receipt, options: .atomic)
            journal = receipt
        }
        var target: NSURL?
        do { try fm.trashItem(at: url, resultingItemURL: &target) }
        catch { if let journal { try? fm.removeItem(at: journal) }; throw error }
        if let journal, let target {
            record["path"] = (target as URL).path
            try JSONSerialization.data(withJSONObject: record).write(to: journal, options: .atomic)
        }
    }

    private static func fileHashes(_ root: URL) throws -> [String: String] {
        func collect(_ url: URL, into files: inout [String: String]) throws {
            let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard v.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
            let key = String(url.path.dropFirst(root.path.count))
            if v.isDirectory == true {
                files[key] = "directory"
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try collect(child, into: &files)
                }
            } else if v.isRegularFile == true {
                files[key] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            } else { throw CocoaError(.fileReadInvalidFileName) }
        }
        var files: [String: String] = [:]
        try collect(root, into: &files)
        return files
    }
}
