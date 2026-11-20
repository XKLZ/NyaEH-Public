import CoreFoundation
import Darwin
import Foundation

/// One lease per test process. Closing the descriptor on process death lets the next run recover it.
enum TestRunResources {
    private static let project = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
    private static let id = UUID().uuidString.lowercased()
    private static let registry = project.appending(path: ".nyaeh-verification/unit-runs")
    private static let work = registry.appending(path: id)

    private static let lease: Int32 = {
        do {
            precondition(registry.path == registry.resolvingSymlinksInPath().path, "Unexpected test registry link")
            try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
            let fd = open(registry.appending(path: "\(id).lease").path,
                          O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            precondition(fd >= 0, "Could not acquire test resource lease")
            let marker = "NyaEH run lease \(id)\n"
            let written = marker.withCString { Darwin.write(fd, $0, marker.utf8.count) }
            precondition(written == marker.utf8.count, "Could not register lease identity")
            try lifecycle("begin")
            atexit {
                do {
                    try TestRunResources.flushDomains()
                    // The collector inherits test output and waits on our close-on-exec lease.
                    // Keep the lease until kernel teardown releases pending tasks and SQLite handles.
                    try TestRunResources.lifecycle("end")
                } catch {
                    FileHandle.standardError.write(Data("Test cleanup failed: \(error)\n".utf8))
                    _exit(EXIT_FAILURE)
                }
            }
            return fd
        } catch {
            fatalError("Could not register test resources: \(error)")
        }
    }()

    static var directory: URL {
        _ = lease
        return work.appending(path: "files")
    }

    static func newDefaultsDomain() -> String {
        _ = lease
        let token = UUID().uuidString.lowercased()
        do {
            try Data().write(to: work.appending(path: "domains/\(token)"), options: .withoutOverwriting)
        } catch {
            fatalError("Could not register test preference domain: \(error)")
        }
        return "dev.gazelee.NyaEH.unit.\(id).\(token)"
    }

    // Relinquish the writer's domains before the external collector reconciles disk snapshots.
    private static func flushDomains() throws {
        let tokens = try FileManager.default.contentsOfDirectory(atPath: work.appending(path: "domains").path)
        for token in tokens {
            guard UUID(uuidString: token) != nil else { throw CocoaError(.fileReadCorruptFile) }
            let name = "dev.gazelee.NyaEH.unit.\(id).\(token)"
            UserDefaults.standard.removePersistentDomain(forName: name)
            guard CFPreferencesAppSynchronize(name as CFString) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private static func lifecycle(_ action: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", "-B", project.appending(path: "script/testing/unit_lifecycle.py").path, action, id]
        try process.run()
        if action == "end" { return }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NyaEHTestResources", code: Int(process.terminationStatus))
        }
    }
}
