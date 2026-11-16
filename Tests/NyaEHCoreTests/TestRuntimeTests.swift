import Foundation
import Testing
@testable import NyaEHCore

@Suite("Test host isolation")
struct TestRuntimeTests {
    private func fixture() throws -> (URL, [String: String], [String: Any]) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let data = root.appendingPathComponent(".nyaeh-dev/Application Support/NyaEH")
        let source = root.appendingPathComponent(".nyaeh-dev/comic")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let env = ["NYAEH_APP_SUPPORT_DIR": data.path, "NYAEH_USER_DEFAULTS_SUITE": "NyaEH.Development",
                   "NYAEH_CREDENTIAL_STORE": "developmentPlaintext", "NYAEH_TEST_SESSION": "development", "NYAEH_TEST_SOURCE_ROOT": source.path]
        let info: [String: Any] = ["NyaEHTestProfile": "development", "NyaEHTestDataRoot": data.path, "NyaEHTestSourceRoot": source.path,
                                  "NyaEHTestDefaultsSuite": "NyaEH.Development", "NyaEHTestSession": "development", "CFBundleDisplayName": "NyaEH 开发版"]
        return (root, env, info)
    }

    @Test func developmentCredentialsNeverFallBackToKeychain() {
        let missing = CredentialStoreFactory.appDefault(environment: ["NYAEH_CREDENTIAL_STORE": "developmentPlaintext"])
        #expect(!(missing is FileCredentialStore))
        let unwritable = CredentialStoreFactory.appDefault(environment: ["NYAEH_CREDENTIAL_STORE": "developmentPlaintext", "NYAEH_APP_SUPPORT_DIR": "/dev/null/invalid"])
        #expect(unwritable is FileCredentialStore)
    }

    @Test func productionHasNoTestProfile() throws {
        #expect(try TestRuntime.resolve(environment: [:], info: [:], bundleID: "com.gazelee.NyaEH") == nil)
    }

    @Test func developmentWithoutMarkerFailsClosed() {
        #expect(throws: (any Error).self) { try TestRuntime.resolve(environment: [:], info: [:], bundleID: "dev.gazelee.NyaEH") }
        #expect(throws: (any Error).self) { try TestRuntime.resolve(environment: [:], info: [:], bundleID: nil, requiresDevelopment: true) }
    }

    @Test func missingOrMismatchedInputsLeaveSentinelUnchanged() throws {
        let (root, env, info) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("production.sqlite")
        try Data("untouched".utf8).write(to: sentinel)
        for key in env.keys {
            var missing = env; missing[key] = nil
            #expect(throws: (any Error).self) { try TestRuntime.resolve(environment: missing, info: info, bundleID: "dev.gazelee.NyaEH") }
            var wrong = env; wrong[key] = sentinel.path
            #expect(throws: (any Error).self) { try TestRuntime.resolve(environment: wrong, info: info, bundleID: "dev.gazelee.NyaEH") }
        }
        #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
        #expect(try TestRuntime.resolve(environment: env, info: info, bundleID: "dev.gazelee.NyaEH")?.profile == "development")
    }

    @Test func symlinkDataRootIsRejected() throws {
        let (root, originalEnv, originalInfo) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(".nyaeh-dev"))
        var env = originalEnv; var info = originalInfo
        let path = link.appendingPathComponent("Application Support/NyaEH").path
        env["NYAEH_APP_SUPPORT_DIR"] = path; info["NyaEHTestDataRoot"] = path
        #expect(throws: (any Error).self) { try TestRuntime.resolve(environment: env, info: info, bundleID: "dev.gazelee.NyaEH") }
    }

    @Test func qaRequiresMatchingOwnership() throws {
        let (root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString.lowercased(), id = "dev.gazelee.NyaEH.qa."
        let data = root.appendingPathComponent(session + "/Data"), source = root.appendingPathComponent(session + "/Comics")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let env = ["NYAEH_APP_SUPPORT_DIR": data.path, "NYAEH_USER_DEFAULTS_SUITE": id + session,
                   "NYAEH_CREDENTIAL_STORE": "developmentPlaintext", "NYAEH_TEST_SESSION": session, "NYAEH_TEST_SOURCE_ROOT": source.path]
        let info: [String: Any] = ["NyaEHTestProfile": "qa", "NyaEHTestDataRoot": data.path, "NyaEHTestSourceRoot": source.path,
                                  "NyaEHTestDefaultsSuite": id + session, "NyaEHTestSession": session, "CFBundleDisplayName": "QA"]
        #expect(throws: (any Error).self) { try TestRuntime.resolve(environment: env, info: info, bundleID: id + session) }
        try JSONEncoder().encode(TestRuntime.Ownership(session: session, files: [])).write(to: data.appendingPathComponent("ownership.json"))
        #expect(try TestRuntime.resolve(environment: env, info: info, bundleID: id + session)?.session == session)
        try JSONEncoder().encode(TestRuntime.Ownership(session: UUID().uuidString, files: [])).write(to: data.appendingPathComponent("ownership.json"))
        #expect(throws: (any Error).self) { try TestRuntime.resolve(environment: env, info: info, bundleID: id + session) }
    }
}
