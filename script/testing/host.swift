// Narrow native process identity helper; never matches or terminates by process name.
import AppKit
import Darwin
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(2) }
func canonicalPath(_ url: URL?) -> String? {
    guard let url, let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
func identity(_ app: NSRunningApplication) -> [String: Any] {
    ["pid": app.processIdentifier, "bundleID": app.bundleIdentifier ?? "", "appPath": canonicalPath(app.bundleURL) ?? "",
     "executable": canonicalPath(app.executableURL) ?? "", "started": app.launchDate?.timeIntervalSince1970 ?? 0]
}
func matches(_ app: NSRunningApplication, _ path: String, _ id: String) -> Bool {
    app.bundleIdentifier == id && canonicalPath(app.bundleURL) == path &&
    canonicalPath(app.executableURL)?.hasPrefix(path + "/Contents/MacOS/") == true
}
guard let command = args.first else { fail("missing command") }
switch command {
case "list":
    guard args.count == 3 else { fail("list path bundleID") }
    let apps = NSWorkspace.shared.runningApplications.filter { matches($0, args[1], args[2]) }.map(identity)
    print(String(data: try JSONSerialization.data(withJSONObject: apps, options: .sortedKeys), encoding: .utf8)!)
case "stop":
    guard args.count == 6, let pid = Int32(args[3]), let started = Double(args[4]), let timeout = Double(args[5]) else { fail("stop path bundleID pid started timeout") }
    guard let app = NSRunningApplication(processIdentifier: pid) else { exit(0) }
    guard matches(app, args[1], args[2]), app.launchDate?.timeIntervalSince1970 == started else { fail("identity mismatch; refusing termination") }
    guard app.terminate() else { fail("graceful termination refused") }
    let deadline = Date().addingTimeInterval(timeout)
    while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if !app.isTerminated { fail("termination timed out; no force kill performed") }
case "preferences-delete":
    let domains = args.dropFirst()
    let qa = "dev.gazelee.NyaEH.qa.", unit = "dev.gazelee.NyaEH.unit."
    guard !domains.isEmpty, domains.allSatisfy({ name in
        if name.hasPrefix(qa) { return UUID(uuidString: String(name.dropFirst(qa.count))) != nil }
        guard name.hasPrefix(unit) else { return false }
        let ids = name.dropFirst(unit.count).components(separatedBy: ".")
        return ids.count == 2 && ids.allSatisfy { UUID(uuidString: $0) != nil }
    }) else { fail("not an isolated test preferences domain") }
    for name in domains {
        let domain = name as CFString
        for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
            if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, host), CFArrayGetCount(keys) > 0 {
                CFPreferencesSetMultiple(nil, keys, domain, kCFPreferencesCurrentUser, host)
            }
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, host) else { fail("preference synchronization failed") }
            if let remaining = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, host), CFArrayGetCount(remaining) != 0 {
                fail("preference domain remains nonempty")
            }
        }
    }
    print("cleared")
default: fail("unknown command")
}
