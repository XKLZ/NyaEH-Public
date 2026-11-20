import Foundation
import Darwin
import Testing
@testable import NyaEHCore

@Suite("Local gallery highlight")
struct LocalHighlightTests {
    @Test("gallery URL parser accepts E-Hentai and ExHentai gallery URLs")
    func parserAcceptsSupportedGalleryURLs() {
        #expect(LocalHighlightGalleryURLParser.galleryID(from: "https://e-hentai.org/g/12345/token/") == "12345")
        #expect(LocalHighlightGalleryURLParser.galleryID(from: "https://exhentai.org/g/67890/token/") == "67890")
        #expect(LocalHighlightGalleryURLParser.galleryID(from: " https://e-hentai.org/g/42/token/?p=1 ") == "42")
    }

    @Test("gallery URL parser rejects unsupported or malformed URLs")
    func parserRejectsInvalidGalleryURLs() {
        #expect(LocalHighlightGalleryURLParser.galleryID(from: "https://example.com/g/123/token/") == nil)
        #expect(LocalHighlightGalleryURLParser.galleryID(from: "https://e-hentai.org/gallery/123/token/") == nil)
        #expect(LocalHighlightGalleryURLParser.galleryID(from: "https://e-hentai.org/g/not-number/token/") == nil)
        #expect(LocalHighlightGalleryURLParser.galleryID(from: "https://e-hentai.org/g/123/") == nil)
        #expect(LocalHighlightGalleryURLParser.galleryID(from: "not a url") == nil)
        #expect(LocalHighlightGalleryURLParser.galleryID(from: nil) == nil)
    }

    @Test("snapshot deduplicates and sorts local existing gallery IDs")
    func snapshotDeduplicatesSortsAndSkipsMissingBooks() {
        let snapshot = LocalHighlightGallerySnapshot.make(
            from: [
                sampleBook(url: "https://e-hentai.org/g/300/token/"),
                sampleBook(url: "https://exhentai.org/g/100/token/"),
                sampleBook(url: "https://e-hentai.org/g/300/other-token/"),
                sampleBook(url: "https://e-hentai.org/g/200/token/", exist: false),
                sampleBook(url: "https://example.com/g/900/token/")
            ]
        )

        #expect(snapshot.app == "NyaEH")
        #expect(snapshot.gids == ["100", "300"])
    }

    @Test("snapshot revision is stable and changes with gallery IDs")
    func snapshotRevisionTracksGalleryIDs() {
        let first = LocalHighlightGallerySnapshot(gids: ["200", "100", "100"])
        let second = LocalHighlightGallerySnapshot(gids: ["100", "200"])
        let changed = LocalHighlightGallerySnapshot(gids: ["100", "300"])

        #expect(first.revision == second.revision)
        #expect(first.revision != changed.revision)
    }

    @MainActor
    @Test("preferences default local highlight service off and clamp port")
    func preferencesDefaultAndClampLocalHighlightPort() {
        let suiteName = TestRunResources.newDefaultsDomain()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(!preferences.isLocalHighlightServerEnabled)
        #expect(preferences.localHighlightServerPort == 23_786)

        preferences.localHighlightServerPort = 20
        #expect(preferences.localHighlightServerPort == 1_024)

        preferences.localHighlightServerPort = 80_000
        #expect(preferences.localHighlightServerPort == 65_535)
    }

    @Test("userscript uses selected local port and EH matches")
    func userscriptIncludesPortAndMatches() {
        let script = LocalHighlightUserscriptTemplate.script(port: 23_789)

        #expect(script.contains("http://127.0.0.1:23789/api/highlight/v1/galleries"))
        #expect(script.contains("// @match        *://e-hentai.org/*"))
        #expect(script.contains("// @match        *://exhentai.org/*"))
        #expect(script.contains("// @connect      127.0.0.1"))
    }

    @Test("local server returns snapshot JSON over loopback")
    func localServerReturnsSnapshotJSON() async throws {
        let port = try availableLoopbackPort()
        let server = LocalHighlightServer()
        try server.start(port: port) {
            LocalHighlightGallerySnapshot(gids: ["12345"])
        }
        defer {
            server.stop()
        }

        let url = URL(string: "http://127.0.0.1:\(port)/api/highlight/v1/galleries")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        let snapshot = try JSONDecoder().decode(LocalHighlightGallerySnapshot.self, from: data)

        #expect(httpResponse.statusCode == 200)
        #expect(snapshot.app == "NyaEH")
        #expect(snapshot.gids == ["12345"])
    }

    @Test("local server handles unknown paths and options")
    func localServerHandlesUnknownPathsAndOptions() async throws {
        let port = try availableLoopbackPort()
        let server = LocalHighlightServer()
        try server.start(port: port) {
            LocalHighlightGallerySnapshot(gids: [])
        }
        defer {
            server.stop()
        }

        let missingURL = URL(string: "http://127.0.0.1:\(port)/not-found")!
        let (_, missingResponse) = try await URLSession.shared.data(from: missingURL)
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)

        var optionsRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/highlight/v1/galleries")!)
        optionsRequest.httpMethod = "OPTIONS"
        let (_, optionsResponse) = try await URLSession.shared.data(for: optionsRequest)
        #expect((optionsResponse as? HTTPURLResponse)?.statusCode == 204)
    }

    @Test("local server reports port conflicts")
    func localServerReportsPortConflicts() throws {
        let port = try availableLoopbackPort()
        let firstServer = LocalHighlightServer()
        try firstServer.start(port: port) {
            LocalHighlightGallerySnapshot(gids: [])
        }
        defer {
            firstServer.stop()
        }

        let secondServer = LocalHighlightServer()
        do {
            try secondServer.start(port: port) {
                LocalHighlightGallerySnapshot(gids: [])
            }
            Issue.record("Expected second server start to fail")
        } catch let error as LocalHighlightServerError {
            #expect(error.localizedDescription.contains("already in use"))
        }
    }

    @MainActor
    @Test("controller startup failure ends in failed status")
    func controllerStartupFailureEndsInFailedStatus() throws {
        let port = try availableLoopbackPort()
        let occupiedServer = LocalHighlightServer()
        try occupiedServer.start(port: port) {
            LocalHighlightGallerySnapshot(gids: [])
        }
        defer {
            occupiedServer.stop()
        }

        let suiteName = TestRunResources.newDefaultsDomain()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = AppPreferences(userDefaults: defaults)
        preferences.localHighlightServerPort = port
        preferences.isLocalHighlightServerEnabled = true

        let controller = LocalHighlightServerController()
        controller.apply(preferences: preferences)

        if case .failed(let failedPort, let message) = controller.status {
            #expect(failedPort == port)
            #expect(message.contains("already in use"))
        } else {
            Issue.record("Expected failed status, got \(controller.status)")
        }
    }

    private func sampleBook(url: String?, exist: Bool = true) -> LibraryBook {
        LibraryBook(
            title: "Sample",
            hash: UUID().uuidString,
            filepath: "/tmp/\(UUID().uuidString).cbz",
            type: .archive,
            status: .correct,
            url: url,
            exist: exist
        )
    }

    private func availableLoopbackPort() throws -> Int {
        let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        defer {
            Darwin.close(fileDescriptor)
        }

        var value: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    fileDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(fileDescriptor, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        return Int(UInt16(bigEndian: address.sin_port))
    }
}
