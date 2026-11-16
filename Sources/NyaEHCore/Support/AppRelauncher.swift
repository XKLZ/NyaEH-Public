import AppKit

@MainActor
enum AppRelauncher {
    enum RelaunchError: LocalizedError {
        case noApplicationBundle
        case launchFailed
        case testHostRequiresLauncher
        case invalidDevelopmentBundle
        case developmentRestartFailed(URL)

        var errorDescription: String? {
            switch self {
            case .noApplicationBundle: "The running app has no application bundle to reopen."
            case .launchFailed: "macOS did not start a new application instance."
            case .testHostRequiresLauncher: "This isolated test app must be restarted with the verification script."
            case .invalidDevelopmentBundle: "The development app path does not match its launcher."
            case .developmentRestartFailed(let log): "The development app could not restart. See \(log.path)."
            }
        }
    }

    static func relaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        launch: ((URL) async throws -> Bool)? = nil,
        terminate: (() -> Void)? = nil
    ) async throws {
        guard bundleURL.pathExtension == "app" else { throw RelaunchError.noApplicationBundle }
        if launch == nil, let runtime = try TestRuntime.current.get() {
            guard runtime.profile == "development" else { throw RelaunchError.testHostRequiresLauncher }
            try await restartDevelopmentHost(bundleURL: bundleURL, runtime: runtime)
            return // The script stops this exact instance after staging its replacement.
        }
        let didLaunch: Bool
        if let launch {
            didLaunch = try await launch(bundleURL)
        } else {
            didLaunch = try await openNewInstance(at: bundleURL)
        }
        guard didLaunch else { throw RelaunchError.launchFailed }
        (terminate ?? { NSApp.terminate(nil) })()
    }

    private static func openNewInstance(at bundleURL: URL) async throws -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { application, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: application != nil) }
            }
        }
    }

    private static func restartDevelopmentHost(bundleURL: URL, runtime: TestRuntime) async throws {
        let bundle = bundleURL.standardizedFileURL
        let root = bundle.deletingLastPathComponent().deletingLastPathComponent()
        guard bundle == root.appendingPathComponent("dist/NyaEHDev.app"),
              bundle.resolvingSymlinksInPath() == bundle,
              runtime.dataRoot == root.appendingPathComponent(".nyaeh-dev/Application Support/NyaEH"),
              runtime.sourceRoot == root.appendingPathComponent(".nyaeh-dev/comic") else {
            throw RelaunchError.invalidDevelopmentBundle
        }
        let script = root.appendingPathComponent("script/build_and_run.sh")
        let log = root.appendingPathComponent(".nyaeh-dev/restart.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        let process = Process()
        process.executableURL = script
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = output
        let status = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        try? output.close()
        if status != 0 { throw RelaunchError.developmentRestartFailed(log) }
    }
}
