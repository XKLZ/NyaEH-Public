import Foundation
import GRDB
import Testing
@testable import NyaEHCore

@Suite("Tag translation cache")
struct TagTranslationTests {
    @Test("parses EhTagTranslation JSON database")
    func parsesJSONDatabase() throws {
        let parser = EhTagTranslationJSONParser()
        let translations = try parser.parse(
            json: """
                {
                  "repo": "https://github.com/EhTagTranslation/Database",
                  "head": { "sha": "sample" },
                  "version": 7,
                  "data": [
                    {
                      "namespace": "rows",
                      "count": 1,
                      "data": {
                        "female": {
                          "name": "女性",
                          "intro": "索引",
                          "links": "数据库页面"
                        }
                      }
                    },
                    {
                      "namespace": "female",
                      "count": 2,
                      "data": {
                        "lolicon": {
                          "name": "萝莉",
                          "intro": "有性的情景。",
                          "links": "https://example.com/ignored.webp"
                        },
                        "empty": {
                          "name": "",
                          "intro": "",
                          "links": ""
                        }
                      }
                    },
                    {
                      "namespace": "male",
                      "count": 1,
                      "data": {
                        "glasses": {
                          "name": "眼镜👓",
                          "intro": "用于改善双眼的视力的透明框架眼镜。",
                          "links": ""
                        }
                      }
                    },
                    {
                      "namespace": "parody",
                      "count": 1,
                      "data": {
                        "princess connect": {
                          "name": "![](https://example.com/cover.webp) 公主连结Re:Dive",
                          "intro": "第一行<br>![](https://example.com/intro.webp)第二行<img src='https://example.com/icon.webp'>",
                          "links": "维基百科 (*)"
                        }
                      }
                    }
                  ]
                }
                """
        )

        #expect(translations.sorted { $0.name < $1.name } == [
            ExternalTagTranslation(
                namespace: "male",
                name: "glasses",
                translatedName: "眼镜👓",
                intro: "用于改善双眼的视力的透明框架眼镜。",
                links: []
            ),
            ExternalTagTranslation(
                namespace: "female",
                name: "lolicon",
                translatedName: "萝莉",
                intro: "有性的情景。",
                links: []
            ),
            ExternalTagTranslation(
                namespace: "parody",
                name: "princess connect",
                translatedName: "公主连结Re:Dive",
                intro: "第一行 第二行",
                links: []
            )
        ])
        #expect(!translations.contains { $0.namespace == "rows" })
    }

    @Test("parses simplified JSON database")
    func parsesSimplifiedJSONDatabase() throws {
        let parser = EhTagTranslationJSONParser()
        let translations = try parser.parse(
            json: """
                {
                  "female": {
                    "glasses": {
                      "name": "眼镜👓",
                      "intro": "用于改善双眼的视力的透明框架眼镜。",
                      "links": ""
                    }
                  }
                }
                """
        )

        #expect(translations == [
            ExternalTagTranslation(
                namespace: "female",
                name: "glasses",
                translatedName: "眼镜👓",
                intro: "用于改善双眼的视力的透明框架眼镜。",
                links: []
            )
        ])
    }

    @Test("HTTP failures include status code")
    func httpFailuresIncludeStatusCode() throws {
        let url = URL(string: "https://github.com/EhTagTranslation/Database/releases/latest/download/db.text.json")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )!

        do {
            _ = try GitHubEhTagTranslationRemoteClient.revisionToken(from: response, downloadedAt: 1)
            Issue.record("Expected HTTP status error")
        } catch let error as EhTagTranslationHTTPError {
            #expect(error.statusCode == 404)
            #expect(error.localizedDescription.contains("HTTP 404"))
            #expect(error.localizedDescription.contains("db.text.json"))
        }
    }

    @Test("revision token prefers ETag then Last-Modified")
    func revisionTokenPrefersHeaders() throws {
        let url = URL(string: "https://github.com/EhTagTranslation/Database/releases/latest/download/db.text.json")!
        let etagResponse = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["ETag": "\"abc\""]
        )!
        let modifiedResponse = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Last-Modified": "Sun, 17 May 2026 12:00:00 GMT"]
        )!

        #expect(try GitHubEhTagTranslationRemoteClient.revisionToken(from: etagResponse, downloadedAt: 1) == "\"abc\"")
        #expect(
            try GitHubEhTagTranslationRemoteClient.revisionToken(from: modifiedResponse, downloadedAt: 1)
                == "Sun, 17 May 2026 12:00:00 GMT"
        )
    }

    @Test("migration adds tag translation cache fields")
    func migrationAddsTagTranslationCacheFields() throws {
        let context = try makeContext()

        try context.database.dbQueue.read { db in
            let columns = try db.columns(in: "tag_translations").map(\.name)
            #expect(columns.contains("intro"))
            #expect(columns.contains("links"))
            #expect(columns.contains("source"))
            #expect(columns.contains("source_revision"))
            #expect(columns.contains("updated_at"))
        }
    }

    @Test("materializes translations only for local tags")
    func materializesOnlyLocalTags() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["female:lolicon"]"#
        )

        let count = try context.tags.materializeTranslations(
            [
                ExternalTagTranslation(
                    namespace: "female",
                    name: "lolicon",
                    translatedName: "萝莉",
                    intro: "简介",
                    links: ["https://example.com/lolicon"]
                ),
                ExternalTagTranslation(
                    namespace: "female",
                    name: "missing tag",
                    translatedName: "不存在",
                    intro: nil,
                    links: []
                )
            ],
            languageCode: EhTagTranslationCache.languageCode,
            source: EhTagTranslationCache.source,
            sourceRevision: "rev1"
        )

        let tag = try #require(try context.tags.fetchAllTags().first)
        let translation = try #require(
            try context.tags.translation(for: tag, languageCode: EhTagTranslationCache.languageCode)
        )

        #expect(count == 1)
        #expect(translation.translatedName == "萝莉")
        #expect(translation.intro == "简介")
        #expect(translation.links == ["https://example.com/lolicon"])
        #expect(translation.sourceRevision == "rev1")
    }

    @Test("resolver falls back to raw tag name")
    func resolverFallsBackToRawTagName() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["female:lolicon","artist:sample"]"#
        )
        _ = try context.tags.materializeTranslations(
            [
                ExternalTagTranslation(
                    namespace: "female",
                    name: "lolicon",
                    translatedName: "萝莉",
                    intro: nil,
                    links: []
                )
            ],
            languageCode: EhTagTranslationCache.languageCode,
            source: EhTagTranslationCache.source,
            sourceRevision: "rev1"
        )

        let resolver = TagTranslationResolver(repository: context.tags)
        let tags = try context.tags.fetchAllTags()
        let translated = try #require(tags.first { $0.rawValue == "female:lolicon" })
        let untranslated = try #require(tags.first { $0.rawValue == "artist:sample" })

        #expect(try resolver.resolvedName(for: translated) == "萝莉")
        #expect(try resolver.resolvedName(for: translated, isEnabled: true) == "萝莉")
        #expect(try resolver.resolvedName(for: translated, isEnabled: false) == "lolicon")
        #expect(try resolver.resolvedTranslation(for: translated, isEnabled: false) == nil)
        #expect(try resolver.resolvedName(for: untranslated) == "sample")
    }

    @Test("repository summaries omit translations when language is nil")
    func repositorySummariesOmitTranslationsWhenLanguageIsNil() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["female:lolicon","female:schoolgirl"]"#
        )
        _ = try context.tags.materializeTranslations(
            [
                ExternalTagTranslation(
                    namespace: "female",
                    name: "lolicon",
                    translatedName: "萝莉",
                    intro: "简介",
                    links: ["https://example.com/lolicon"]
                )
            ],
            languageCode: EhTagTranslationCache.languageCode,
            source: EhTagTranslationCache.source,
            sourceRevision: "rev1"
        )

        let summaries = try context.tags.summaries(namespace: "female", languageCode: nil)
        let lolicon = try #require(summaries.first { $0.rawValue == "female:lolicon" })

        #expect(summaries.count == 2)
        #expect(lolicon.count == 1)
        #expect(lolicon.translatedName == nil)
        #expect(lolicon.translationIntro == nil)
        #expect(lolicon.translationLinks == [])
    }

    @Test("repository summaries join translations in one namespace query")
    func repositorySummariesJoinTranslationsInOneNamespaceQuery() throws {
        let context = try makeContext()
        let first = try context.books.insert(sampleBook())
        let second = try context.books.insert(sampleBook(hash: "sha1-second", filepath: "/tmp/second.cbz"))
        try context.tags.rebuildTags(
            forBookID: try #require(first.databaseID),
            tagsJSON: #"["female:lolicon","female:schoolgirl"]"#
        )
        try context.tags.rebuildTags(
            forBookID: try #require(second.databaseID),
            tagsJSON: #"["female:lolicon"]"#
        )
        _ = try context.tags.materializeTranslations(
            [
                ExternalTagTranslation(
                    namespace: "female",
                    name: "lolicon",
                    translatedName: "萝莉",
                    intro: "简介",
                    links: ["https://example.com/lolicon"]
                )
            ],
            languageCode: EhTagTranslationCache.languageCode,
            source: EhTagTranslationCache.source,
            sourceRevision: "rev1"
        )

        let summaries = try context.tags.summaries(
            namespace: "female",
            languageCode: EhTagTranslationCache.languageCode
        )
        let lolicon = try #require(summaries.first { $0.rawValue == "female:lolicon" })
        let schoolgirl = try #require(summaries.first { $0.rawValue == "female:schoolgirl" })

        #expect(summaries.map(\.rawValue) == ["female:lolicon", "female:schoolgirl"])
        #expect(lolicon.count == 2)
        #expect(lolicon.translatedName == "萝莉")
        #expect(lolicon.translationIntro == "简介")
        #expect(lolicon.translationLinks == ["https://example.com/lolicon"])
        #expect(schoolgirl.translatedName == nil)
        #expect(schoolgirl.translationIntro == nil)
        #expect(schoolgirl.translationLinks == [])
    }

    @Test("library service tag summaries honor translation toggle")
    func libraryServiceTagSummariesHonorTranslationToggle() throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["female:lolicon","female:schoolgirl"]"#
        )
        _ = try context.tags.materializeTranslations(
            [
                ExternalTagTranslation(
                    namespace: "female",
                    name: "lolicon",
                    translatedName: "萝莉",
                    intro: "简介",
                    links: ["https://example.com/lolicon"]
                )
            ],
            languageCode: EhTagTranslationCache.languageCode,
            source: EhTagTranslationCache.source,
            sourceRevision: "rev1"
        )
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags
        )

        let untranslated = try service.tagSummaries(namespace: "female", isTagTranslationEnabled: false)
        let translated = try service.tagSummaries(namespace: "female", isTagTranslationEnabled: true)

        #expect(untranslated.first { $0.rawValue == "female:lolicon" }?.displayName == "lolicon")
        #expect(untranslated.first { $0.rawValue == "female:lolicon" }?.translationIntro == nil)
        #expect(untranslated.first { $0.rawValue == "female:lolicon" }?.translationLinks == [])
        #expect(translated.first { $0.rawValue == "female:lolicon" }?.displayName == "萝莉")
        #expect(translated.first { $0.rawValue == "female:lolicon" }?.translationIntro == "简介")
        #expect(translated.first { $0.rawValue == "female:lolicon" }?.translationLinks == ["https://example.com/lolicon"])
        #expect(translated.first { $0.rawValue == "female:schoolgirl" }?.displayName == "schoolgirl")
    }

    @Test("tag summary sorter follows display name and count direction")
    func tagSummarySorterUsesDisplayNameAndCountDirection() {
        let tags = [
            TagDisplaySummary(
                id: 1,
                namespace: "artist",
                name: "zeta",
                rawValue: "artist:zeta",
                displayName: "阿尔法",
                count: 2
            ),
            TagDisplaySummary(
                id: 2,
                namespace: "artist",
                name: "alpha",
                rawValue: "artist:alpha",
                displayName: "贝塔",
                count: 5
            )
        ]

        #expect(
            TagSummarySorter.sorted(tags, strategy: .alphabetical, direction: .ascending).map(\.id)
                == [1, 2]
        )
        #expect(
            TagSummarySorter.sorted(tags, strategy: .count, direction: .descending).map(\.id)
                == [2, 1]
        )
    }

    @Test("category search matches translated and original names within the selected subpage")
    func categorySearchFiltersBeforePaging() {
        let workTags = [
            TagDisplaySummary(
                id: 1, namespace: "parody", name: "love live", rawValue: "parody:love live",
                displayName: "ラブライブ", count: 8
            ),
            TagDisplaySummary(
                id: 2, namespace: "parody", name: "touhou", rawValue: "parody:touhou",
                displayName: "东方Project", count: 5
            ),
            TagDisplaySummary(
                id: 3, namespace: "parody", name: "love lab", rawValue: "parody:love lab",
                displayName: "恋爱实验室", count: 2
            )
        ]
        let characterTags = [
            TagDisplaySummary(
                id: 4, namespace: "character", name: "love", rawValue: "character:love",
                displayName: "另一位角色", count: 1
            )
        ]

        #expect(TagSummarySearch.filtered(workTags, query: "  LOVE  ").map(\.id) == [1, 3])
        #expect(TagSummarySearch.filtered(workTags, query: "东方").map(\.id) == [2])
        #expect(TagSummarySearch.filtered(workTags, query: " ").map(\.id) == [1, 2, 3])
        #expect(TagSummarySearch.filtered(workTags, query: "another").isEmpty)

        let scoped = TagSummarySearch.filtered(workTags, query: "love")
        let firstPage = TagCategoryPresentation(tags: scoped, page: 1, pageSize: 1)
        let secondPage = TagCategoryPresentation(tags: scoped, page: 2, pageSize: 1)
        #expect(firstPage.tagCount == 2)
        #expect(firstPage.sections.first?.tags.map(\.id) == [1])
        #expect(secondPage.sections.first?.tags.map(\.id) == [3])
        #expect(TagSummarySearch.filtered(workTags + characterTags, query: "love").count == 3)
    }

    @Test("tag hover explanation delay gates popover display")
    func tagHoverExplanationDelayGatesPopoverDisplay() {
        #expect(!TagHoverExplanationDelay.shouldShow(elapsedMilliseconds: 599, isHovering: true, hasIntro: true))
        #expect(TagHoverExplanationDelay.shouldShow(elapsedMilliseconds: 600, isHovering: true, hasIntro: true))
        #expect(!TagHoverExplanationDelay.shouldShow(elapsedMilliseconds: 800, isHovering: false, hasIntro: true))
        #expect(!TagHoverExplanationDelay.shouldShow(elapsedMilliseconds: 800, isHovering: true, hasIntro: false))
    }

    @Test("tag summary sorter handles flattened namespace groups")
    func tagSummarySorterHandlesFlattenedNamespaceGroups() {
        let groupedTags: [TagNamespaceGroup: [TagDisplaySummary]] = [
            .female: [
                TagDisplaySummary(
                    id: 1,
                    namespace: "female",
                    name: "schoolgirl",
                    rawValue: "female:schoolgirl",
                    displayName: "alpha schoolgirl",
                    count: 2
                )
            ],
            .male: [
                TagDisplaySummary(
                    id: 2,
                    namespace: "male",
                    name: "glasses",
                    rawValue: "male:glasses",
                    displayName: "glasses",
                    count: 5
                )
            ],
            .location: [
                TagDisplaySummary(
                    id: 3,
                    namespace: "location",
                    name: "school",
                    rawValue: "location:school",
                    displayName: "school",
                    count: 3
                )
            ]
        ]

        let flattened = TagNamespaceGroup.allCases.flatMap { groupedTags[$0] ?? [] }

        #expect(
            TagSummarySorter.sorted(flattened, strategy: .count, direction: .descending).map(\.rawValue)
                == ["male:glasses", "location:school", "female:schoolgirl"]
        )
        #expect(
            TagSummarySorter.sorted(flattened, strategy: .alphabetical, direction: .ascending).map(\.rawValue)
                == ["female:schoolgirl", "male:glasses", "location:school"]
        )
    }

    @Test("tag category grouped presentation preserves namespace order and counts")
    func tagCategoryGroupedPresentationPreservesNamespaceOrderAndCounts() {
        let female = TagDisplaySummary(
            id: 1,
            namespace: "female",
            name: "schoolgirl",
            rawValue: "female:schoolgirl",
            displayName: "schoolgirl",
            count: 2
        )
        let male = TagDisplaySummary(
            id: 2,
            namespace: "male",
            name: "glasses",
            rawValue: "male:glasses",
            displayName: "glasses",
            count: 5
        )
        let presentation = TagCategoryPresentation(
            groupedTags: [
                (.female, [female]),
                (.male, [male])
            ]
        )

        #expect(presentation.sections.map(\.id) == ["female", "male"])
        #expect(presentation.sections.map(\.titleKey) == [.tagNamespaceFemale, .tagNamespaceMale])
        #expect(presentation.sections.map(\.hasTopSpacing) == [false, true])
        #expect(presentation.tagCount == 2)
    }

    @Test("tag category flat presentation keeps sorted tag order")
    func tagCategoryFlatPresentationKeepsSortedTagOrder() {
        let tags = [
            TagDisplaySummary(
                id: 1,
                namespace: "artist",
                name: "zeta",
                rawValue: "artist:zeta",
                displayName: "Zeta",
                count: 1
            ),
            TagDisplaySummary(
                id: 2,
                namespace: "artist",
                name: "alpha",
                rawValue: "artist:alpha",
                displayName: "Alpha",
                count: 3
            )
        ]
        let sorted = TagSummarySorter.sorted(tags, strategy: .count, direction: .descending)
        let presentation = TagCategoryPresentation(tags: sorted)

        #expect(presentation.sections.count == 1)
        #expect(presentation.sections.first?.titleKey == nil)
        #expect(presentation.sections.first?.tags.map(\.rawValue) == ["artist:alpha", "artist:zeta"])
        #expect(presentation.tagCount == 2)
    }

    @Test("tag category flat presentation paginates sorted tags")
    func tagCategoryFlatPresentationPaginatesSortedTags() {
        let tags = (1...5).map { index in
            TagDisplaySummary(
                id: Int64(index),
                namespace: "artist",
                name: "tag-\(index)",
                rawValue: "artist:tag-\(index)",
                displayName: "Tag \(index)",
                count: index
            )
        }
        let presentation = TagCategoryPresentation(tags: tags, page: 2, pageSize: 2)

        #expect(presentation.sections.count == 1)
        #expect(presentation.sections.first?.tags.map(\.rawValue) == ["artist:tag-3", "artist:tag-4"])
        #expect(presentation.tagCount == 5)
    }

    @Test("tag category grouped subpage paginates within selected namespace")
    func tagCategoryGroupedSubpagePaginatesWithinSelectedNamespace() {
        let selectedNamespaceTags = [
            tagSummary(id: 1, namespace: "male", name: "teacher"),
            tagSummary(id: 2, namespace: "male", name: "student"),
            tagSummary(id: 3, namespace: "male", name: "glasses")
        ]
        let presentation = TagCategoryPresentation(tags: selectedNamespaceTags, page: 2, pageSize: 2)

        #expect(presentation.sections.count == 1)
        #expect(presentation.sections.first?.titleKey == nil)
        #expect(presentation.sections.first?.tags.map(\.rawValue) == ["male:glasses"])
        #expect(presentation.tagCount == 3)
    }

    @Test("tag category presentation paginates followed filtered tags")
    func tagCategoryPresentationPaginatesFollowedFilteredTags() {
        let tags = [
            tagSummary(id: 1, namespace: "artist", name: "first", isFollowed: true),
            tagSummary(id: 2, namespace: "artist", name: "second", isFollowed: false),
            tagSummary(id: 3, namespace: "artist", name: "third", isFollowed: true)
        ]
        let followedTags = tags.filter(\.isFollowed)
        let presentation = TagCategoryPresentation(tags: followedTags, page: 1, pageSize: 20)

        #expect(presentation.sections.first?.tags.map(\.rawValue) == ["artist:first", "artist:third"])
        #expect(presentation.tagCount == 2)
    }

    @Test("tag category pages define tab and namespace order")
    func tagCategoryPagesDefineTabAndNamespaceOrder() {
        #expect(TagCategory.allCases == [.creator, .work, .tags])
        #expect(TagCategory.creator.defaultTab == .artist)
        #expect(TagCategory.work.defaultTab == .parody)
        #expect(TagCategory.tags.defaultTab == nil)
        #expect(TagCategory.creator.namespaces == ["artist", "group"])
        #expect(TagCategory.work.namespaces == ["parody", "character"])
        #expect(TagCategory.tags.namespaces == ["female", "male", "mixed", "location", "other"])
    }

    @Test("tag display name parses markdown image and text")
    func tagDisplayNameParsesMarkdownImageAndText() throws {
        let displayName = TagDisplayName(
            markdown: "![拉拉图标](https://example.com/love.webp)LoveLive!"
        )

        #expect(displayName.text == "LoveLive!")
        #expect(displayName.imageURL?.absoluteString == "https://example.com/love.webp")
        #expect(displayName.imageAltText == "拉拉图标")
    }

    @Test("tag display summary caches parsed display fields")
    func tagDisplaySummaryCachesParsedDisplayFields() {
        let summary = TagDisplaySummary(
            id: 1,
            namespace: "parody",
            name: "love live",
            rawValue: "parody:love live",
            displayName: "![拉拉图标](https://example.com/love.webp)LoveLive!",
            count: 1
        )

        #expect(summary.displayText == "LoveLive!")
        #expect(summary.displayImageURL?.absoluteString == "https://example.com/love.webp")
        #expect(summary.displayImageAltText == "拉拉图标")
    }

    @Test("tag display name keeps plain text unchanged")
    func tagDisplayNameKeepsPlainText() {
        let displayName = TagDisplayName(markdown: "LoveLive!")

        #expect(displayName.text == "LoveLive!")
        #expect(displayName.imageURL == nil)
        #expect(displayName.imageAltText == nil)
    }

    @Test("tag display name uses first image and removes all image markdown")
    func tagDisplayNameUsesFirstImageAndRemovesAllImages() {
        let displayName = TagDisplayName(
            markdown: "![first](https://example.com/first.webp) Alpha ![second](https://example.com/second.webp) Beta"
        )

        #expect(displayName.text == "Alpha Beta")
        #expect(displayName.imageURL?.absoluteString == "https://example.com/first.webp")
        #expect(displayName.imageAltText == "first")
    }

    @Test("tag display name strips unsupported image urls but keeps text")
    func tagDisplayNameStripsUnsupportedImageURLs() {
        let displayName = TagDisplayName(markdown: "![bad](file:///tmp/icon.webp)LoveLive!")

        #expect(displayName.text == "LoveLive!")
        #expect(displayName.imageURL == nil)
    }

    @Test("tag image cache ignores unsupported urls")
    func tagImageCacheIgnoresUnsupportedURLs() async throws {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = TagImageCacheService(rootURLProvider: { directory })

        let data = await service.imageData(for: URL(string: "file:///tmp/icon.webp")!)

        #expect(data == nil)
    }

    @MainActor
    @Test("update downloads JSON cache and refreshes existing translations")
    func updateDownloadsJSONCacheAndRefreshesExistingTranslations() async throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["female:lolicon"]"#
        )

        let appDataRoot = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = tagTranslationDatabaseData(
            entries: """
                "lolicon": {
                  "name": "萝莉",
                  "intro": "简介",
                  "links": "https://example.com/ignored.webp"
                },
                "missing tag": {
                  "name": "不存在",
                  "intro": "不应写入",
                  "links": ""
                }
            """
        )
        let service = EhTagTranslationUpdateService(
            appDataRoot: appDataRoot,
            remoteClient: FakeEhTagTranslationRemoteClient(revision: "rev2", database: database)
        )

        let result = try await service.update(repository: context.tags)

        let manifest = try #require(try service.cachedManifest())
        let tag = try #require(try context.tags.fetchAllTags().first)
        let translation = try #require(
            try context.tags.translation(for: tag, languageCode: EhTagTranslationCache.languageCode)
        )

        #expect(result.downloaded)
        #expect(result.files == 1)
        #expect(result.parsedTranslations == 2)
        #expect(result.materializedTranslations == 1)
        #expect(manifest.revision == "rev2")
        #expect(translation.translatedName == "萝莉")
        #expect(translation.links == [])
        #expect(translation.sourceRevision == "rev2")
    }

    @MainActor
    @Test("same revision skips download but rematerializes cached translations")
    func sameRevisionSkipsDownload() async throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["female:lolicon"]"#
        )

        let appDataRoot = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = EhTagTranslationUpdateService(
            appDataRoot: appDataRoot,
            remoteClient: FakeEhTagTranslationRemoteClient(revision: "rev3", database: Data())
        )
        let cache = EhTagTranslationCache(appDataRoot: appDataRoot)
        try cache.replaceCache(
            databaseData: tagTranslationDatabaseData(
                entries: """
                    "lolicon": {
                      "name": "萝莉",
                      "intro": "简介",
                      "links": ""
                    }
                """
            ),
            manifest: EhTagTranslationManifest(
                source: EhTagTranslationCache.source,
                repositoryURL: EhTagTranslationCache.repositoryURL,
                branch: EhTagTranslationCache.branch,
                revision: "rev3",
                downloadedAt: 1,
                status: "success",
                message: nil
            )
        )

        let result = try await service.update(repository: context.tags)

        #expect(!result.downloaded)
        #expect(result.materializedTranslations == 1)
    }

    @MainActor
    @Test("failed update keeps existing cache and translations")
    func failedUpdateKeepsOldData() async throws {
        let context = try makeContext()
        let book = try context.books.insert(sampleBook())
        let bookID = try #require(book.databaseID)
        try context.tags.rebuildTags(
            forBookID: bookID,
            tagsJSON: #"["female:lolicon"]"#
        )

        let appDataRoot = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = EhTagTranslationUpdateService(
            appDataRoot: appDataRoot,
            remoteClient: FailingEhTagTranslationRemoteClient()
        )
        let cache = EhTagTranslationCache(appDataRoot: appDataRoot)
        try cache.replaceCache(
            databaseData: tagTranslationDatabaseData(
                entries: """
                    "lolicon": {
                      "name": "旧译名",
                      "intro": "旧简介",
                      "links": ""
                    }
                """
            ),
            manifest: EhTagTranslationManifest(
                source: EhTagTranslationCache.source,
                repositoryURL: EhTagTranslationCache.repositoryURL,
                branch: EhTagTranslationCache.branch,
                revision: "old",
                downloadedAt: 1,
                status: "success",
                message: nil
            )
        )
        _ = try service.materializeCachedTranslations(repository: context.tags)

        await #expect(throws: Error.self) {
            _ = try await service.update(repository: context.tags)
        }

        let manifest = try #require(try service.cachedManifest())
        let tag = try #require(try context.tags.fetchAllTags().first)
        let translation = try #require(
            try context.tags.translation(for: tag, languageCode: EhTagTranslationCache.languageCode)
        )

        #expect(manifest.revision == "old")
        #expect(translation.translatedName == "旧译名")
    }

    private func makeContext() throws -> RepositoryContext {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: directory.appendingPathComponent("NyaEH.sqlite").path)
        return RepositoryContext(
            database: database,
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            metadata: SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue),
            tags: SQLiteTagRepository(dbQueue: database.dbQueue)
        )
    }

    private func sampleBook(hash: String = "sha1-sample", filepath: String = "/tmp/sample.cbz") -> LibraryBook {
        LibraryBook(
            title: "Sample Book",
            hash: hash,
            filepath: filepath,
            type: .archive,
            fileCount: 42,
            bundleSize: 123_456,
            mtime: 1_775_657_594_420,
            status: .unscanned,
            date: 1_775_657_594_420,
            tags: #"["female:lolicon"]"#
        )
    }

    private func tagSummary(
        id: Int64,
        namespace: String,
        name: String,
        isFollowed: Bool = false
    ) -> TagDisplaySummary {
        TagDisplaySummary(
            id: id,
            namespace: namespace,
            name: name,
            rawValue: "\(namespace):\(name)",
            displayName: name,
            isFollowed: isFollowed,
            count: 1
        )
    }

    private func tagTranslationDatabaseData(entries: String) -> Data {
        Data(
            """
            {
              "repo": "https://github.com/EhTagTranslation/Database",
              "head": { "sha": "sample" },
              "version": 7,
              "data": [
                {
                  "namespace": "rows",
                  "count": 1,
                  "data": {
                    "female": {
                      "name": "女性",
                      "intro": "索引",
                      "links": "数据库页面"
                    }
                  }
                },
                {
                  "namespace": "female",
                  "count": 1,
                  "data": {
            \(entries)
                  }
                }
              ]
            }
            """.utf8
        )
    }

}

private struct RepositoryContext {
    let database: DatabaseManager
    let books: SQLiteLibraryBookRepository
    let metadata: SQLiteGalleryMetadataRepository
    let tags: SQLiteTagRepository
}

private struct FakeEhTagTranslationRemoteClient: EhTagTranslationRemoteClient {
    var revision: String
    var database: Data

    func downloadDatabase(proxySettings: NetworkProxySettings) async throws -> EhTagTranslationDownload {
        EhTagTranslationDownload(data: database, revision: revision)
    }
}

private struct FailingEhTagTranslationRemoteClient: EhTagTranslationRemoteClient {
    func downloadDatabase(proxySettings: NetworkProxySettings) async throws -> EhTagTranslationDownload {
        throw URLError(.cannotLoadFromNetwork)
    }
}
