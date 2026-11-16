import Foundation
import Testing
@testable import NyaEHCore

@Suite("Gallery metadata fetching")
struct GalleryMetadataFetchServiceTests {
    @Test("builds E-Hentai and ExHentai search URLs")
    func buildsSearchURLs() throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"

        let eHentaiURL = try GalleryMetadataFetchService.searchURL(hash: hash, site: .eHentai)
        #expect(eHentaiURL.absoluteString == "https://e-hentai.org/?f_shash=0123456789abcdef0123456789abcdef01234567&fs_similar=on&fs_exp=on&f_cats=161")

        let exHentaiURL = try GalleryMetadataFetchService.searchURL(hash: hash, site: .exHentai)
        #expect(exHentaiURL.absoluteString == "https://exhentai.org/?f_shash=0123456789abcdef0123456789abcdef01234567&fs_similar=on&fs_exp=on&f_cats=161")
    }

    @Test("builds ExHentai cookie header")
    func buildsCookieHeader() {
        let configuration = GalleryMetadataFetchConfiguration(
            site: .exHentai,
            igneous: "igneous-value",
            ipbPassHash: "pass-value",
            ipbMemberID: "12345",
            star: "1"
        )

        #expect(GalleryMetadataFetchService.cookieHeader(for: configuration) == "igneous=igneous-value; ipb_pass_hash=pass-value; ipb_member_id=12345; star=1")
        #expect(GalleryMetadataFetchService.cookieHeader(for: GalleryMetadataFetchConfiguration(site: .exHentai)) == nil)
    }

    @Test("parses search result titles and gallery URLs")
    func parsesSearchResults() {
        let html = """
        <table class="itg">
          <tr>
            <td class="gl3c glname">
              <a href="https://e-hentai.org/g/12345/abcdef1234/">
                Link
              </a>
              <div class="glink">Sample &amp; Gallery</div>
            </td>
          </tr>
        </table>
        """

        let results = GalleryMetadataFetchService.parseSearchResults(html: html, site: .eHentai)

        #expect(results.count == 1)
        #expect(results[0].title == "Sample & Gallery")
        #expect(results[0].url.absoluteString == "https://e-hentai.org/g/12345/abcdef1234/")
        #expect(results[0].galleryID == 12345)
        #expect(results[0].galleryToken == "abcdef1234")
    }

    @Test("falls back to gallery links outside result containers")
    func parsesFallbackGalleryLinks() {
        let html = """
        <html>
          <body>
            <a href="/g/55555/fallback123/">Fallback Gallery</a>
          </body>
        </html>
        """

        let results = GalleryMetadataFetchService.parseSearchResults(html: html, site: .exHentai)

        #expect(results.count == 1)
        #expect(results[0].title == "Fallback Gallery")
        #expect(results[0].url.absoluteString == "https://exhentai.org/g/55555/fallback123/")
        #expect(results[0].galleryID == 55555)
        #expect(results[0].galleryToken == "fallback123")
    }

    @Test("returns no results for empty search page")
    func parsesEmptySearchResults() {
        let results = GalleryMetadataFetchService.parseSearchResults(html: "<html><body>No hits</body></html>", site: .eHentai)
        #expect(results.isEmpty)
    }

    @Test("search reports IP ban page instead of no results")
    func searchReportsIPBanPage() async throws {
        let service = GalleryMetadataFetchService(
            httpClient: MockGalleryMetadataHTTPClient(
                responses: [Data("<html>Your IP address has been temporarily banned.</html>".utf8)]
            )
        )

        do {
            _ = try await service.fetchMetadata(
                hash: "0123456789abcdef0123456789abcdef01234567",
                configuration: GalleryMetadataFetchConfiguration(site: .exHentai, igneous: "a", ipbPassHash: "b", ipbMemberID: "c")
            )
            Issue.record("Expected IP ban error")
        } catch let error as GalleryMetadataFetchError {
            #expect(error == .ipBanned)
        }
    }

    @Test("search reports ExHentai access page instead of no results")
    func searchReportsExHentaiAccessPage() async throws {
        let service = GalleryMetadataFetchService(
            httpClient: MockGalleryMetadataHTTPClient(
                responses: [Data("<html><body>Sad Panda</body></html>".utf8)]
            )
        )

        do {
            _ = try await service.fetchMetadata(
                hash: "0123456789abcdef0123456789abcdef01234567",
                configuration: GalleryMetadataFetchConfiguration(site: .exHentai, igneous: "a", ipbPassHash: "b", ipbMemberID: "c")
            )
            Issue.record("Expected ExHentai access error")
        } catch let error as GalleryMetadataFetchError {
            #expect(error == .exHentaiAccessDenied)
        }
    }

    @Test("fetches API metadata and maps it into the database model")
    func fetchesAPIMetadata() async throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let client = MockGalleryMetadataHTTPClient(
            responses: [
                Data(#"<a href="https://e-hentai.org/g/12345/abcdef1234/"><div class="glink">Search Title</div></a>"#.utf8),
                Data(
                    """
                    {
                      "gmetadata": [
                        {
                          "gid": 12345,
                          "token": "abcdef1234",
                          "title": "Remote Title",
                          "title_jpn": "日本語タイトル",
                          "category": "Doujinshi",
                          "posted": "1700000000",
                          "filecount": "42",
                          "filesize": 123456,
                          "rating": "4.5",
                          "tags": ["language:chinese", "artist:sample"]
                        }
                      ]
                    }
                    """.utf8
                )
            ]
        )
        let service = GalleryMetadataFetchService(httpClient: client)

        let metadata = try await service.fetchMetadata(
            hash: hash,
            configuration: GalleryMetadataFetchConfiguration(site: .eHentai)
        )

        #expect(metadata.hash == hash)
        #expect(metadata.galleryID == 12345)
        #expect(metadata.galleryToken == "abcdef1234")
        #expect(metadata.title == "Remote Title")
        #expect(metadata.titleJpn == "日本語タイトル")
        #expect(metadata.category == "Doujinshi")
        #expect(metadata.posted == 1_700_000_000)
        #expect(metadata.pages == 42)
        #expect(metadata.filesize == 123_456)
        #expect(metadata.rating == 4.5)
        #expect(metadata.tags == "[\"language:chinese\",\"artist:sample\"]")
        #expect(client.requests.count == 2)
    }

    @Test("fetching metadata writes gallery metadata and overrides scanner language hint")
    @MainActor
    func servicePersistsMetadataAndOverridesScannerLanguageHint() async throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let context = try makeContext()
        var scannerHintBook = sampleBook(hash: hash)
        scannerHintBook.languageCode = "japanese"
        scannerHintBook.tags = #"["language:japanese"]"#
        let book = try context.books.insert(scannerHintBook)
        let client = MockGalleryMetadataHTTPClient(
            responses: [
                Data(#"<a href="https://e-hentai.org/g/12345/abcdef1234/"><div class="glink">Search Title</div></a>"#.utf8),
                Data(
                    """
                    {
                      "gmetadata": [
                        {
                          "gid": "12345",
                          "token": "abcdef1234",
                          "title": "Remote Title",
                          "title_jpn": "日本語タイトル",
                          "category": "Doujinshi",
                          "posted": "1700000000",
                          "filecount": "42",
                          "filesize": "123456",
                          "rating": "4.5",
                          "tags": ["language:chinese"]
                        }
                      ]
                    }
                    """.utf8
                )
            ]
        )
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            metadataFetchService: GalleryMetadataFetchService(httpClient: client)
        )

        let updatedBook = try await libraryService.fetchMetadata(
            for: book,
            configuration: GalleryMetadataFetchConfiguration(site: .eHentai)
        )

        #expect(updatedBook.title == "Remote Title")
        #expect(updatedBook.titleJpn == "日本語タイトル")
        #expect(updatedBook.status == .correct)
        #expect(updatedBook.url == "https://e-hentai.org/g/12345/abcdef1234/")
        #expect(updatedBook.tags == "[\"language:chinese\"]")
        #expect(updatedBook.languageCode == "chinese")

        let tagSummaries = try context.tags.summaries(namespace: "language")
        #expect(tagSummaries.count == 1)
        #expect(tagSummaries[0].rawValue == "language:chinese")
        #expect(tagSummaries[0].count == 1)

        let fetchedMetadata = try context.metadata.fetch(hash: hash)
        let metadata = try #require(fetchedMetadata)
        #expect(metadata.title == "Remote Title")
        #expect(metadata.galleryID == 12345)
    }

    @Test("parses direct gallery URLs")
    func parsesDirectGalleryURLs() throws {
        let result = try GalleryMetadataFetchService.searchResult(
            fromGalleryURL: #require(URL(string: "https://exhentai.org/g/98765/tokenabc/"))
        )

        #expect(result.galleryID == 98765)
        #expect(result.galleryToken == "tokenabc")
        #expect(result.url.absoluteString == "https://exhentai.org/g/98765/tokenabc/")
        #expect(throws: BookMetadataEditError.invalidGalleryURL) {
            try GalleryMetadataFetchService.searchResult(fromGalleryURL: #require(URL(string: "https://example.com/g/1/a/")))
        }
    }

    @Test("direct URL metadata updates current book")
    @MainActor
    func directURLMetadataUpdatesBook() async throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(hash: hash))
        let client = MockGalleryMetadataHTTPClient(
            responses: [
                Data(
                    """
                    {
                      "gmetadata": [
                        {
                          "gid": "222",
                          "token": "directtoken",
                          "title": "Direct Title",
                          "category": "Doujinshi",
                          "filecount": "33",
                          "tags": ["artist:direct"]
                        }
                      ]
                    }
                    """.utf8
                )
            ]
        )
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            metadataFetchService: GalleryMetadataFetchService(httpClient: client),
            coverCache: nil
        )

        let updatedBook = try await libraryService.fetchMetadata(
            for: book,
            galleryURL: #require(URL(string: "https://e-hentai.org/g/222/directtoken/")),
            configuration: GalleryMetadataFetchConfiguration(site: .eHentai)
        )

        #expect(updatedBook.title == "Direct Title")
        #expect(updatedBook.pages == 33)
        #expect(updatedBook.url == "https://e-hentai.org/g/222/directtoken/")
        #expect(client.requests.count == 1)
        #expect(client.requests[0].url?.absoluteString == "https://api.e-hentai.org/api.php")
    }

    @Test("manual metadata save updates book metadata mirror and tag index")
    func manualMetadataSaveUpdatesBookMetadataAndTags() throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let context = try makeContext()
        let book = try context.books.insert(sampleBook(hash: hash))
        var draft = BookMetadataEditDraft(book: book)
        draft.title = "Manual Title"
        draft.titleJpn = "手動タイトル"
        draft.category = "Doujinshi"
        draft.languageSelection = .chinese
        draft.pagesText = "88"
        draft.isTranslated = true
        draft.isFullColor = true
        draft.censorship = "uncensored"
        draft.hasExtraneousAds = true
        draft.tagGroups = [
            BookMetadataTagGroup(namespace: "artist", valuesText: "sample artist"),
            BookMetadataTagGroup(namespace: "group", valuesText: "sample group"),
            BookMetadataTagGroup(namespace: "parody", valuesText: "original"),
            BookMetadataTagGroup(namespace: "character", valuesText: "hero"),
            BookMetadataTagGroup(namespace: "female", valuesText: "sole female"),
            BookMetadataTagGroup(namespace: "male", valuesText: ""),
            BookMetadataTagGroup(namespace: "mixed", valuesText: ""),
            BookMetadataTagGroup(namespace: "location", valuesText: ""),
            BookMetadataTagGroup(namespace: "other", valuesText: "story arc")
        ]
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            coverCache: nil
        )

        let updatedBook = try libraryService.saveManualMetadataDraft(draft, for: book)

        #expect(updatedBook.title == "Manual Title")
        #expect(updatedBook.titleJpn == "手動タイトル")
        #expect(updatedBook.type == book.type)
        #expect(updatedBook.category == "Doujinshi")
        #expect(updatedBook.pages == 88)
        #expect(updatedBook.languageCode == "chinese")
        #expect(updatedBook.isTranslated)
        #expect(updatedBook.isFullColor)
        #expect(updatedBook.censorship == "uncensored")
        #expect(updatedBook.hasExtraneousAds)
        let fetchedMetadata = try context.metadata.fetch(hash: hash)
        let metadata = try #require(fetchedMetadata)
        #expect(metadata.title == "Manual Title")
        let artistTags = try context.tags.summaries(namespace: "artist")
        #expect(artistTags.map(\.rawValue) == ["artist:sample artist"])
    }

    @Test("manual metadata rejects invalid pages")
    func manualMetadataRejectsInvalidPages() throws {
        let book = sampleBook(hash: "0123456789abcdef0123456789abcdef01234567")
        var draft = BookMetadataEditDraft(book: book)
        draft.pagesText = "abc"

        #expect(throws: BookMetadataEditError.invalidPages) {
            _ = try draft.validatedMetadata(for: book)
        }
    }

    @Test("manual metadata language options generate expected tags")
    func manualMetadataLanguageOptionsGenerateExpectedTags() throws {
        let book = sampleBook(hash: "0123456789abcdef0123456789abcdef01234567")
        var draft = BookMetadataEditDraft(book: book)
        draft.languageSelection = .english
        var update = try draft.validatedMetadata(for: book)
        #expect(update.languageCode == "english")
        #expect(update.tagsJSON.contains("language:english"))

        draft.languageSelection = .unknown
        update = try draft.validatedMetadata(for: book)
        #expect(update.languageCode == "unknown")
        #expect(!update.tagsJSON.contains("language:unknown"))

        draft.languageSelection = .other
        draft.customLanguageCode = "thai"
        update = try draft.validatedMetadata(for: book)
        #expect(update.languageCode == "thai")
        #expect(update.tagsJSON.contains("language:thai"))
    }

    @Test("clearing metadata removes mirror and tag index")
    func clearingMetadataRemovesMirrorAndTags() throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let context = try makeContext()
        var source = sampleBook(hash: hash)
        source.title = "Remote Title"
        source.tags = "[\"artist:sample\"]"
        source.titleJpn = "日本語"
        source.category = "Doujinshi"
        source.pages = 12
        let book = try context.books.insert(source)
        _ = try context.metadata.upsert(GalleryMetadata(hash: hash, title: "Remote Title", tags: source.tags))
        try context.tags.rebuildTags(forBookID: #require(book.databaseID), tagsJSON: source.tags)
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            coverCache: nil
        )

        let cleared = try libraryService.clearMetadata(for: book)

        #expect(cleared.titleJpn == nil)
        #expect(cleared.tags == "[]")
        #expect(cleared.pages == nil)
        #expect(cleared.category == nil)
        #expect(cleared.status == .unscanned)
        #expect(try context.metadata.fetch(hash: hash) == nil)
        #expect(try context.tags.tags(forBookID: #require(book.databaseID)).isEmpty)
    }

    @Test("deleting book removes source file and database row")
    func deletingBookRemovesSourceFileAndDatabaseRow() throws {
        let context = try makeContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sample.cbz")
        try Data("zip".utf8).write(to: fileURL)
        var source = sampleBook(hash: "0123456789abcdef0123456789abcdef01234567")
        source.filepath = fileURL.path
        source.coverPath = directory.appendingPathComponent("cover.jpg").path
        try Data("cover".utf8).write(to: URL(fileURLWithPath: source.coverPath!))
        let book = try context.books.insert(source)
        let coverCache = MockCoverCache()
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            coverCache: coverCache
        )

        try libraryService.deleteBookAndSourceFile(book)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try context.books.fetch(id: #require(book.databaseID)) == nil)
        #expect(coverCache.removedPaths == [source.coverPath])
    }

    @Test("deleting book preserves shared metadata and cover")
    func deletingBookPreservesSharedMetadataAndCover() throws {
        let context = try makeContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let coverPath = directory.appendingPathComponent("shared-cover.jpg").path
        try Data("cover".utf8).write(to: URL(fileURLWithPath: coverPath))

        let firstURL = directory.appendingPathComponent("first.cbz")
        let secondURL = directory.appendingPathComponent("second.cbz")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)

        var first = sampleBook(hash: hash)
        first.filepath = firstURL.path
        first.coverPath = coverPath
        var second = sampleBook(hash: hash)
        second.filepath = secondURL.path
        second.coverPath = coverPath
        let firstBook = try context.books.insert(first)
        let secondBook = try context.books.insert(second)
        _ = try context.metadata.upsert(GalleryMetadata(hash: hash, title: "Shared"))
        let coverCache = MockCoverCache()
        let libraryService = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            coverCache: coverCache
        )

        try libraryService.deleteBookAndSourceFile(firstBook)

        #expect(try context.books.fetch(id: #require(firstBook.databaseID)) == nil)
        #expect(try context.books.fetch(id: #require(secondBook.databaseID)) != nil)
        #expect(try context.metadata.fetch(hash: hash) != nil)
        #expect(coverCache.removedPaths.isEmpty)
    }

    private func sampleBook(hash: String) -> LibraryBook {
        LibraryBook(
            title: "Sample Book",
            hash: hash,
            filepath: "/tmp/\(UUID().uuidString).cbz",
            type: .archive,
            status: .unscanned
        )
    }

    private func makeContext() throws -> RepositoryContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: directory.appendingPathComponent("NyaEH.sqlite").path)
        return RepositoryContext(
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            metadata: SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue),
            tags: SQLiteTagRepository(dbQueue: database.dbQueue)
        )
    }
}

private final class MockGalleryMetadataHTTPClient: GalleryMetadataHTTPClient, @unchecked Sendable {
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

private final class MockCoverCache: CoverCaching {
    var removedPaths: [String?] = []

    func cacheCover(originalData: Data) throws -> CachedCover? {
        nil
    }

    func cachedCoverExists(path: String?) -> Bool {
        false
    }

    func removeCachedCover(path: String?) throws {
        removedPaths.append(path)
    }
}

private struct RepositoryContext {
    let books: SQLiteLibraryBookRepository
    let metadata: SQLiteGalleryMetadataRepository
    let tags: SQLiteTagRepository
}
