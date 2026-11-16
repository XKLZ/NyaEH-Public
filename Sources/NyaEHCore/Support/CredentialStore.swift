// 本文件提供 CredentialStore 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation
import Darwin

protocol CredentialStore {
    func string(forKey key: String) throws -> String
    func set(_ value: String, forKey key: String) throws
    func removeValue(forKey key: String) throws
}

enum CredentialStoreFactory {
    static let environmentKey = "NYAEH_CREDENTIAL_STORE"
    static let developmentPlaintextValue = "developmentPlaintext"

    static func appDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any CredentialStore {
        if environment == ProcessInfo.processInfo.environment {
            switch TestRuntime.current {
            case .success(let runtime?): return FileCredentialStore(appDataRoot: runtime.dataRoot, filename: runtime.profile == "development" ? "development-credentials.json" : "credentials.json")
            case .failure: return UnavailableTestCredentialStore()
            case .success(nil):
                if Bundle.main.bundleIdentifier != "com.gazelee.NyaEH" { return UnavailableTestCredentialStore() }
            }
        }
        if environment[environmentKey] == developmentPlaintextValue {
            guard let path = environment[AppDataDirectory.overrideEnvironmentKey], path.hasPrefix("/") else {
                return UnavailableTestCredentialStore()
            }
            // File creation failures must remain development-store failures, never fall back to Keychain.
            return FileCredentialStore(appDataRoot: URL(fileURLWithPath: path), filename: "development-credentials.json")
        }
        do {
            return FileCredentialStore(appDataRoot: try AppDataDirectory.rootURL(environment: environment))
        } catch {
            return FailedCredentialStore(error: error)
        }
    }
}

private struct UnavailableTestCredentialStore: CredentialStore {
    func string(forKey key: String) -> String { "" }
    func set(_ value: String, forKey key: String) throws { throw CredentialFileError.unavailable }
    func removeValue(forKey key: String) throws { throw CredentialFileError.unavailable }
}

private struct FailedCredentialStore: CredentialStore {
    let error: Error
    func string(forKey key: String) throws -> String { throw error }
    func set(_ value: String, forKey key: String) throws { throw error }
    func removeValue(forKey key: String) throws { throw error }
}

private enum CredentialFileError: LocalizedError {
    case unavailable
    var errorDescription: String? { "凭据文件不可用，请检查应用数据目录权限。" }
}

final class FileCredentialStore: CredentialStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        appDataRoot: URL,
        filename: String = "credentials.json",
        fileManager: FileManager = .default
    ) {
        fileURL = appDataRoot
            .appendingPathComponent("Credentials", isDirectory: true)
            .appendingPathComponent(filename)
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func string(forKey key: String) throws -> String {
        let values = try readValues()
        return values[key] ?? LegacyNaming.oldCredentialKey(for: key).flatMap { values[$0] } ?? ""
    }

    func set(_ value: String, forKey key: String) throws {
        if value.isEmpty {
            try removeValue(forKey: key)
            return
        }
        var values = try readValues()
        values[key] = value
        if let oldKey = LegacyNaming.oldCredentialKey(for: key) { values.removeValue(forKey: oldKey) }
        try writeValues(values)
    }

    func removeValue(forKey key: String) throws {
        var values = try readValues()
        values.removeValue(forKey: key)
        if let oldKey = LegacyNaming.oldCredentialKey(for: key) { values.removeValue(forKey: oldKey) }
        try writeValues(values)
    }

    private func readValues() throws -> [String: String] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([String: String].self, from: data)
    }

    private func writeValues(_ values: [String: String]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
        let data = try encoder.encode(values)
        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(".credentials-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { unlink(temporaryURL.path) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            close(descriptor)
            throw error
        }
        guard rename(temporaryURL.path, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
