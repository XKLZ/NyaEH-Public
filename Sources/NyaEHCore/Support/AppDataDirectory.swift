// 本文件提供 AppDataDirectory 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation

enum AppDataDirectory {
    static let overrideEnvironmentKey = "NYAEH_APP_SUPPORT_DIR"
    static let appDirectoryName = "NyaEH"
    static let legacyAppDirectoryName = LegacyNaming.applicationSupportDirectory

    static func rootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil,
        createIfNeeded: Bool = true
    ) throws -> URL {
        let root: URL

        if environment == ProcessInfo.processInfo.environment,
           let runtime = try TestRuntime.current.get() {
            root = runtime.dataRoot
        } else if let overridePath = environment[overrideEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            root = URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let supportDirectory: URL
            if let applicationSupportDirectory {
                supportDirectory = applicationSupportDirectory
            } else {
                guard let defaultSupportDirectory = fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw NyaEHError.missingDatabaseDirectory
                }
                supportDirectory = defaultSupportDirectory
            }

            root = try productionRootURL(
                supportDirectory: supportDirectory,
                fileManager: fileManager,
                createIfNeeded: createIfNeeded
            )
        }

        if createIfNeeded {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        return root
    }

    private static func productionRootURL(
        supportDirectory: URL,
        fileManager: FileManager,
        createIfNeeded: Bool
    ) throws -> URL {
        let root = supportDirectory.appendingPathComponent(appDirectoryName, isDirectory: true)

        guard createIfNeeded else {
            return root
        }

        let legacyRoot = supportDirectory.appendingPathComponent(legacyAppDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: root.path),
           fileManager.fileExists(atPath: legacyRoot.path) {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacyRoot, to: root)
        }

        return root
    }
}
