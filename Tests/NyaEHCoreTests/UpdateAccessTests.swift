import Foundation
import Sparkle
import Testing
@testable import NyaEHCore

struct UpdateAccessTests {
    @Test("Sparkle owns automatic update preferences across settings instances")
    @MainActor
    func automaticUpdateSettingsPersist() throws {
        let bundleID = TestRunResources.newDefaultsDomain()
        let bundleURL = TestRunResources.directory.appendingPathComponent("\(bundleID).app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        defer { UserDefaults(suiteName: bundleID)?.removePersistentDomain(forName: bundleID) }
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Update Settings Test",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))

        let first = SPUUpdaterSettings(hostBundle: bundle)
        first.automaticallyChecksForUpdates = true
        #expect(first.allowsAutomaticUpdates)
        first.automaticallyDownloadsUpdates = true

        let reopened = SPUUpdaterSettings(hostBundle: bundle)
        #expect(reopened.automaticallyChecksForUpdates)
        #expect(reopened.automaticallyDownloadsUpdates)
        reopened.automaticallyChecksForUpdates = false
        #expect(!reopened.allowsAutomaticUpdates)
        #expect(!reopened.automaticallyDownloadsUpdates)
        reopened.automaticallyChecksForUpdates = true
        #expect(reopened.allowsAutomaticUpdates)
        #expect(reopened.automaticallyDownloadsUpdates)
    }

    @Test("Sparkle uses the raw XML endpoint while access checks use the GitHub API")
    @MainActor
    func feedEndpoints() async {
        #expect(UpdateManager.feedURL.absoluteString == "https://raw.githubusercontent.com/XKLZ/NyaEH-Public/main/updates/appcast.xml")
        #expect(GitHubUpdateAccessService.accessCheckURL.absoluteString == "https://api.github.com/repos/XKLZ/NyaEH-Public/contents/updates/appcast.xml?ref=main")

        let service = GitHubUpdateAccessService { request in
            #expect(request.url == GitHubUpdateAccessService.accessCheckURL)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
            return 200
        }
        #expect(await service.resolve() == .publicRepository)
    }

    @Test("public repository does not send Authorization")
    func publicRepository() async {
        let service = GitHubUpdateAccessService { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return 200
        }
        #expect(await service.resolve() == .publicRepository)
    }

    @Test("HTTP 404 never falls back to an authenticated request")
    func unavailablePublicFeed() async {
        let service = GitHubUpdateAccessService { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return 404
        }
        #expect(await service.resolve() == .unavailable("GitHub HTTP 404"))
    }

    @Test("network failure stays distinct from private authentication")
    func offline() async {
        let service = GitHubUpdateAccessService { _ in throw URLError(.notConnectedToInternet) }
        guard case .unavailable = await service.resolve() else {
            Issue.record("Expected an unavailable update source")
            return
        }
    }
}
