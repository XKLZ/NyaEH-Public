import Foundation
import Testing
@testable import NyaEHCore

@Suite("Metadata batch queue")
struct MetadataBatchTests {
    @Test("batch snapshots eligible unscanned books and honors limit")
    @MainActor
    func snapshotsEligibleBooksAndHonorsLimit() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(hash: hash(1), filepath: "/tmp/1.cbz"))
        let second = try context.books.insert(sampleBook(hash: hash(2), filepath: "/tmp/2.cbz"))
        let invalid = try context.books.insert(sampleBook(hash: "broken:/tmp/3.cbz", filepath: "/tmp/3.cbz"))
        let client = MockBatchHTTPClient(
            responses: [
                .html(galleryHTML(gid: 1, token: "token1")),
                .json(gdataJSON(gid: 1, token: "token1", title: "Remote 1"))
            ]
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                metadataFetchService: GalleryMetadataFetchService(httpClient: client)
            ),
            sleep: { _ in }
        )

        store.startMetadataBatch(
            books: [first, invalid, second],
            configuration: batchConfiguration(limit: 1),
            localizer: AppLocalizer(language: .en)
        )
        await waitForBatch(store, states: [.completed])

        #expect(store.metadataBatchProgress.total == 1)
        #expect(store.metadataBatchProgress.succeeded == 1)
        #expect(store.metadataBatchProgress.skipped == 1)
        #expect(client.requests.count == 2)
        #expect(try context.books.fetch(id: first.databaseID!)?.title == "Remote 1")
        #expect(try context.books.fetch(id: second.databaseID!)?.title == "Sample")
    }

    @Test("batch continues after no search results")
    @MainActor
    func continuesAfterNoSearchResults() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(hash: hash(1), filepath: "/tmp/1.cbz"))
        let second = try context.books.insert(sampleBook(hash: hash(2), filepath: "/tmp/2.cbz"))
        let client = MockBatchHTTPClient(
            responses: [
                .html("<html><body>No hits</body></html>"),
                .html(galleryHTML(gid: 2, token: "token2")),
                .json(gdataJSON(gid: 2, token: "token2", title: "Remote 2"))
            ]
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                metadataFetchService: GalleryMetadataFetchService(httpClient: client)
            ),
            sleep: { _ in }
        )

        store.startMetadataBatch(
            books: [first, second],
            configuration: batchConfiguration(limit: 10),
            localizer: AppLocalizer(language: .en)
        )
        await waitForBatch(store, states: [.completed])

        #expect(store.metadataBatchProgress.failed == 1)
        #expect(store.metadataBatchProgress.succeeded == 1)
        #expect(try context.books.fetch(id: first.databaseID!)?.status == .unscanned)
        #expect(try context.books.fetch(id: second.databaseID!)?.title == "Remote 2")
    }

    @Test("zero limit processes all eligible books")
    @MainActor
    func zeroLimitProcessesAllEligibleBooks() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(hash: hash(1), filepath: "/tmp/1.cbz"))
        let second = try context.books.insert(sampleBook(hash: hash(2), filepath: "/tmp/2.cbz"))
        let client = MockBatchHTTPClient(
            responses: [
                .html(galleryHTML(gid: 1, token: "token1")),
                .json(gdataJSON(gid: 1, token: "token1", title: "Remote 1")),
                .html(galleryHTML(gid: 2, token: "token2")),
                .json(gdataJSON(gid: 2, token: "token2", title: "Remote 2"))
            ]
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                metadataFetchService: GalleryMetadataFetchService(httpClient: client)
            ),
            sleep: { _ in }
        )

        store.startMetadataBatch(
            books: [first, second],
            configuration: batchConfiguration(limit: 0),
            localizer: AppLocalizer(language: .en)
        )
        await waitForBatch(store, states: [.completed])

        #expect(store.metadataBatchProgress.total == 2)
        #expect(store.metadataBatchProgress.succeeded == 2)
        #expect(client.requests.count == 4)
    }

    @Test("batch updates work character index once after metadata writes")
    @MainActor
    func batchUpdatesWorkCharacterIndexOnceAfterMetadataWrites() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(hash: hash(1), filepath: "/tmp/1.cbz"))
        let second = try context.books.insert(sampleBook(hash: hash(2), filepath: "/tmp/2.cbz"))
        let client = MockBatchHTTPClient(
            responses: [
                .html(galleryHTML(gid: 1, token: "token1")),
                .json(gdataJSON(
                    gid: 1,
                    token: "token1",
                    title: "Remote 1",
                    tags: ["parody:love live", "character:honoka"]
                )),
                .html(galleryHTML(gid: 2, token: "token2")),
                .json(gdataJSON(
                    gid: 2,
                    token: "token2",
                    title: "Remote 2",
                    tags: ["parody:love live", "character:kotori"]
                ))
            ]
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                tagRepository: context.tags,
                workCharacterRepository: context.workCharacters,
                metadataFetchService: GalleryMetadataFetchService(httpClient: client)
            ),
            sleep: { _ in }
        )

        store.startMetadataBatch(
            books: [first, second],
            configuration: batchConfiguration(limit: 0),
            localizer: AppLocalizer(language: .en)
        )
        await waitForBatch(store, states: [.completed])
        await store.waitForWorkCharacterIndexUpdate()

        let works = try context.workCharacters.fetchWorks(languageCode: nil)
        let work = try #require(works.first)
        let characters = try context.workCharacters.fetchCharacters(parodyTagID: work.tag.id, languageCode: nil)

        #expect(works.map(\.tag.name) == ["love live"])
        #expect(work.bookCount == 2)
        #expect(work.characterCount == 2)
        #expect(characters.map(\.tag.name).sorted() == ["honoka", "kotori"])
        #expect(store.workCharacterIndexMessage == "Work-character index updated: processed 2 book(s), 2 link(s) indexed.")
    }

    @Test("batch pauses on ExHentai access errors")
    @MainActor
    func pausesOnAccessErrors() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(hash: hash(1), filepath: "/tmp/1.cbz"))
        let second = try context.books.insert(sampleBook(hash: hash(2), filepath: "/tmp/2.cbz"))
        let client = MockBatchHTTPClient(
            responses: [
                .html("<html><body>Sad Panda</body></html>")
            ]
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                metadataFetchService: GalleryMetadataFetchService(httpClient: client)
            ),
            sleep: { _ in }
        )

        store.startMetadataBatch(
            books: [first, second],
            configuration: batchConfiguration(site: .exHentai, limit: 10),
            localizer: AppLocalizer(language: .en)
        )
        await waitForBatch(store, states: [.paused])

        #expect(store.metadataBatchProgress.state == .paused)
        #expect(store.metadataBatchProgress.processed == 0)
        #expect(client.requests.count == 1)
    }

    @Test("batch retries transient errors")
    @MainActor
    func retriesTransientErrors() async throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook(hash: hash(1), filepath: "/tmp/1.cbz"))
        let client = MockBatchHTTPClient(
            responses: [
                .status(500),
                .html(galleryHTML(gid: 1, token: "token1")),
                .json(gdataJSON(gid: 1, token: "token1", title: "Remote 1"))
            ]
        )
        let store = CatalogStore(
            service: BookLibraryService(
                bookRepository: context.books,
                metadataRepository: context.metadata,
                metadataFetchService: GalleryMetadataFetchService(httpClient: client)
            ),
            sleep: { _ in }
        )

        store.startMetadataBatch(
            books: [first],
            configuration: batchConfiguration(retryCount: 1, limit: 10),
            localizer: AppLocalizer(language: .en)
        )
        await waitForBatch(store, states: [.completed])

        #expect(store.metadataBatchProgress.succeeded == 1)
        #expect(client.requests.count == 3)
        #expect(try context.books.fetch(id: first.databaseID!)?.title == "Remote 1")
    }

    private func batchConfiguration(
        site: GallerySearchSite = .eHentai,
        retryCount: Int = 0,
        limit: Int
    ) -> MetadataBatchConfiguration {
        MetadataBatchConfiguration(
            fetchConfiguration: GalleryMetadataFetchConfiguration(
                site: site,
                igneous: "igneous",
                ipbPassHash: "pass",
                ipbMemberID: "member"
            ),
            minDelaySeconds: 0,
            maxDelaySeconds: 0,
            retryCount: retryCount,
            limit: limit
        )
    }

    private func sampleBook(hash: String, filepath: String) -> LibraryBook {
        LibraryBook(
            title: "Sample",
            hash: hash,
            filepath: filepath,
            type: .archive,
            status: .unscanned
        )
    }

    private func hash(_ value: Int) -> String {
        String(format: "%040d", value)
    }

    private func galleryHTML(gid: Int64, token: String) -> String {
        """
        <table>
          <td class="gl3c glname">
            <a href="https://e-hentai.org/g/\(gid)/\(token)/">Link</a>
            <div class="glink">Gallery \(gid)</div>
          </td>
        </table>
        """
    }

    private func gdataJSON(
        gid: Int64,
        token: String,
        title: String,
        tags: [String] = ["language:chinese"]
    ) -> String {
        let tagsJSON = tags.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "gmetadata": [
            {
              "gid": "\(gid)",
              "token": "\(token)",
              "title": "\(title)",
              "category": "Doujinshi",
              "filecount": "10",
              "rating": "4.0",
              "posted": "1700000000",
              "filesize": "12345",
              "tags": [\(tagsJSON)]
            }
          ]
        }
        """
    }

    private func makeContext() throws -> MetadataBatchRepositoryContext {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: directory.appendingPathComponent("NyaEH.sqlite").path)
        return MetadataBatchRepositoryContext(
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            metadata: SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue),
            tags: SQLiteTagRepository(dbQueue: database.dbQueue),
            workCharacters: SQLiteWorkCharacterRepository(dbQueue: database.dbQueue)
        )
    }

    @MainActor
    private func waitForBatch(
        _ store: CatalogStore,
        states: Set<MetadataBatchRunState>,
        maxYields: Int = 200
    ) async {
        for _ in 0..<maxYields {
            if states.contains(store.metadataBatchProgress.state) {
                return
            }
            await Task.yield()
        }
    }
}

private struct MetadataBatchRepositoryContext {
    let books: SQLiteLibraryBookRepository
    let metadata: SQLiteGalleryMetadataRepository
    let tags: SQLiteTagRepository
    let workCharacters: SQLiteWorkCharacterRepository
}

private final class MockBatchHTTPClient: GalleryMetadataHTTPClient, @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var data: Data

        static func html(_ html: String) -> Response {
            Response(statusCode: 200, data: Data(html.utf8))
        }

        static func json(_ json: String) -> Response {
            Response(statusCode: 200, data: Data(json.utf8))
        }

        static func status(_ statusCode: Int) -> Response {
            Response(statusCode: statusCode, data: Data())
        }
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.data, httpResponse)
    }
}
