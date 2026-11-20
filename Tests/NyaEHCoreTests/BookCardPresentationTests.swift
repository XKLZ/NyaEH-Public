import SwiftUI
import Testing
@testable import NyaEHCore

@Suite("Book card presentation")
struct BookCardPresentationTests {
    @Test func metadataFitsTheNarrowestCardAndUsesItsBreakpoint() {
        for width in stride(from: 112, through: 176, by: 8) {
            let gap = BookCardMetrics.metadataSpacing(width: CGFloat(width))
            #expect(gap == (width < 128 ? 6 : 8))
            let fixedSlots: CGFloat = 19 + 12 + 12 + 36
            let paddingAndOuterSpacing: CGFloat = 4 + 8 + 8
            #expect(fixedSlots + 2 * gap + paddingAndOuterSpacing <= CGFloat(width))
        }
        #expect(BookCardMetrics.prefersDarkInk(linearRed: 1, green: 1, blue: 0))
        #expect(!BookCardMetrics.prefersDarkInk(linearRed: 0.09, green: 0.01, blue: 0.24))
    }

    @Test func unifiedCardKeepsMetadataAndReaderInsideItsBody() {
        for width in stride(from: 112, through: 176, by: 8) {
            let current = BookCardMetrics(width: width, appearance: .standard)
            let card = BookCardMetrics(width: width)
            #expect(card.appearance == .unified)
            #expect(card.coverHeight == CGFloat(width) * 1.25)
            #expect(card.coverHeight < current.coverHeight)
            #expect(current.contentWidth == CGFloat(width))
            #expect(card.contentInset == (width < 128 ? 4 : 6))
            let allSlots: CGFloat = 19 + 12 + 12 + 36
            let padding: CGFloat = 4 + 8
            let gaps = 2 * (BookCardMetrics.metadataSpacing(width: card.cardWidth) + card.metadataOuterSpacing)
            #expect(allSlots + padding + gaps <= card.contentWidth)
            #expect(card.metadataTop - card.coverHeight == current.metadataTop - current.coverHeight)
            #expect(card.cardHeight - card.bottomInset - card.coverHeight == current.cardHeight - current.coverHeight)
            #expect(card.cardHeight - card.bottomInset - card.footerHeight(for: .all)
                    == card.metadataTop + card.metadataHeight + card.infoSpacing)
        }
    }

    @MainActor @Test func readingBadgesMatchScoreHeightAndMinimumWidth() throws {
        let localizer = AppLocalizer(language: .zhHans)
        let score = BookCardRating(rating: 3.8, localizer: localizer)
        let size = try #require(ImageRenderer(content: score.fixedSize()).nsImage?.size)
        #expect(size.height == 16)
        for reading: BookCardReadingStatus in [.unread, .completed(openCount: 0), .completed(openCount: 123)] {
            let row = BookCardReadingRow(reading: reading, fields: .all, localizer: localizer)
            let badge = try #require(ImageRenderer(content: row.fixedSize()).nsImage?.size)
            #expect(badge.height == size.height)
            #expect(badge.width >= size.width)
            if reading == .completed(openCount: 123) { #expect(badge.width > size.width) }
        }
    }

    @MainActor @Test func gallerySamplesShareAppearanceButOwnChanges() throws {
        let localizer = AppLocalizer(language: .zhHans)
        var opened: LibraryBook.ID?
        let gallery = DevelopmentCardSamples(localizer: localizer) { opened = $0.id }
        let fresh = DevelopmentCardSamples(localizer: localizer) { _ in }
        #expect(gallery.groups.map(\.count) == [1, 2, 3, 12, 1, 1, 1, 1])
        #expect(BookCardMetadata(book: gallery.displayed[0]) == BookCardMetadata(book: gallery.displayed[1]))
        let original = gallery.displayed[1]
        let other = try #require(gallery.cardVersionAlternatives(to: original, showsUserHidden: false).first)
        gallery.setCardMarked(true, book: other)
        gallery.setPrimaryVersion(other, completion: nil)
        gallery.read(other)
        gallery.updateProgress(book: other, page: 4, total: 12, completed: false)
        #expect(opened == other.id && gallery.displayed[1].id == other.id && gallery.displayed[1].mark)
        #expect(gallery.readingState(for: original)?.currentPageIndex == 11)
        #expect(fresh.displayed[1].id == original.id && !fresh.bookForCard(other).mark)
        #expect(fresh.readingState(for: other)?.currentPageIndex == 11)
    }

    @Test func versionChoicesStayWithinGroupAndScope() {
        let primary = book(1, group: 3)
        let translation = book(2, group: 3)
        let hidden = book(3, group: 3, hidden: true)
        let different = book(4, group: 4)
        let standalone = book(5)
        let choices = [primary, translation, hidden, different, standalone]

        #expect(BookCardVersionChoices.alternatives(to: primary, among: choices,
                                                    showsUserHidden: false).map(\.databaseID) == [2])
        #expect(BookCardVersionChoices.alternatives(to: primary, among: choices,
                                                    showsUserHidden: true).map(\.databaseID) == [3])
        #expect(BookCardVersionChoices.alternatives(to: standalone, among: choices, showsUserHidden: false).isEmpty)
    }

    @Test func managementCommandsResolveTheCurrentGroupOfTheClickedEdition() {
        var target = book(15, group: 4)
        target.collectionID = 8
        #expect(CardMenuCommand.manageSeries.destination(for: target) == .manageSeries("8"))
        #expect(CardMenuCommand.owningSeries.destination(for: target) == .series("8"))
        target.versionGroupID = 21
        #expect(CardMenuCommand.manageVersions.destination(for: target) == .manageVersions("21"))
        target.collectionID = nil
        #expect(CardMenuCommand.manageSeries.destination(for: target) == nil)
    }

    @Test func stackExposesAllVisibleEditionsWithThreeVisualLayers() {
        let primary = book(1, group: 3)
        let companions = [book(2, group: 3), book(3, group: 3), book(4, group: 3), book(5, group: 3, hidden: true)]
        let visible = BookCardVersionChoices.alternatives(to: primary, among: companions, showsUserHidden: false)
        let stack = BookCardEditionStack(current: primary, visibleAlternatives: visible, aggregatesVersions: true)
        #expect(stack.depth == 3)
        #expect(stack.editions.map(\.id) == ["1", "2", "3", "4"])
        #expect(stack.index(for: "5") == 0)
    }

    @Test func ratingsUseVisibleEditionsAndPreferStableOrderOnTies() {
        var primary = book(1, group: 3)
        var first = book(2, group: 3)
        var second = book(3, group: 3)
        var hidden = book(4, group: 3, hidden: true)
        primary.rating = 4.0
        first.rating = 4.5
        second.rating = 4.5
        hidden.rating = 5.0
        let visible = BookCardVersionChoices.alternatives(to: primary, among: [first, second, hidden], showsUserHidden: false)
        #expect(BookCardEditionStack(current: primary, visibleAlternatives: visible, aggregatesVersions: true).highestRating?.id == first.id)
        let individual = BookCardEditionStack(current: primary, visibleAlternatives: visible, aggregatesVersions: false)
        #expect(individual.depth == 1)
        #expect(individual.highestRating?.id == primary.id)
        primary.rating = 4.5
        #expect(BookCardEditionStack(current: primary, visibleAlternatives: visible, aggregatesVersions: true).highestRating?.id == primary.id)
        primary.rating = .infinity
        #expect(BookCardEditionStack(current: primary, visibleAlternatives: [], aggregatesVersions: true).highestRating == nil)
    }

    @Test(arguments: [
        ("chinese", AppLanguage.zhHans, "中"), ("ko", .zhHant, "韓"),
        ("fr", .ja, "仏"), ("japanese", .ko, "일"), ("zh-hans", .en, "ZH")
    ])
    func languageUsesInterfaceAbbreviation(_ code: String, _ language: AppLanguage, _ expected: String) {
        let label = BookCardLanguageLabel(code, interfaceLanguage: language)
        #expect(label.abbreviation == expected)
        #expect(!label.fullName.isEmpty)
    }

    @Test func editionDeckKeepsTheCurrentEdgeAnchoredAndScrollsWhenConstrained() {
        let viewport = CGRect(x: 0, y: 0, width: 360, height: 500)
        for width in [112, 176] {
            for count in [2, 3, 12] {
                for y in [8, 442] {
                    let anchor = CGRect(x: 20, y: y, width: width, height: 24)
                    let deck = EditionDeckPlacement(anchor: anchor, viewport: viewport, count: count)
                    #expect(deck.growsUp == (y == 8))
                    #expect(deck.needsScroll == (count == 12))
                    #expect(deck.frame.width == anchor.width)
                    #expect(deck.growsUp ? deck.frame.minY == anchor.minY
                                         : deck.frame.maxY - EditionDeckPlacement.tileHeight == anchor.minY)
                    #expect(viewport.contains(deck.frame))
                }
            }
        }
        #expect([1, 37, 999, 1250].map(BookCardMetrics.progressLabel(page:)) == ["P1", "P37", "P999", "P1250"])
    }

    @Test func progressLabelSwitchesAtItsMeasuredWidth() {
        for width: CGFloat in [70, 134] {
            for textWidth: CGFloat in [12, 18, 30] {
                let threshold = textWidth + 8
                for fill: CGFloat in [0, 1, threshold - 0.5, threshold, width - 1, width] {
                    let position = BookCardMetrics.pageLabelPosition(width: width, fill: fill, numberWidth: textWidth)
                    #expect(position.onFill == (fill >= threshold))
                    #expect(position.x == (position.onFill ? fill - textWidth - 4 : min(fill + 4, width - textWidth - 4)))
                    #expect(position.x >= 0 && position.x + textWidth <= width)
                }
                let unknown = BookCardMetrics.pageLabelPosition(width: width, fill: nil, numberWidth: textWidth)
                #expect(unknown.x == 4 && !unknown.onFill)
            }
        }
        let metrics = BookCardMetrics.default
        #expect(metrics.footerHeight(for: [.directRead, .readingStatus]) == metrics.infoRowHeight)
        #expect(metrics.footerHeight(for: [.directRead]) == metrics.ratingHeight)
    }

    @Test func returnTripUsesOnlyVisibleTilesAndEndsAtTheOriginalEdge() {
        for count in [2, 3, 12] {
            for y in [8, 252] {
                let layout = EditionDeckPlacement(anchor: CGRect(x: 0, y: y, width: 112, height: 24),
                                                  viewport: CGRect(x: 0, y: 0, width: 240, height: 300), count: count)
                for top: CGFloat? in [nil, 118] {
                    let motion = EditionDeckMotion(layout: layout, count: count, scrollTop: top)
                    #expect(motion.duration <= 0.30)
                    #expect(motion.amount(for: motion.visible.lowerBound, progress: 0.5)
                            > motion.amount(for: motion.visible.upperBound, progress: 0.5))
                    for index in motion.visible {
                        #expect(motion.amount(for: index, progress: 0) == 0)
                        #expect(abs(motion.amount(for: index, progress: 1) - 1) < 0.0001)
                    }
                    if top == nil { #expect(abs(motion.returnOffset(for: 0)) < 0.001) }
                    if count == 12 { #expect(motion.visible.count < count) }
                }
            }
        }
    }

    @MainActor @Test func interruptedReturnAndPrimaryCommitKeepTheirOwnLifetimes() {
        let session = EditionDeckSession(keyboard: false, anchorHovered: false)
        session.dismiss(reversible: true)
        let interrupted = session.revision
        session.hover(true, panel: true)
        session.finishRetraction(revision: interrupted)
        #expect(session.phase == .open)
        session.beginSave()
        session.dismiss()
        #expect(session.saving && !session.canSelect && session.phase == .open)
        session.finishSave(succeeded: false)
        #expect(session.canSelect)
        session.beginSave()
        session.finishSave(succeeded: true)
        session.sourceLeft()
        session.hover(true, panel: true)
        #expect(session.phase == .closing)
        session.finishRetraction(revision: interrupted)
        #expect(session.isPresented)
        session.finishRetraction(revision: session.revision)
        #expect(!session.isPresented)
    }

    @MainActor @Test func crossingTheGapCancelsHoverDismissal() async throws {
        let session = EditionDeckSession(keyboard: false, anchorHovered: true)
        session.hover(false, panel: false)
        session.hover(true, panel: true)
        try await Task.sleep(for: .milliseconds(220))
        #expect(session.phase == .open)
        session.hover(false, panel: true)
        // The full suite shares the main actor. Wait for the scheduled dismissal to run.
        let deadline = ContinuousClock.now + .seconds(5)
        while session.phase == .open && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.phase == .closing)
        session.hover(true, panel: true)
        #expect(session.phase == .open)
        session.dismiss()
        session.hover(true, panel: false)
        #expect(session.phase == .closing)
        session.sourceLeft()
        #expect(!session.isPresented)
    }

    @Test func absentFieldsAndNonWebLinksAreOmitted() {
        var file = book(1)
        file.url = "file:///tmp/1.cbz"
        file.languageCode = " UNKNOWN "
        file.censorship = "unknown"
        file.rating = .infinity
        file.pages = 0
        file.fileCount = 17
        let metadata = BookCardMetadata(book: file)

        #expect(metadata.language == nil)
        #expect(metadata.censorship == nil)
        #expect(metadata.rating == nil)
        #expect(metadata.url == nil)
        #expect(metadata.pages == 17)

        file.pages = 18
        file.url = "https://example.com/gallery"
        #expect(BookCardMetadata(book: file).pages == 18)
        #expect(BookCardMetadata(book: file).url?.absoluteString == file.url)
    }

    @Test func readingStatusUsesPersistedProgressInsteadOfOpenCount() {
        #expect(BookCardReadingStatus(state: nil, openCount: 4) == .unread)
        var state = BookReadingState.initial(bookID: 1)
        #expect(BookCardReadingStatus(state: state, openCount: 1) == .unread)
        state.currentPageIndex = 2
        #expect(BookCardReadingStatus(state: state, openCount: 1) == .reading(current: 3, total: nil))
        state.totalPages = 23
        #expect(BookCardReadingStatus(state: state, openCount: 1) == .reading(current: 3, total: 23))
        state.completedAt = 1
        #expect(BookCardReadingStatus(state: state, openCount: 3) == .completed(openCount: 3))
    }

    @Test func clearedRowsReduceCardAndSeriesPopoverHeight() {
        let metrics = BookCardMetrics.default
        #expect(metrics.cardHeight(for: [.color, .rating, .readingStatus]) == metrics.cardHeight)
        #expect(metrics.cardHeight - metrics.cardHeight(for: [.metadata, .reading]) == metrics.ratingHeight + metrics.infoSpacing)
        let popover = SearchCollectionPopoverMetrics(viewport: CGSize(width: 1000, height: 800), memberCount: 2, fields: [])
        #expect(popover.memberHeight == metrics.coverHeight + metrics.regularTitleHeight + metrics.contentSpacing + metrics.bottomInset)
    }

    @MainActor
    @Test func preferencesDistinguishUnsetFromAllHidden() throws {
        let domain = TestRunResources.newDefaultsDomain()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(userDefaults: defaults, applicationLanguageDomain: domain)

        #expect(preferences.bookCardFields == .all)
        defaults.set(0, forKey: "NyaEH.cardFields")
        #expect(AppPreferences(userDefaults: defaults, applicationLanguageDomain: domain).bookCardFields == [.directRead])
        preferences.bookCardFields = []
        #expect(AppPreferences(userDefaults: defaults, applicationLanguageDomain: domain).bookCardFields.isEmpty)
        preferences.bookCardFields = [.language, .readingNumbers]
        #expect(AppPreferences(userDefaults: defaults, applicationLanguageDomain: domain).bookCardFields == [.language, .readingNumbers])
    }

    @Test func cardMenuFollowsMembershipIndependentlyOfVisibleAlternatives() {
        for series in [nil, Int64(1)] {
            for group in [nil, Int64(2)] {
                var target = book(7, group: group)
                target.collectionID = series
                let hidden = book(8, group: group, hidden: true)
                #expect(BookCardVersionChoices.alternatives(to: target, among: [hidden], showsUserHidden: false).isEmpty)
                let sections = CardMenuCommand.sections(book: target, reading: nil, canNavigate: true, canReveal: true, selected: nil)
                let commands = sections.flatMap { $0 }
                #expect(sections.allSatisfy { !$0.isEmpty })
                #expect(sections.prefix(2).elementsEqual([[.details, .read], [.favorite, .markRead]]))
                #expect(commands.contains(.owningSeries) == (series != nil))
                #expect(commands.contains(.manageSeries) == (series != nil))
                #expect(commands.contains(.manageVersions) == (group != nil))
                #expect(sections.last == [.copyTitle, .finder])
            }
        }
    }

    @Test func menuLinksSelectionAndReadingState() {
        var target = book(9)
        target.mark = true
        var state = BookReadingState.initial(bookID: 9)
        state.currentPageIndex = 12
        for link in [nil, "file:///tmp/sample.cbz", "https://", "https://example.org/gallery/9"] {
            target.url = link
            let sections = CardMenuCommand.sections(book: target, reading: state, canNavigate: true, canReveal: true, selected: false)
            #expect(sections[0] == [.details, .resume])
            #expect(sections[1] == [.unfavorite, .markRead])
            #expect(sections[2].contains(.source) == (link == "https://example.org/gallery/9"))
            #expect(sections.last == [.select])
        }
        state.completedAt = 42
        #expect(CardMenuCommand.sections(book: target, reading: state, canNavigate: false, canReveal: false, selected: true)[1] == [.unfavorite, .markUnread])
        #expect(CardMenuCommand.seriesSections(selected: nil) == [[.series, .manageSeries]])
        #expect(CardMenuCommand.seriesSections(selected: true) == [[.series, .manageSeries], [.deselect]])
    }

    @MainActor @Test func menuTargetIsIndependentOfSearchSelectionAndUsesCurrentArchive() throws {
        var opened: String?
        let samples = DevelopmentCardSamples(localizer: .init(language: .en)) { opened = $0.id }
        let selected = Array(samples.displayed.prefix(2))
        let target = samples.groups[2][1]
        let originalCount = target.readCount
        var selection = SearchResultSelectionState()
        for book in selected { selection.toggleSelection(.book(book)) }
        let before = selection.selectedBookIDs
        samples.setPrimaryVersion(target, completion: nil)
        let archive = try #require(samples.book(id: target.id))
        samples.read(archive)
        samples.setCardCompleted(true, book: archive)
        #expect(opened == target.id)
        #expect(samples.book(id: target.id)?.readCount == originalCount)
        #expect(samples.readingState(for: target)?.isCompleted == true)
        #expect(samples.readingState(for: samples.groups[2][0])?.isCompleted == false)
        #expect(selected.allSatisfy { samples.readingState(for: $0)?.isCompleted == false })
        #expect(selection.selectedBookIDs == before)
    }

    @Test func showcaseUsesFivePerGroupAndKeepsTheExactEdition() throws {
        let source = (1...7).map { book(Int64($0), group: 12) }
        for count in [0, 1, 5, 7] {
            let list = Array(source.prefix(count))
            let groups = HomeShowcaseBooks(continuing: list, recent: list.reversed(), recommended: list)
            for group in HomeShowcaseGroup.allCases {
                #expect(groups[group].count == min(5, count))
            }
            #expect(groups[.recent].map(\.id) == Array(list.reversed().prefix(5)).map(\.id))
            #expect(groups.resolve(nil)?.id == list.first?.id)
        }
        let groups = HomeShowcaseBooks(continuing: source, recent: source.reversed(), recommended: [source[1]])
        let last = HomeShowcaseSelection(group: .recent, id: source[2].id)
        let first = try #require(groups.first(in: .recent))
        #expect(groups.adjacent(to: last, offset: 1) == first)
        #expect(groups.adjacent(to: first, offset: -1) == last)
        #expect(groups.resolve(last) == last)
        #expect(groups.first(in: .recommended)?.id == source[1].id)
        let refresh = HomeShowcaseBooks(continuing: [], recent: [source[0]], recommended: [source[1]])
        #expect(refresh.resolve(last) == refresh.first(in: .recent))
        #expect(refresh.resolve(nil) == refresh.first(in: .recommended))
        let recentOnly = HomeShowcaseBooks(continuing: [], recent: [source[0]], recommended: [])
        #expect(recentOnly.resolve(groups.first(in: .continuing)) == recentOnly.first(in: .recent))
    }

    @Test func showcaseNavigatesAcrossRowsAndResolvesTheLastPreviewedEdition() throws {
        let items = (1...5).map { book(Int64($0), group: 9) }
        let rows = HomeShowcaseBooks(continuing: items, recent: [items[2], items[0]], recommended: [])
        let last = HomeShowcaseSelection(group: .continuing, id: items[4].id)
        let shorter = rows.changingRow(from: last, offset: 1)
        #expect(shorter == .init(group: .recent, id: items[0].id))
        let sameBook = try #require(rows.first(in: .continuing))
        #expect(shorter != sameBook)
        #expect(rows.book(for: shorter)?.id == rows.book(for: sameBook)?.id)
        let wrapped = rows.changingRow(from: shorter, offset: 1)
        #expect(wrapped == .init(group: .continuing, id: items[1].id))
        #expect(rows.changingRow(from: wrapped, offset: -1) == shorter)

        let previews = [sameBook, wrapped, shorter, rows.adjacent(to: shorter, offset: -1)]
        let target = try #require(previews.last.flatMap(rows.book(for:)))
        #expect(target.filepath == items[2].filepath)
        #expect(rows.book(for: .init(group: .recommended, id: target.id)) == nil)
    }

    @Test func showcaseLateLookupsCannotSupplyAnotherBooksTintOrCredits() {
        let tint = HomeShowcaseResult(key: "/covers/one", value: "yellow")
        #expect(tint.value(for: "/covers/one") == "yellow")
        #expect(tint.value(for: "/covers/two") == nil)
        let credits = HomeShowcaseResult(key: ["1", "revision-1"], value: ["Writer", "Studio"])
        #expect(credits.value(for: ["2", "revision-1"]) == nil)
        #expect(credits.value(for: ["1", "revision-2"]) == nil)
        #expect(credits.value(for: ["1", "revision-1"]) == ["Writer", "Studio"])
    }

    @Test func categoryDwellOnlySelectsTheLatestNonemptyHeading() throws {
        let first = book(1), second = book(2)
        let books = HomeShowcaseBooks(continuing: [first, second], recent: [second], recommended: [])
        let current = HomeShowcaseSelection(group: .continuing, id: second.id)
        var hover = HomeShowcaseHover()
        hover.hover(.recent, inside: true)
        hover.hover(.continuing, inside: true)
        hover.hover(.recent, inside: false)
        #expect(hover.pending == .continuing)
        #expect(hover.selection(afterDwellingOn: .recent, in: books, current: current) == nil)
        #expect(hover.selection(afterDwellingOn: .continuing, in: books, current: current) == nil)
        hover.hover(.recent, inside: true)
        #expect(hover.selection(afterDwellingOn: .recent, in: books, current: current) == .init(group: .recent, id: second.id))
        hover.hover(.recommended, inside: true)
        #expect(hover.selection(afterDwellingOn: .recommended, in: books, current: current) == nil)
        hover.hover(.recommended, inside: false)
        #expect(hover.pending == nil)
    }

    @Test func tagPreviewReservesTheActualOverflowCounterOnTheSecondLine() {
        func layout(_ widths: [CGFloat]) -> HomeTagPreviewLayout {
            HomeTagPreviewLayout(widths: widths, available: 100, gap: 4, moreWidth: { $0 < 10 ? 20 : 30 })
        }
        #expect(layout([]).rows.isEmpty)
        #expect(layout([48, 48, 100]).hidden == 0)
        let several = layout([48, 48, 48, 48, 36])
        #expect(several.rows == [[0, 1], [2]])
        #expect(several.hidden == 2)
        let many = layout(Array(repeating: 100, count: 15))
        #expect(many.rows == [[0], []])
        #expect(many.hidden == 14)
    }

    @MainActor @Test func progressRetargetsFromThePresentedFractionInEitherDirection() {
        var progress = CardPageProgress(current: 10, total: 100, showsNumber: true, size: .showcase)
        let high = CardPageProgress(current: 90, total: 100, showsNumber: true, size: .showcase)
        #expect(progress.animatableData == 0.1)
        #expect(high.animatableData == 0.9)
        progress.animatableData = 0.5
        let next = CardPageProgress(current: 5, total: 100, showsNumber: true, size: .showcase)
        #expect(progress.animatableData == 0.5 && next.animatableData == 0.05)
        #expect(BookCardMetrics.pageLabelPosition(width: 200, fill: 200 * progress.animatableData, numberWidth: 20).x == 76)
    }

    @Test func showcaseOnlyRotatesWhenIdleAndVisible() {
        let selection = HomeShowcaseSelection(group: .continuing, id: "1")
        func plays(ids: [String] = ["1", "2"], visible: Bool = true, active: Bool = true,
                   interacting: Bool = false, reduceMotion: Bool = false) -> Bool {
            HomeShowcasePlayback(selection: selection, ids: ids, visible: visible, active: active,
                                 interacting: interacting, reduceMotion: reduceMotion) != nil
        }
        #expect(plays())
        #expect(!plays(ids: ["1"]))
        #expect(!plays(visible: false))
        #expect(!plays(active: false))
        #expect(!plays(interacting: true))
        #expect(!plays(reduceMotion: true))
    }

    private func book(_ id: Int64, group: Int64? = nil, hidden: Bool = false) -> LibraryBook {
        LibraryBook(databaseID: id, title: "Book \(id)", hash: "test-\(id)", filepath: "/tmp/test-\(id).cbz",
                    versionGroupID: group, isUserHidden: hidden)
    }
}

@Suite("Development shelf preview")
struct DevelopmentShelfPreviewTests {
    @Test @MainActor func snapshotActionsStayLocalAndRecentBooksKeepTheirEdition() {
        let first = LibraryBook(databaseID: 1, title: "a", hash: "a", filepath: "a", versionGroupID: 1, mark: true)
        let second = LibraryBook(databaseID: 2, title: "b", hash: "b", filepath: "b",
                                 versionGroupID: 1, isPrimaryVersion: false, mark: true)
        var opened: String?
        func snapshot() -> DevelopmentShelfSource {
            DevelopmentShelfSource(favorites: [first], recent: [second, first], companions: { _ in [first, second] },
                                   record: { _ in nil }) { _, book in opened = book.id }
        }
        let preview = snapshot()
        preview.samples.setPrimaryVersion(second, completion: nil)
        #expect(preview.favorites.map(\.id) == [second.id])
        #expect(preview.recent.map(\.id) == [second.id, first.id])
        preview.samples.setCardMarked(false, book: second)
        #expect(preview.favorites.isEmpty)
        #expect(preview.recent.allSatisfy { !$0.mark })
        preview.samples.read(second)
        #expect(opened == second.id)
        preview.samples.updateProgress(book: second, page: 8, total: 50, completed: false)
        #expect(preview.samples.readingState(for: second)?.currentPageIndex == 8)
        let fresh = snapshot()
        #expect(fresh.favorites.first?.id == first.id)
        #expect(fresh.samples.readingState(for: second) == nil)
    }

    @Test func arrivalLimitsDatesColumnsAndLanguage() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let books = (0..<12).map { i in
            LibraryBook(databaseID: Int64(i), title: "Book", hash: "", filepath: "", pages: 24,
                        versionLabel: "汉化版", languageCode: "chinese", createdAt: Int64(12 - i / 3) * 86_400_000)
        }
        #expect(ShelfArrivalDay.groups(books, expanded: false, calendar: utc).map { $0.books.count } == [3, 1])
        #expect(ShelfArrivalDay.groups(books, expanded: true, calendar: utc).flatMap(\.books) == Array(books.prefix(10)))
        #expect(ShelfArrivalDay.groups(books, expanded: true, calendar: utc).map { $0.books.count } == [3, 3, 3, 1])
        let localizer = AppLocalizer(language: .zhHans)
        #expect(ShelfArrivalDay.caption(books[0], localizer: localizer) == "汉化版 · " + localizer.bookPageCount(24))
    }
    @Test func shelfAndTimelineUseTheActualCardWidthAtTheBoundary() {
        for width in [112, 144, 176].map({ CGFloat($0) }) {
            let row = width * 3 + 2 * BookCardMetrics.shelfSpacing
            #expect(ShelfPreviewLayout.controlGutter(count: 3, cardWidth: width, available: row) == 0)
            #expect(ShelfPreviewLayout.controlGutter(count: 3, cardWidth: width, available: row - 1) == 36)
            #expect(ShelfPreviewLayout.controlGutter(count: 1, cardWidth: width, available: row) == 0)
            let boundary = 2 * width + BookCardMetrics.shelfSpacing + ShelfPreviewLayout.nodeGutter
                + ShelfPreviewLayout.dateGap + ShelfPreviewLayout.dateWidth
            #expect(ShelfPreviewLayout(available: boundary, cardWidth: width).sideDate)
            #expect(ShelfPreviewLayout(available: boundary, cardWidth: width).columns == 2)
            #expect(!ShelfPreviewLayout(available: boundary - 1, cardWidth: width).sideDate)
            #expect(ShelfPreviewLayout(available: width + 20, cardWidth: width).columns == 1)
        }
    }

}

@Suite("Home arrival dates")
struct HomeArrivalDayTests {
    @Test func threeLatestVisibleDaysHaveIndependentLimitsAndKeepEditions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let counts = [1, 33, 7, 1, 5]
        var books: [LibraryBook] = []
        for (day, count) in counts.enumerated() {
            for edition in 0..<count {
                let id = Int64(day * 100 + edition)
                books.append(LibraryBook(databaseID: id, title: "Book", hash: String(id), filepath: "",
                                         versionGroupID: 4, isPrimaryVersion: edition == 0, isUserHidden: day == 0,
                                         createdAt: Int64(30 - day) * 86_400_000 + Int64(50 - edition)))
            }
        }
        let days = HomeArrivalDay.latest(from: books.sorted(by: HomeArrivalDay.newer), calendar: calendar)
        #expect(days.map { $0.bookIDs.count } == [7, 7, 1])
        #expect(days.map(\.hasMore) == [true, false, false])
        #expect(days.first?.bookIDs == (100...106).map(String.init))
        #expect(HomeArrivalDay.latest(from: [], calendar: calendar).isEmpty)
    }
}
