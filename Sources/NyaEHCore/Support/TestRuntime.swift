// Test hosts fail closed before any app dependencies are created. Production has no profile.
import Foundation
import CryptoKit

struct TestRuntime: Sendable {
    struct OwnedFile: Codable, Sendable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let sha256: String
    }
    struct Ownership: Codable, Sendable {
        let session: String
        let files: [OwnedFile]
    }
    let profile: String
    let session: String
    let dataRoot: URL
    let sourceRoot: URL
    let defaultsSuite: String
    let bundleID: String
    let name: String
    let host: String

    static let current: Result<TestRuntime?, Error> = Result {
        try resolve(environment: ProcessInfo.processInfo.environment,
                    info: Bundle.main.infoDictionary ?? [:], bundleID: Bundle.main.bundleIdentifier,
                    requiresDevelopment: ProcessInfo.processInfo.processName == "NyaEHDevRunner")
    }

    static func resolve(environment env: [String: String], info: [String: Any], bundleID: String?, requiresDevelopment: Bool = false) throws -> TestRuntime? {
        let profile = info["NyaEHTestProfile"] as? String
        let testID = bundleID?.hasPrefix("dev.gazelee.NyaEH") == true
        guard let profile else {
            if requiresDevelopment || testID { throw failure("测试宿主缺少环境标识，请通过项目脚本启动。") }
            return nil
        }
        guard ["development", "qa"].contains(profile), let bundleID,
              let root = info["NyaEHTestDataRoot"] as? String,
              let source = info["NyaEHTestSourceRoot"] as? String,
              let suite = info["NyaEHTestDefaultsSuite"] as? String,
              let session = info["NyaEHTestSession"] as? String,
              let name = info["CFBundleDisplayName"] as? String,
              root.hasPrefix("/"), source.hasPrefix("/"),
              env["NYAEH_APP_SUPPORT_DIR"] == root,
              env["NYAEH_USER_DEFAULTS_SUITE"] == suite,
              env["NYAEH_CREDENTIAL_STORE"] == "developmentPlaintext",
              env["NYAEH_TEST_SESSION"] == session,
              env["NYAEH_TEST_SOURCE_ROOT"] == source else {
            throw failure("测试启动参数缺失或与应用标识不一致；未打开书库。请通过项目脚本启动。")
        }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let sourceURL = URL(fileURLWithPath: source).standardizedFileURL
        guard rootURL.path == rootURL.resolvingSymlinksInPath().path,
              sourceURL.path == sourceURL.resolvingSymlinksInPath().path else {
            throw failure("测试路径包含符号链接或未规范化，已拒绝启动。")
        }
        if profile == "development" {
            guard bundleID == "dev.gazelee.NyaEH", suite == "NyaEH.Development", session == "development",
                  root.hasSuffix("/.nyaeh-dev/Application Support/NyaEH"), source.hasSuffix("/.nyaeh-dev/comic") else {
                throw failure("开发数据目录或偏好域不合法。")
            }
        } else {
            guard UUID(uuidString: session) != nil, bundleID == "dev.gazelee.NyaEH.qa.\(session)",
                  suite == bundleID, root.hasSuffix("/\(session)/Data") || root.contains("/\(bundleID)/Data/Library/Application Support/QA"),
                  source.hasSuffix("/\(session)/Comics") else { throw failure("验收会话身份不合法。") }
            let marker = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: rootURL.appendingPathComponent("ownership.json")))
            guard marker.session == session else { throw failure("验收数据不属于当前会话。") }
        }
        return TestRuntime(profile: profile, session: session, dataRoot: rootURL, sourceRoot: sourceURL,
                           defaultsSuite: suite, bundleID: bundleID, name: name,
                           host: info["NyaEHTestHost"] as? String ?? "swiftpm")
    }

    static func failure(_ text: String) -> NSError { NSError(domain: "NyaEHTestRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    static func validateSourceRoot(_ url: URL) throws {
        guard let runtime = try current.get(), runtime.profile == "qa" else { return }
        guard url.standardizedFileURL == runtime.sourceRoot,
              url.resolvingSymlinksInPath() == runtime.sourceRoot else { throw failure("验收只能使用本会话的合成图库。") }
    }

    static func validateSourceFile(_ url: URL) throws {
        guard let runtime = try current.get(), runtime.profile == "qa" else { return }
        try validateSourceRoot(url.deletingLastPathComponent())
        guard url.standardizedFileURL == url.resolvingSymlinksInPath() else { throw failure("测试文件不能为符号链接。") }
        let marker = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: runtime.dataRoot.appendingPathComponent("ownership.json")))
        guard let owned = marker.files.first(where: { $0.path == url.path }) else { throw failure("此文件未登记为合成测试文件。") }
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
        guard (attrs[.systemNumber] as? NSNumber)?.uint64Value == owned.device,
              (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == owned.inode,
              (attrs[.size] as? NSNumber)?.uint64Value == owned.size,
              SHA256.hash(data: try Data(contentsOf: url)).map({ String(format: "%02x", $0) }).joined() == owned.sha256 else {
            throw failure("测试文件身份已变化，操作已停止。")
        }
    }

    func writeReady() throws {
        var record: [String: Any] = ["session": session, "pid": ProcessInfo.processInfo.processIdentifier,
                                    "host": host, "dataRoot": dataRoot.path, "bundleID": bundleID,
                                    "appPath": Bundle.main.bundleURL.path]
        if let frameworksURL = Bundle.main.privateFrameworksURL,
           let sparkleBundle = Bundle(url: frameworksURL.appendingPathComponent("Sparkle.framework")) {
            record["sparkleCancel"] = sparkleBundle.localizedString(forKey: "Cancel", value: nil, table: "Sparkle")
            record["sparklePreferredLocalizations"] = sparkleBundle.preferredLocalizations
            record["appPreferredLocalizations"] = Bundle.main.preferredLocalizations
        }
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: dataRoot.appendingPathComponent("ready.json"), options: .atomic)
    }

    static func recordTrash(source: URL, target: URL) throws {
        guard let runtime = try current.get(), runtime.profile == "qa" else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let record: [String: Any] = ["session": runtime.session, "source": source.path, "path": target.path,
            "device": attrs[.systemNumber] as? NSNumber ?? 0, "inode": attrs[.systemFileNumber] as? NSNumber ?? 0,
            "size": attrs[.size] as? NSNumber ?? 0,
            "sha256": SHA256.hash(data: try Data(contentsOf: target)).map { String(format: "%02x", $0) }.joined()]
        let folder = runtime.dataRoot.appendingPathComponent("trash-records")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
    }
}
