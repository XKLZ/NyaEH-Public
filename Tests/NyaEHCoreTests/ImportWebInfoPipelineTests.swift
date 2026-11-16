import Foundation
import Testing
import ZIPFoundation
@testable import NyaEHCore

@Suite("Smart import webinfo", .serialized)
struct ImportWebInfoPipelineTests {
    @Test("embedded URL precedes cache and hash search; manual URL precedes embedded URL")
    @MainActor
    func urlPrecedence() async throws {
        for preferredURL in [nil, "https://e-hentai.org/g/333/manual/"] {
            let fixture = try makeFixture(webInfo: "https://e-hentai.org/g/222/embedded/", preferredURL: preferredURL)
            _ = try fixture.metadata.upsert(GalleryMetadata(hash: fixture.hash, title: "Cached"))
            let client = FixtureHTTPClient(responses: [gdata(id: preferredURL == nil ? 222 : 333, token: preferredURL == nil ? "embedded" : "manual")])
            let store = makeStore(fixture, client: client)
            await runMetadata(store, fixture: fixture)

            let item = try #require(try fixture.pipeline.fetchItem(bookID: fixture.bookID))
            #expect(item.metadataSource == .galleryURL)
            #expect(client.requests.count == 1)
            #expect(client.requests.first?.url?.host == "api.e-hentai.org")
            #expect(try fixture.books.fetch(id: fixture.bookID)?.title == "Remote")
        }
    }

    @Test("missing or invalid webinfo falls back to hash search")
    @MainActor
    func absentOrInvalidFallback() async throws {
        for webInfo in [nil, "https://example.com/g/1/wrong/"] {
            let fixture = try makeFixture(webInfo: webInfo)
            let client = FixtureHTTPClient(responses: [
                Data(#"<a href="https://e-hentai.org/g/444/search/"><div class="glink">Result</div></a>"#.utf8),
                gdata(id: 444, token: "search")
            ])
            let store = makeStore(fixture, client: client)
            await runMetadata(store, fixture: fixture)
            let item = try #require(try fixture.pipeline.fetchItem(bookID: fixture.bookID))
            #expect(item.metadataSource == .hashSearch)
            #expect(client.requests.count == 2)
            #expect(client.requests.first?.url?.host == "e-hentai.org")
        }
    }

    @Test("direct API failure defers without hash search")
    @MainActor
    func directFailureDoesNotSearch() async throws {
        let fixture = try makeFixture(webInfo: "https://e-hentai.org/g/222/embedded/")
        let client = FixtureHTTPClient(responses: [Data(#"{"gmetadata":[{"gid":"222","token":"embedded","error":"unavailable"}]}"#.utf8)])
        let store = makeStore(fixture, client: client)
        await runMetadata(store, fixture: fixture)
        let item = try #require(try fixture.pipeline.fetchItem(bookID: fixture.bookID))
        #expect(item.stage == .metadataDeferred)
        #expect(client.requests.count == 1)
        #expect(client.requests.first?.url?.host == "api.e-hentai.org")
    }

    @MainActor
    private func runMetadata(_ store: CatalogStore, fixture: Fixture) async {
        store.refresh()
        store.startImportPipeline(
            securityScopedRootURL: fixture.root,
            configuration: MetadataBatchConfiguration(fetchConfiguration: GalleryMetadataFetchConfiguration(site: .eHentai), minDelaySeconds: 0, maxDelaySeconds: 0, retryCount: 0),
            useCoverSimilarity: false,
            useSemanticSeriesSimilarity: false,
            maximumCoverDistance: 0,
            localizer: AppLocalizer(language: .en)
        )
        for _ in 0..<200 where store.isProcessingImportPipeline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func makeStore(_ fixture: Fixture, client: FixtureHTTPClient) -> CatalogStore {
        CatalogStore(service: BookLibraryService(
            bookRepository: fixture.books,
            metadataRepository: fixture.metadata,
            importPipelineRepository: fixture.pipeline,
            metadataFetchService: GalleryMetadataFetchService(httpClient: client),
            coverCache: nil
        ), sleep: { _ in })
    }

    private func makeFixture(webInfo: String?, preferredURL: String? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("sample.cbz")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        var entries = ["001.jpg": Data("page".utf8)]
        if let webInfo { entries["webinfo.txt"] = Data(webInfo.utf8) }
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        let database = try DatabaseManager(path: root.appendingPathComponent("NyaEH.sqlite").path)
        let books = SQLiteLibraryBookRepository(dbQueue: database.dbQueue)
        let metadata = SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue)
        let pipeline = SQLiteImportPipelineRepository(dbQueue: database.dbQueue)
        let hash = String(repeating: "a", count: 40)
        let book = try books.insert(LibraryBook(title: "Sample", hash: hash, filepath: archiveURL.path, type: .archive, status: .unscanned, exist: true))
        let bookID = try #require(book.databaseID)
        try pipeline.reconcile(books: [book])
        if let preferredURL {
            var item = try #require(try pipeline.fetchItem(bookID: bookID))
            item.preferredGalleryURL = preferredURL
            try pipeline.updateItem(item)
        }
        return Fixture(root: root, hash: hash, bookID: bookID, books: books, metadata: metadata, pipeline: pipeline)
    }

    private func gdata(id: Int, token: String) -> Data {
        Data(#"{"gmetadata":[{"gid":"\#(id)","token":"\#(token)","title":"Remote","category":"Doujinshi","filecount":"1","tags":[]}]}"#.utf8)
    }
}

private struct Fixture {
    let root: URL
    let hash: String
    let bookID: Int64
    let books: SQLiteLibraryBookRepository
    let metadata: SQLiteGalleryMetadataRepository
    let pipeline: SQLiteImportPipelineRepository
}

// Test fixture is used only by MainActor-isolated metadata fetches and assertions.
// Replace this escape hatch with an actor if the client is ever called concurrently.
private final class FixtureHTTPClient: GalleryMetadataHTTPClient, @unchecked Sendable {
    var responses: [Data]
    var requests: [URLRequest] = []

    init(responses: [Data]) { self.responses = responses }

    func data(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = responses.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
