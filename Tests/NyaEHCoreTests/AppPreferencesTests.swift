import AppKit
import Observation
import SwiftUI
import Testing
@testable import NyaEHCore

private func portraitFixture(width: Int, height: Int, opaqueRect: CGRect) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    ))
    for y in 0..<height {
        for x in 0..<width {
            let alpha: CGFloat = opaqueRect.contains(CGPoint(x: x, y: y)) ? 1 : 0
            bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: alpha), atX: x, y: y)
        }
    }
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

private final class ObservationChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func markChanged() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("App preferences and localization")
struct AppPreferencesTests {
    @Test("theme modes map to color schemes")
    func themeModesMapToColorSchemes() {
        #expect(ThemeMode.system.colorScheme == nil)
        #expect(ThemeMode.light.colorScheme == .light)
        #expect(ThemeMode.dark.colorScheme == .dark)
    }

    @Test("system language resolves supported languages")
    func systemLanguageResolvesSupportedLanguages() {
        #expect(AppLanguage.resolveSystemLanguage(preferredLanguages: ["zh-Hans-US"]) == .zhHans)
        #expect(AppLanguage.resolveSystemLanguage(preferredLanguages: ["zh-Hant-TW"]) == .zhHant)
        #expect(AppLanguage.resolveSystemLanguage(preferredLanguages: ["ja-JP"]) == .ja)
        #expect(AppLanguage.resolveSystemLanguage(preferredLanguages: ["ko-KR"]) == .ko)
        #expect(AppLanguage.resolveSystemLanguage(preferredLanguages: ["en-US"]) == .en)
        #expect(AppLanguage.resolveSystemLanguage(preferredLanguages: ["fr-FR"]) == .en)
    }

    @Test("all localization keys are translated for concrete languages")
    func allLocalizationKeysAreTranslated() {
        for language in AppLanguage.concreteLanguages {
            for key in L10nKey.allCases {
                #expect(AppLocalizer.hasTranslation(for: key, language: language))
            }
        }
    }

    @Test("built in command shortcuts have unique key combinations")
    func builtInCommandShortcutsHaveUniqueKeyCombinations() {
        let shortcuts = AppShortcutPreset.builtIn
        let signatures = shortcuts.compactMap(\.signature)

        #expect(shortcuts.count == AppCommandID.allCases.count)
        #expect(Set(signatures).count == signatures.count)
        #expect(AppShortcutPreset.shortcut(.goBack).signature == "escape|")
        #expect(AppShortcutPreset.shortcut(.increaseCardSize).signature == "+|command")
        #expect(AppShortcutPreset.shortcut(.decreaseCardSize).signature == "-|command")
        #expect(AppShortcutPreset.shortcut(.previousPage).signature == "leftArrow|command")
        #expect(AppShortcutPreset.shortcut(.nextPage).signature == "rightArrow|command")
        #expect(AppShortcutPreset.shortcut(.navigateImport).signature == nil)
    }

    @Test("built in command shortcut titles are localized")
    func builtInCommandShortcutTitlesAreLocalized() {
        for shortcut in AppShortcutPreset.builtIn {
            for language in AppLanguage.concreteLanguages {
                #expect(AppLocalizer.hasTranslation(for: shortcut.titleKey, language: language))
            }
        }
    }

    @Test("book status and library filter keys resolve")
    func modelTitleKeysResolve() {
        let localizer = AppLocalizer(language: .en)

        for mode in BookTitleDisplayMode.allCases {
            #expect(!localizer.string(mode.titleKey).isEmpty)
        }

        for status in BookStatus.allCases {
            #expect(!localizer.string(status.titleKey).isEmpty)
        }

        for filter in LibraryFilter.allCases {
            #expect(!localizer.string(filter.titleKey).isEmpty)
        }

        #expect(!LibraryFilter.childFilters.contains(.marked))
    }

    @Test("detail route path keeps work detail under book detail")
    func detailRoutePathKeepsWorkDetailUnderBookDetail() {
        let workPath = [LibraryRoute.workDetail(42)]
        let bookPath = LibraryNavigationPathReducer.pathAfterOpeningBook(
            "book-7",
            source: .workDetail,
            currentPath: workPath
        )

        #expect(bookPath == [.workDetail(42), .bookDetail("book-7")])
    }

    @Test("detail route path pops back to work detail")
    func detailRoutePathPopsBackToWorkDetail() {
        let path = [
            LibraryRoute.workDetail(42),
            LibraryRoute.bookDetail("book-7")
        ]

        #expect(LibraryNavigationPathReducer.pathAfterGoingBack(from: path) == [.workDetail(42)])
    }

    @Test("topic links retain at most the current and previous topic")
    func topicLinksKeepTwoPages() {
        let workA = LibraryRoute.workDetail(10)
        let character = LibraryRoute.characterDetail(20)
        let workB = LibraryRoute.workDetail(30)

        let first = LibraryNavigationPathReducer.pathAfterOpeningTopic(character, currentPath: [workA])
        #expect(first == [workA, character])
        #expect(LibraryNavigationPathReducer.pathAfterOpeningTopic(workA, currentPath: first) == [workA])

        let second = LibraryNavigationPathReducer.pathAfterOpeningTopic(workB, currentPath: first)
        #expect(second == [character, workB])
        #expect(LibraryRouteTransitionBackingResolver.backingRouteIDs(from: first, to: second) == [character.id])
        #expect(LibraryRouteMountDeferralPolicy.deferredRouteIDs(from: first, to: second) == [workB.id])
        #expect(LibraryNavigationPathReducer.pathAfterGoingBack(from: second) == [character])
        #expect(LibraryNavigationPathReducer.pathAfterGoingBack(from: [character]).isEmpty)
        #expect(LibraryNavigationPathReducer.pathAfterOpeningTopic(workB, currentPath: second) == second)

        let bookPath = LibraryNavigationPathReducer.pathAfterOpeningBook(
            "book-7", source: .workDetail, currentPath: second
        )
        #expect(bookPath == [character, workB, .bookDetail("book-7")])
        #expect(LibraryNavigationPathReducer.pathAfterGoingBack(from: bookPath) == second)
    }

    @Test("character background prefers its own asset, then the first eligible work asset")
    func characterBackgroundSelection() {
        let character = visualTag(id: 1, namespace: "character", name: "hero")
        let emptyWork = visualTag(id: 2, namespace: "parody", name: "empty")
        let original = visualTag(id: 3, namespace: "parody", name: "original", background: "original.jpg")
        let firstWork = visualTag(id: 4, namespace: "parody", name: "first", background: "first.jpg")
        let secondWork = visualTag(id: 5, namespace: "parody", name: "second", background: "second.jpg")
        let sections = [emptyWork, original, firstWork, secondWork].map {
            CharacterWorkBookSection(work: $0, books: [])
        }

        #expect(CharacterDetail(character: character, sections: sections).backgroundTag?.id == firstWork.id)
        #expect(CharacterDetail(character: visualTag(id: 1, namespace: "character", name: "hero", background: "own.jpg"), sections: sections).backgroundTag?.id == character.id)
        #expect(CharacterDetail(character: character, sections: [CharacterWorkBookSection(work: emptyWork, books: [])]).backgroundTag == nil)
    }

    private func visualTag(id: Int64, namespace: String, name: String, background: String? = nil) -> TagDisplaySummary {
        TagDisplaySummary(
            id: id,
            namespace: namespace,
            name: name,
            rawValue: "\(namespace):\(name)",
            displayName: name,
            count: 1,
            visualProfile: background.map { TagVisualProfile(tagID: id, backgroundAssetPath: $0) }
        )
    }

    @Test("detail route path stays stable for in-detail book replacement")
    func detailRoutePathStaysStableForInDetailBookReplacement() {
        let path = [
            LibraryRoute.workDetail(42),
            LibraryRoute.bookDetail("book-7")
        ]
        let replacedPath = LibraryNavigationPathReducer.pathAfterOpeningBook(
            "book-8",
            source: .bookDetail,
            currentPath: path
        )

        #expect(replacedPath == path)
    }

    @Test("nested route presentation keeps every route layer")
    func nestedRoutePresentationKeepsEveryRouteLayer() {
        let path = [
            LibraryRoute.workDetail(42),
            LibraryRoute.bookDetail("book-7")
        ]

        #expect(path.count == 2)
        #expect(LibraryRoutePresentation.isTopRoute(index: 0, pathCount: path.count) == false)
        #expect(LibraryRoutePresentation.isTopRoute(index: 1, pathCount: path.count))
    }

    @Test("route layer state distinguishes active backing and frozen")
    func routeLayerStateDistinguishesActiveBackingAndFrozen() {
        let path = [
            LibraryRoute.workDetail(42),
            LibraryRoute.bookDetail("book-7")
        ]

        #expect(
            LibraryRoutePresentation.layerState(
                routeID: path[1].id,
                index: 1,
                pathCount: path.count,
                transitionBackingRouteIDs: []
            ) == .active
        )
        #expect(
            LibraryRoutePresentation.layerState(
                routeID: path[0].id,
                index: 0,
                pathCount: path.count,
                transitionBackingRouteIDs: [path[0].id]
            ) == .transitionBacking
        )
        #expect(
            LibraryRoutePresentation.layerState(
                routeID: path[0].id,
                index: 0,
                pathCount: path.count,
                transitionBackingRouteIDs: []
            ) == .frozen
        )
    }

    @Test("only active route layer accepts hit testing")
    func onlyActiveRouteLayerAcceptsHitTesting() {
        #expect(LibraryRoutePresentation.allowsHitTesting(layerState: .active))
        #expect(!LibraryRoutePresentation.allowsHitTesting(layerState: .transitionBacking))
        #expect(!LibraryRoutePresentation.allowsHitTesting(layerState: .frozen))
    }

    @Test("frozen route layer uses placeholder content")
    func frozenRouteLayerUsesPlaceholderContent() {
        #expect(LibraryRoutePresentation.contentWeight(for: .active) == .full)
        #expect(LibraryRoutePresentation.contentWeight(for: .transitionBacking) == .full)
        #expect(LibraryRoutePresentation.contentWeight(for: .frozen) == .frozenPlaceholder)
    }

    @Test("route presentation uses non identity transitions")
    func routePresentationUsesNonIdentityTransitions() {
        #expect(LibraryRoutePresentation.transitionStyle(for: .workDetail(42)) == .trailingMoveOpacity)
        #expect(LibraryRoutePresentation.transitionStyle(for: .collectionDetail("collection-7")) == .trailingMoveOpacity)
        #expect(LibraryRoutePresentation.transitionStyle(for: .bookDetail("book-7")) == .trailingMoveOpacity)
    }

    @Test("route transition backing resolver marks push and pop backing routes")
    func routeTransitionBackingResolverMarksPushAndPopBackingRoutes() {
        let workRoute = LibraryRoute.workDetail(42)
        let bookRoute = LibraryRoute.bookDetail("book-7")

        #expect(
            LibraryRouteTransitionBackingResolver.backingRouteIDs(
                from: [workRoute],
                to: [workRoute, bookRoute]
            ) == [workRoute.id]
        )
        #expect(
            LibraryRouteTransitionBackingResolver.backingRouteIDs(
                from: [workRoute, bookRoute],
                to: [workRoute]
            ) == [workRoute.id]
        )
        #expect(
            LibraryRouteTransitionBackingResolver.backingRouteIDs(
                from: [workRoute, bookRoute],
                to: [workRoute, bookRoute]
            ).isEmpty
        )
    }

    @Test("route transition backing activation disables animation")
    func routeTransitionBackingActivationDisablesAnimation() {
        let workRoute = LibraryRoute.workDetail(42)
        let bookRoute = LibraryRoute.bookDetail("book-7")
        let backingIDs = LibraryRouteTransitionBackingResolver.backingRouteIDs(
            from: [workRoute, bookRoute],
            to: [workRoute]
        )

        #expect(backingIDs == [workRoute.id])
        #expect(
            LibraryRoutePresentation.layerState(
                routeID: workRoute.id,
                index: 0,
                pathCount: 1,
                transitionBackingRouteIDs: backingIDs
            ) == .active
        )
        #expect(LibraryRouteTransitionBackingResolver.activationAnimationPolicy == .disabledAnimation)
    }

    @Test("frozen work and collection routes use placeholder only policy")
    func frozenWorkAndCollectionRoutesUsePlaceholderOnlyPolicy() {
        #expect(LibraryRoutePresentation.frozenContentPolicy(for: .workDetail(42)) == .placeholderOnly)
        #expect(LibraryRoutePresentation.frozenContentPolicy(for: .collectionDetail("collection-7")) == .placeholderOnly)
        #expect(LibraryRoutePresentation.frozenContentPolicy(for: .bookDetail("book-7")) == .placeholderOnly)
    }

    @Test("work detail scroll restoration preserves frozen route offsets")
    func workDetailScrollRestorationPreservesFrozenRouteOffsets() {
        #expect(WorkDetailScrollRestorationPolicy.shouldPreserveScrollOffset(for: .routeFrozenThenRestored))
        #expect(WorkDetailScrollRestorationPolicy.shouldPreserveScrollOffset(for: .bookDetailReplacement))
        #expect(!WorkDetailScrollRestorationPolicy.shouldPreserveScrollOffset(for: .baseDestinationChanged))
        #expect(WorkDetailScrollRestorationPolicy.restorationAnimationPolicy == .disabledAnimation)
    }

    @Test("work detail scroll cache clears on base selection")
    func workDetailScrollCacheClearsOnBaseSelection() {
        let cache = ["work.42": CGFloat(320)]

        #expect(WorkDetailRouteScrollCachePolicy.cacheAfterBaseDestinationChange(cache).isEmpty)
    }

    @Test("work detail route scroll store mutates outside observation")
    func workDetailRouteScrollStoreMutatesOutsideObservation() {
        let store = WorkDetailRouteScrollOffsetStore()
        let route = LibraryRoute.workDetail(42)

        store.setOffset(480, for: route.id)
        #expect(store.offset(for: route.id) == 480)

        store.clearAfterBaseDestinationChange()
        #expect(store.offset(for: route.id) == nil)
    }

    @Test("work detail scroll cache survives book detail return and replacement")
    func workDetailScrollCacheSurvivesBookDetailReturnAndReplacement() {
        let workRoute = LibraryRoute.workDetail(42)
        let bookRoute = LibraryRoute.bookDetail("book-7")
        let cache = [workRoute.id: CGFloat(320)]

        let afterBack = WorkDetailRouteScrollCachePolicy.cacheAfterPathChange(
            cache,
            oldPath: [workRoute, bookRoute],
            newPath: [workRoute]
        )
        let afterReplacement = WorkDetailRouteScrollCachePolicy.cacheAfterPathChange(
            cache,
            oldPath: [workRoute, bookRoute],
            newPath: [workRoute, bookRoute]
        )

        #expect(afterBack[workRoute.id] == 320)
        #expect(afterReplacement[workRoute.id] == 320)
    }

    @Test("work detail scroll cache removes popped work routes")
    func workDetailScrollCacheRemovesPoppedWorkRoutes() {
        let workRoute = LibraryRoute.workDetail(42)
        let cache = [workRoute.id: CGFloat(320)]
        let cleared = WorkDetailRouteScrollCachePolicy.cacheAfterPathChange(
            cache,
            oldPath: [workRoute],
            newPath: []
        )

        #expect(cleared.isEmpty)
    }

    @Test("work detail scroll restoration clamps offsets")
    func workDetailScrollRestorationClampsOffsets() {
        #expect(WorkDetailScrollRestorationPolicy.clampedOffset(-20, documentHeight: 1000, viewportHeight: 300) == 0)
        #expect(WorkDetailScrollRestorationPolicy.clampedOffset(450, documentHeight: 1000, viewportHeight: 300) == 450)
        #expect(WorkDetailScrollRestorationPolicy.clampedOffset(900, documentHeight: 1000, viewportHeight: 300) == 700)
        #expect(WorkDetailScrollRestorationPolicy.clampedOffset(20, documentHeight: 200, viewportHeight: 300) == 0)
    }

    @Test("work detail viewport policy renders visible and prefetched sections")
    func workDetailViewportPolicyRendersVisibleAndPrefetchedSections() {
        #expect(WorkDetailSectionViewportPolicy.contentWeight(for: 0, visibleRange: nil, totalCount: 8) == .full)
        #expect(WorkDetailSectionViewportPolicy.contentWeight(for: 2, visibleRange: nil, totalCount: 8) == .full)
        #expect(WorkDetailSectionViewportPolicy.contentWeight(for: 3, visibleRange: nil, totalCount: 8) == .placeholder)

        #expect(WorkDetailSectionViewportPolicy.contentWeight(for: 1, visibleRange: 2...3, totalCount: 8) == .full)
        #expect(WorkDetailSectionViewportPolicy.contentWeight(for: 4, visibleRange: 2...3, totalCount: 8) == .full)
        #expect(WorkDetailSectionViewportPolicy.contentWeight(for: 5, visibleRange: 2...3, totalCount: 8) == .placeholder)
    }

    @Test("work detail viewport policy resolves visible range")
    func workDetailViewportPolicyResolvesVisibleRange() {
        #expect(
            WorkDetailSectionViewportPolicy.visibleRange(afterVisibilityChange: [5, 2, 3], totalCount: 10) == 2...5
        )
        #expect(
            WorkDetailSectionViewportPolicy.visibleRange(afterVisibilityChange: [9, 12], totalCount: 10) == 9...9
        )
        #expect(
            WorkDetailSectionViewportPolicy.visibleRange(afterVisibilityChange: [], totalCount: 10) == nil
        )
    }

    @Test("library route mount defers top shell routes")
    func libraryRouteMountDefersTopShellRoutes() {
        let workRoute = LibraryRoute.workDetail(42)
        let bookRoute = LibraryRoute.bookDetail("book-7")
        let replacementBookRoute = LibraryRoute.bookDetail("book-8")
        let collectionRoute = LibraryRoute.collectionDetail("collection-3")

        #expect(
            LibraryRouteMountDeferralPolicy.deferredRouteIDs(from: [], to: [workRoute]) == [workRoute.id]
        )
        #expect(
            LibraryRouteMountDeferralPolicy.deferredRouteIDs(from: [workRoute], to: [workRoute, bookRoute]) == [bookRoute.id]
        )
        #expect(
            LibraryRouteMountDeferralPolicy.deferredRouteIDs(from: [workRoute, bookRoute], to: [workRoute]) == [workRoute.id]
        )
        #expect(
            LibraryRouteMountDeferralPolicy.deferredRouteIDs(from: [bookRoute], to: [replacementBookRoute]).isEmpty
        )
        #expect(
            LibraryRouteMountDeferralPolicy.deferredRouteIDs(from: [], to: [collectionRoute]).isEmpty
        )
        #expect(
            LibraryRouteMountDeferralPolicy.content(for: workRoute, deferredRouteIDs: [workRoute.id]) == .transitionShell
        )
        #expect(
            LibraryRouteMountDeferralPolicy.content(for: bookRoute, deferredRouteIDs: [bookRoute.id]) == .transitionShell
        )
        #expect(
            LibraryRouteMountDeferralPolicy.content(for: collectionRoute, deferredRouteIDs: [collectionRoute.id]) == .full
        )
        #expect(
            LibraryRouteMountDeferralPolicy.content(for: workRoute, deferredRouteIDs: []) == .full
        )
        #expect(LibraryRouteMountDeferralPolicy.activationAnimationPolicy == .disabledAnimation)
        #expect(LibraryRouteMountDeferralPolicy.contentReplacementAnimationPolicy == .disabledAnimation)
        #expect(LibraryRouteMountDeferralPolicy.contentReplacementTransitionStyle == .identity)
    }

    @Test("book detail external shell suppresses only initial replacement motion")
    func bookDetailExternalShellSuppressesOnlyInitialReplacementMotion() {
        #expect(
            BookDetailExternalTransitionShellPolicy.shouldSuppressContentReplacementMotion(
                usesExternalTransitionShell: true,
                hasConsumedExternalTransitionShell: false
            )
        )
        #expect(
            !BookDetailExternalTransitionShellPolicy.shouldSuppressContentReplacementMotion(
                usesExternalTransitionShell: true,
                hasConsumedExternalTransitionShell: true
            )
        )
        #expect(
            !BookDetailExternalTransitionShellPolicy.shouldSuppressContentReplacementMotion(
                usesExternalTransitionShell: false,
                hasConsumedExternalTransitionShell: false
            )
        )
        #expect(BookDetailExternalTransitionShellPolicy.initialContentReplacementAnimationPolicy == .disabledAnimation)
        #expect(BookDetailExternalTransitionShellPolicy.initialContentReplacementTransitionStyle == .identity)
    }

    @Test("sidebar base selection clears detail route path")
    func sidebarBaseSelectionClearsDetailRoutePath() {
        #expect(LibraryDestination.importLibrary.id == "importLibrary")
        #expect(LibraryDestination.importLibrary.sidebarDestination == .importLibrary)
        #expect(LibraryDestination.developmentTools.id == "developmentTools")
        #expect(LibraryDestination.developmentTools.sidebarDestination == .developmentTools)
        #expect(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination().isEmpty)
    }

    @Test("original parody tags open search instead of work detail")
    func originalParodyTagsOpenSearchInsteadOfWorkDetail() {
        #expect(TagOpenDestinationResolver.destination(for: tag(namespace: "parody", name: "original")) == .search)
        #expect(TagOpenDestinationResolver.destination(for: tag(namespace: "parody", name: "origin")) == .search)
        #expect(TagOpenDestinationResolver.destination(for: tag(namespace: "parody", name: "love live")) == .workDetail)
        #expect(TagOpenDestinationResolver.destination(for: tag(namespace: "character", name: "original")) == .characterDetail)
        #expect(TagOpenDestinationResolver.destination(for: tag(namespace: "artist", name: "sample")) == .search)
    }

    @Test("book detail opens animate except in-detail replacement")
    func bookDetailOpensAnimateExceptInDetailReplacement() {
        #expect(BookOpenSource.workDetail.usesAnimatedBookDetailTransition)
        #expect(BookOpenSource.home.usesAnimatedBookDetailTransition)
        #expect(BookOpenSource.search.usesAnimatedBookDetailTransition)
        #expect(BookOpenSource.library.usesAnimatedBookDetailTransition)
        #expect(BookOpenSource.collectionDetail.usesAnimatedBookDetailTransition)
        #expect(BookOpenSource.characterDetail.usesAnimatedBookDetailTransition)
        #expect(BookOpenSource.management.usesAnimatedBookDetailTransition)
        #expect(!BookOpenSource.bookDetail.usesAnimatedBookDetailTransition)
    }

    private func tag(namespace: String, name: String) -> TagDisplaySummary {
        TagDisplaySummary(
            id: 1,
            namespace: namespace,
            name: name,
            rawValue: "\(namespace):\(name)",
            displayName: name,
            count: 1
        )
    }

    @Test("book detail scroll reset is limited to page disappearance")
    func bookDetailScrollResetIsLimitedToPageDisappearance() {
        #expect(!BookDetailScrollResetPolicy.shouldResetScrollState(for: .bookChanged))
        #expect(BookDetailScrollResetPolicy.shouldResetScrollState(for: .disappear))
    }

    @Test("book detail replacement keeps transient content stable")
    func bookDetailReplacementKeepsTransientContentStable() {
        #expect(!BookDetailReplacementPolicy.shouldClearDisplayTags(for: .bookChanged))
        #expect(BookDetailReplacementPolicy.shouldClearDisplayTags(for: .disappear))
        #expect(
            BookDetailReplacementPolicy.deferredSectionsBookIDAfterBookChange(
                mountedBookID: "book-1",
                nextBookID: "book-2"
            ) == "book-2"
        )
        #expect(
            BookDetailReplacementPolicy.deferredSectionsBookIDAfterBookChange(
                mountedBookID: nil,
                nextBookID: "book-2"
            ) == nil
        )
        #expect(BookDetailReplacementPolicy.shouldShowDeferredSections(mountedBookID: "book-2"))
        #expect(!BookDetailReplacementPolicy.shouldShowDeferredSections(mountedBookID: nil))
    }

    @Test("book detail replacement uses light content crossfade")
    func bookDetailReplacementUsesLightContentCrossfade() {
        #expect(BookDetailReplacementPolicy.mainContentTransitionStyle == .identity)
        #expect(BookDetailReplacementPolicy.contentCrossfadeDuration == BookDetailContentReplacementMotion.duration)
        #expect(BookDetailReplacementPolicy.contentCrossfadeDuration <= 0.18)
    }

    @Test("book detail background keeps stable color while target theme is unresolved")
    func bookDetailBackgroundKeepsStableColorWhileTargetThemeIsUnresolved() throws {
        let stableColor = try #require(NSColor.nyaehColor(hex: "#334455FF"))

        let displayColor = BookDetailThemeColorPolicy.displayColor(
            resolvedColor: nil,
            cachedColor: nil,
            currentStableColor: stableColor
        )

        #expect(displayColor.nyaehHexString == "#334455FF")
    }

    @Test("book detail background prefers target resolved or cached theme color")
    func bookDetailBackgroundPrefersTargetResolvedOrCachedThemeColor() throws {
        let stableColor = try #require(NSColor.nyaehColor(hex: "#334455FF"))
        let cachedColor = try #require(NSColor.nyaehColor(hex: "#667788FF"))
        let resolvedColor = try #require(NSColor.nyaehColor(hex: "#99AABBFF"))

        let cachedDisplayColor = BookDetailThemeColorPolicy.displayColor(
            resolvedColor: nil,
            cachedColor: cachedColor,
            currentStableColor: stableColor
        )
        let resolvedDisplayColor = BookDetailThemeColorPolicy.displayColor(
            resolvedColor: resolvedColor,
            cachedColor: cachedColor,
            currentStableColor: stableColor
        )

        #expect(cachedDisplayColor.nyaehHexString == "#667788FF")
        #expect(resolvedDisplayColor.nyaehHexString == "#99AABBFF")
    }

    @Test("book detail background uses neutral fallback without stable color")
    func bookDetailBackgroundUsesNeutralFallbackWithoutStableColor() {
        let displayColor = BookDetailThemeColorPolicy.displayColor(
            resolvedColor: nil,
            cachedColor: nil,
            currentStableColor: nil
        )

        #expect(displayColor.nyaehHexString == "#8AA3ADFF")
        #expect(displayColor.nyaehHexString != NSColor.systemYellow.nyaehHexString)
        #expect(displayColor.nyaehHexString != CoverThemeColorExtractor.fallbackColor.nyaehHexString)
    }

    @Test("book detail route identity changes for different books")
    func bookDetailRouteIdentityChangesForDifferentBooks() {
        let first = LibraryRoute.bookDetail("book-1")
        let second = LibraryRoute.bookDetail("book-2")

        #expect(first.id != second.id)
        #expect(first.id == "book.book-1")
        #expect(second.id == "book.book-2")
    }

    @Test("tag visual pasteboard drop bridge ignores ordinary mouse events")
    func tagVisualPasteboardDropBridgeIgnoresOrdinaryMouseEvents() {
        #expect(!TagVisualPasteboardDropHitPolicy.acceptsHit(for: .leftMouseDown))
        #expect(!TagVisualPasteboardDropHitPolicy.acceptsHit(for: .leftMouseUp))
        #expect(!TagVisualPasteboardDropHitPolicy.acceptsHit(for: .rightMouseDown))
        #expect(!TagVisualPasteboardDropHitPolicy.acceptsHit(for: .mouseMoved))
        #expect(!TagVisualPasteboardDropHitPolicy.acceptsHit(for: .scrollWheel))

        #expect(TagVisualPasteboardDropHitPolicy.acceptsHit(for: nil))
        #expect(TagVisualPasteboardDropHitPolicy.acceptsHit(for: .leftMouseDragged))
        #expect(TagVisualPasteboardDropHitPolicy.acceptsHit(for: .rightMouseDragged))
        #expect(TagVisualPasteboardDropHitPolicy.acceptsHit(for: .otherMouseDragged))
        #expect(TagVisualPasteboardDropHitPolicy.acceptsHit(for: .appKitDefined))
    }

    @Test("tag visual pasteboard drop bridge can opt into strict drop hit testing")
    func tagVisualPasteboardDropBridgeCanOptIntoStrictDropHitTesting() {
        #expect(!TagVisualPasteboardDropHitPolicy.acceptsHit(for: .leftMouseDown))
        #expect(TagVisualPasteboardDropHitPolicy.acceptsHit(for: .leftMouseDown, capturesAllHitTests: true))
        #expect(TagVisualPasteboardDropHitPolicy.acceptsHit(for: .rightMouseDown, capturesAllHitTests: true))
        #expect(TagVisualPasteboardDropHitPolicy.acceptsHit(for: nil, capturesAllHitTests: true))
    }

    @Test("book detail session token rejects stale revisions")
    func bookDetailSessionTokenRejectsStaleRevisions() {
        let first = BookDetailSessionToken.inactive.next(bookID: "book-1")
        let second = first.next(bookID: "book-2")
        let inactive = second.nextInactive()

        #expect(first.matches(bookID: "book-1"))
        #expect(!first.matches(bookID: "book-2"))
        #expect(first != second)
        #expect(!inactive.matches(bookID: "book-2"))
        #expect(inactive.revision == second.revision + 1)
    }

    @Test("book detail scroll metrics detect slow frames")
    func bookDetailScrollMetricsDetectSlowFrames() {
        #expect(!BookDetailScrollFrameMetrics.isSlowFrame(intervalMilliseconds: 32.9))
        #expect(BookDetailScrollFrameMetrics.isSlowFrame(intervalMilliseconds: 33.0))
        #expect(!BookDetailScrollFrameMetrics.isSlowHeroLayout(milliseconds: 7.9))
        #expect(BookDetailScrollFrameMetrics.isSlowHeroLayout(milliseconds: 8.0))
    }

    @Test("book detail scroll metrics accumulate summary")
    func bookDetailScrollMetricsAccumulateSummary() {
        var state = BookDetailScrollFrameMetrics.State()

        #expect(state.record(offset: 10, timestampMilliseconds: 100, heroPhase: .expanded) == .started)
        #expect(state.record(offset: 10.5, timestampMilliseconds: 108, heroPhase: .expanded) == .ignored)
        let normalResult = state.record(offset: 18, timestampMilliseconds: 116, heroPhase: .collapsing)
        let slowResult = state.record(offset: 64, timestampMilliseconds: 150, heroPhase: .collapsing)

        guard case .frame(let normalFrame) = normalResult else {
            Issue.record("Expected normal frame")
            return
        }
        guard case .frame(let slowFrame) = slowResult else {
            Issue.record("Expected slow frame")
            return
        }

        #expect(normalFrame.isSlow == false)
        #expect(normalFrame.intervalMilliseconds == 8)
        #expect(normalFrame.offsetDelta == 8)
        #expect(normalFrame.heroPhase == .collapsing)
        #expect(slowFrame.isSlow == true)
        #expect(slowFrame.intervalMilliseconds == 34)
        #expect(slowFrame.offsetDelta == 46)
        #expect(slowFrame.heroPhase == .collapsing)
        #expect(state.frameCount == 2)
        #expect(state.slowFrameCount == 1)
        #expect(state.maxIntervalMilliseconds == 34)
        #expect(state.maxOffsetDelta == 46)

        state.reset()
        #expect(!state.hasFrames)
        #expect(state.frameCount == 0)
        #expect(state.slowFrameCount == 0)
    }

    @Test("book detail scroll metrics ignore tiny offset deltas")
    func bookDetailScrollMetricsIgnoreTinyOffsetDeltas() {
        var state = BookDetailScrollFrameMetrics.State()

        #expect(state.record(offset: 100, timestampMilliseconds: 0, heroPhase: .collapsing) == .started)
        #expect(state.record(offset: 100.4, timestampMilliseconds: 40, heroPhase: .collapsing) == .ignored)
        #expect(state.record(offset: 100.9, timestampMilliseconds: 80, heroPhase: .collapsing) == .ignored)
        #expect(state.frameCount == 0)
        #expect(!state.hasFrames)

        let result = state.record(offset: 102, timestampMilliseconds: 96, heroPhase: .collapsing)
        guard case .frame(let frame) = result else {
            Issue.record("Expected tracked frame")
            return
        }
        #expect(frame.intervalMilliseconds == 16)
        #expect(frame.offsetDelta == 2)
        #expect(state.frameCount == 1)
    }

    @Test("book detail scroll offset coalescer publishes latest pending offset")
    func bookDetailScrollOffsetCoalescerPublishesLatestPendingOffset() {
        var state = BookDetailScrollOffsetCoalescer.State()

        #expect(BookDetailScrollOffsetCoalescer.record(offset: 10, state: &state) == .schedule)
        #expect(BookDetailScrollOffsetCoalescer.record(offset: 12, state: &state) == .updatePendingOnly)
        #expect(BookDetailScrollOffsetCoalescer.record(offset: 18, state: &state) == .updatePendingOnly)
        #expect(BookDetailScrollOffsetCoalescer.flush(state: &state) == 18)
        #expect(state.pendingOffset == nil)
        #expect(!state.isPublishScheduled)
    }

    @Test("book detail scroll offset coalescer resets pending offset")
    func bookDetailScrollOffsetCoalescerResetsPendingOffset() {
        var state = BookDetailScrollOffsetCoalescer.State()

        _ = BookDetailScrollOffsetCoalescer.record(offset: 10, state: &state)
        BookDetailScrollOffsetCoalescer.reset(state: &state)

        #expect(state.pendingOffset == nil)
        #expect(!state.isPublishScheduled)
    }

    @Test("book reader lifecycle rejects cancelled and stale loads")
    func bookReaderLifecycleRejectsCancelledAndStaleLoads() {
        var state = BookReaderLoadLifecycleState()

        let didStartFirst = state.start(bookID: "book-1")
        let didStartDuplicate = state.start(bookID: "book-1")

        #expect(didStartFirst)
        #expect(!didStartDuplicate)
        #expect(state.acceptsResult(bookID: "book-1", isCancelled: false))
        #expect(!state.acceptsResult(bookID: "book-2", isCancelled: false))
        #expect(!state.acceptsResult(bookID: "book-1", isCancelled: true))

        state.finish(bookID: "book-2")
        #expect(state.isLoading)
        state.finish(bookID: "book-1")
        #expect(!state.isLoading)

        let didStartSecond = state.start(bookID: "book-2")
        #expect(didStartSecond)
        state.reset()
        #expect(!state.isLoading)
        #expect(!state.acceptsResult(bookID: "book-2", isCancelled: false))
    }

    @Test("work character shelf visual state keeps foreground static")
    func workCharacterShelfVisualStateKeepsForegroundStatic() {
        let visualState = WorkCharacterShelfVisualState.resolve(hasForegroundAsset: true)

        #expect(!visualState.showsPlaceholder)
        #expect(visualState.characterShadowOpacity > 0)
        #expect(visualState.characterShadowRadius > 0)
        #expect(visualState.characterShadowYOffset > 0)
    }

    @Test("work character shelf split layout keeps character and content columns stable")
    func workCharacterShelfSplitLayoutKeeepsCharacterAndContentColumnsStable() {
        let layout = WorkCharacterShelfSplitMetrics.resolve(containerSize: CGSize(width: 1_200, height: 520))

        #expect(layout.characterColumnWidth >= WorkCharacterShelfSplitLayout.minCharacterColumnWidth)
        #expect(layout.characterColumnWidth <= WorkCharacterShelfSplitLayout.maxCharacterColumnWidth)
        #expect(layout.contentColumnWidth >= WorkCharacterShelfSplitLayout.minimumContentWidth)
        #expect(WorkCharacterShelfSplitLayout.keepsContentOutsideCharacterColumn(
            characterColumnWidth: layout.characterColumnWidth,
            contentColumnWidth: layout.contentColumnWidth,
            containerWidth: 1_200
        ))
    }

    @Test("work character shelf split layout keeps badge insets compact and stable")
    func workCharacterShelfSplitLayoutKeepsBadgeInsetsCompactAndStable() {
        let layout = WorkCharacterShelfSplitMetrics.resolve(containerSize: CGSize(width: 1_200, height: 520))

        #expect(layout.capsuleInsets.leading > 0)
        #expect(layout.capsuleInsets.bottom > 0)
        #expect(layout.capsuleInsets.leading <= 18)
        #expect(layout.capsuleInsets.bottom <= 16)
    }

    @Test("work character shelf viewport mask stays light and nonnegative")
    func workCharacterShelfViewportMaskStaysLightAndNonnegative() {
        let layout = WorkCharacterShelfSplitMetrics.resolve(containerSize: CGSize(width: 1_200, height: 520))
        let wide = WorkCharacterShelfViewportMaskMetrics.resolve(
            size: CGSize(width: layout.contentColumnWidth, height: 260),
            preferredFadeWidth: layout.viewportFadeWidth
        )
        let narrowLayout = WorkCharacterShelfSplitMetrics.resolve(containerSize: CGSize(width: 420, height: 520))
        let narrow = WorkCharacterShelfViewportMaskMetrics.resolve(
            size: CGSize(width: narrowLayout.contentColumnWidth, height: 260),
            preferredFadeWidth: narrowLayout.viewportFadeWidth
        )
        let empty = WorkCharacterShelfViewportMaskMetrics.resolve(
            size: .zero,
            preferredFadeWidth: 0
        )

        #expect(wide.leftFadeWidth == wide.rightFadeWidth)
        #expect(wide.leftFadeWidth <= wide.size.width * 0.12)
        #expect(wide.opaqueWidth >= 0)
        #expect(narrow.leftFadeWidth <= narrow.size.width * 0.12)
        #expect(narrow.opaqueWidth >= 0)
        #expect(empty.leftFadeWidth == 0)
        #expect(empty.opaqueWidth == 0)
    }

    @Test("work character shelf badge width stays content-sized")
    func workCharacterShelfBadgeWidthStaysContentSized() {
        let layout = WorkCharacterShelfSplitMetrics.resolve(containerSize: CGSize(width: 1_200, height: 520))
        let maxBadgeWidth = layout.characterColumnWidth - layout.capsuleInsets.leading - layout.capsuleInsets.trailing

        #expect(maxBadgeWidth < layout.characterColumnWidth)
        #expect(maxBadgeWidth > 0)
    }

    @Test("book card metrics expose compact single line title height")
    func bookCardMetricsExposeCompactSingleLineTitleHeight() {
        let metrics = BookCardMetrics.default

        #expect(metrics.titleHeight == 22)
        #expect(metrics.infoRowHeight == 16)
        #expect(metrics.ratingHeight == 16)
        #expect(metrics.contentSpacing == 4)
    }

    @Test("book card fits a two-line title and three information rows")
    func bookCardTotalHeightIsDerivedFromCompactContent() {
        let metrics = BookCardMetrics.default
        let expectedHeight = metrics.coverHeight + metrics.bottomInset
            + metrics.regularTitleHeight
            + metrics.infoRowHeight + metrics.metadataHeight
            + metrics.ratingHeight
            + metrics.contentSpacing * 2 + metrics.infoSpacing * 2

        #expect(metrics.cardHeight == expectedHeight)
        #expect(metrics.cardWidth == 144)
        #expect(metrics.coverHeight == 180)
    }

    @Test("book cover thumbnail uses fit only for landscape images")
    func bookCoverThumbnailUsesFitOnlyForLandscapeImages() {
        #expect(BookCoverThumbnailDisplayMode.resolve(imageSize: CGSize(width: 1_200, height: 800)) == .fit)
        #expect(BookCoverThumbnailDisplayMode.resolve(imageSize: CGSize(width: 800, height: 1_200)) == .fill)
        #expect(BookCoverThumbnailDisplayMode.resolve(imageSize: CGSize(width: 900, height: 900)) == .fill)
    }

    @Test("book cover thumbnail display mode falls back safely for invalid sizes")
    func bookCoverThumbnailDisplayModeFallsBackSafelyForInvalidSizes() {
        #expect(BookCoverThumbnailDisplayMode.resolve(imageSize: .zero) == .fill)
        #expect(BookCoverThumbnailDisplayMode.resolve(imageSize: CGSize(width: -1, height: 800)) == .fill)
        #expect(BookCoverThumbnailDisplayMode.resolve(imageSize: CGSize(width: 1_200, height: -1)) == .fill)
    }

    @Test("book cover thumbnail load identity includes pixel bucket")
    func bookCoverThumbnailLoadIdentityIncludesPixelBucket() {
        let small = BookCoverThumbnailLoadRequest(coverPath: "/covers/example.jpg", pixelBucket: 128)
        let large = BookCoverThumbnailLoadRequest(coverPath: "/covers/example.jpg", pixelBucket: 512)

        #expect(small != large)
    }

    @Test("book cover thumbnail reuses images only for matching paths and sufficient buckets")
    func bookCoverThumbnailReusesImagesOnlyForMatchingPathsAndSufficientBuckets() {
        let small = BookCoverThumbnailLoadRequest(coverPath: "/covers/example.jpg", pixelBucket: 128)
        let large = BookCoverThumbnailLoadRequest(coverPath: "/covers/example.jpg", pixelBucket: 512)

        #expect(BookCoverThumbnailImagePolicy.satisfies(
            loadedPath: "/covers/example.jpg",
            loadedPixelBucket: 512,
            request: small
        ))
        #expect(!BookCoverThumbnailImagePolicy.satisfies(
            loadedPath: "/covers/example.jpg",
            loadedPixelBucket: 128,
            request: large
        ))
        #expect(!BookCoverThumbnailImagePolicy.satisfies(
            loadedPath: "/covers/other.jpg",
            loadedPixelBucket: 512,
            request: large
        ))
    }

    @Test("book cover thumbnail keeps a matching lower bucket visible while upgrading")
    func bookCoverThumbnailKeepsMatchingLowerBucketVisibleWhileUpgrading() {
        let request = BookCoverThumbnailLoadRequest(coverPath: "/covers/example.jpg", pixelBucket: 512)

        #expect(BookCoverThumbnailImagePolicy.canDisplay(
            loadedPath: "/covers/example.jpg",
            for: request
        ))
        #expect(!BookCoverThumbnailImagePolicy.canDisplay(
            loadedPath: "/covers/other.jpg",
            for: request
        ))
    }

    @Test("book cover thumbnail rejects a late lower resolution response")
    func bookCoverThumbnailRejectsLateLowerResolutionResponse() {
        #expect(!BookCoverThumbnailImagePolicy.shouldAcceptResponse(
            path: "/covers/example.jpg",
            pixelBucket: 128,
            currentPath: "/covers/example.jpg",
            currentPixelBucket: 512
        ))
        #expect(BookCoverThumbnailImagePolicy.shouldAcceptResponse(
            path: "/covers/example.jpg",
            pixelBucket: 512,
            currentPath: "/covers/example.jpg",
            currentPixelBucket: 128
        ))
    }

    @Test("book card title scroll metrics start only for overflowing hover")
    func bookCardTitleScrollMetricsStartOnlyForOverflowingHover() {
        #expect(!BookCardTitleScrollMetrics.canStart(isHovering: false, titleWidth: 180, cardWidth: 120, reduceMotion: false))
        #expect(!BookCardTitleScrollMetrics.canStart(isHovering: true, titleWidth: 120.5, cardWidth: 120, reduceMotion: false))
        #expect(!BookCardTitleScrollMetrics.canStart(isHovering: true, titleWidth: 180, cardWidth: 120, reduceMotion: true))
        #expect(BookCardTitleScrollMetrics.canStart(isHovering: true, titleWidth: 180, cardWidth: 120, reduceMotion: false))
        #expect(BookCardTitleScrollMetrics.duration(forOverflow: 10) == BookCardTitleScrollMetrics.minimumDuration)
        #expect(BookCardTitleScrollMetrics.duration(forOverflow: 90) == 5)
    }

    @Test("work detail shelf carousel fits one card row")
    func workDetailShelfCarouselFitsOneCardRow() {
        let metrics = WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: false)
        #expect(metrics.cardWidth == 168)
        let height = WorkCharacterShelfMetrics.carouselHeight(metrics: metrics, usesDoubleRow: false)

        #expect(height >= metrics.cardHeight + WorkCharacterShelfMetrics.verticalCardPadding)
    }

    @Test("work detail shelf carousel fits double card rows")
    func workDetailShelfCarouselFitsDoubleCardRows() {
        let metrics = WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: true)
        #expect(metrics.cardWidth == 136)
        let height = WorkCharacterShelfMetrics.carouselHeight(metrics: metrics, usesDoubleRow: true)
        let expectedMinimum = metrics.cardHeight * 2
            + WorkCharacterShelfMetrics.doubleRowSpacing
            + WorkCharacterShelfMetrics.verticalCardPadding

        #expect(height >= expectedMinimum)
    }

    @Test("work detail render phase shows loading shell before uncached content")
    func workDetailRenderPhaseShowsLoadingShellBeforeUncachedContent() {
        #expect(WorkDetailRenderPhase.resolve(hasDetail: false, isLoading: false, hasRequestedLoad: false, hasError: false) == .loadingShell)
        #expect(WorkDetailRenderPhase.resolve(hasDetail: false, isLoading: true, hasRequestedLoad: true, hasError: false) == .loadingShell)
        #expect(WorkDetailRenderPhase.resolve(hasDetail: true, isLoading: true, hasRequestedLoad: true, hasError: false) == .content)
        #expect(WorkDetailRenderPhase.resolve(hasDetail: false, isLoading: false, hasRequestedLoad: true, hasError: true) == .error)
        #expect(WorkDetailRenderPhase.resolve(hasDetail: false, isLoading: false, hasRequestedLoad: true, hasError: false) == .unavailable)
    }

    @Test("work detail section render budget unlocks progressively")
    func workDetailSectionRenderBudgetUnlocksProgressively() {
        var budget = WorkDetailSectionRenderBudget()

        #expect(!budget.isUnlocked(index: 0))
        let initial = budget.unlockInitial(totalCount: 12)
        #expect(initial.didUnlock)
        #expect(budget.unlockedCount == WorkDetailSectionRenderBudget.initialUnlockedCount)
        #expect(budget.isUnlocked(index: 2))
        #expect(!budget.isUnlocked(index: 3))

        let viewport = budget.unlockThroughVisibleIndex(5, totalCount: 12)
        #expect(viewport.didUnlock)
        #expect(budget.unlockedCount == 8)

        let clamped = budget.unlockThroughVisibleIndex(11, totalCount: 12)
        #expect(clamped.didUnlock)
        #expect(budget.unlockedCount == 12)

        budget.reset()
        #expect(budget.unlockedCount == 0)
    }

    @Test("work character shelf layout handles single and double row ranges")
    func workCharacterShelfLayoutHandlesSingleAndDoubleRowRanges() {
        #expect(!WorkCharacterShelfLayout.usesDoubleRow(bookCount: 6, threshold: 6))
        #expect(WorkCharacterShelfLayout.usesDoubleRow(bookCount: 7, threshold: 6))
        #expect(WorkCharacterShelfLayout.columnCount(bookCount: 0, usesDoubleRow: false) == 0)
        #expect(WorkCharacterShelfLayout.columnCount(bookCount: 5, usesDoubleRow: false) == 5)
        #expect(WorkCharacterShelfLayout.columnCount(bookCount: 7, usesDoubleRow: true) == 4)
        #expect(WorkCharacterShelfLayout.bookRange(forColumn: 2, bookCount: 7, usesDoubleRow: true) == 4..<6)
        #expect(WorkCharacterShelfLayout.bookRange(forColumn: 3, bookCount: 7, usesDoubleRow: true) == 6..<7)
        #expect(WorkCharacterShelfLayout.bookRange(forColumn: 4, bookCount: 7, usesDoubleRow: false) == 4..<5)
    }

    @Test("work hero background keeps image on right side")
    func workHeroBackgroundKeepsImageOnRightSide() {
        let layout = WorkHeroBackgroundLayout.resolve(size: CGSize(width: 1440, height: 520))
        let textSafetyMaxX: CGFloat = 560

        #expect(layout.imageFrame.minX > textSafetyMaxX)
        #expect(layout.imageFrame.maxX <= 1440)
        #expect(layout.imageFrame.width >= 760)
        #expect(layout.textReadableOverlayWidth <= layout.imageFrame.minX + layout.edgeFadeWidth)
    }

    @Test("work hero background layout keeps stable nonnegative dimensions")
    func workHeroBackgroundLayoutKeepsStableNonnegativeDimensions() {
        for size in [
            CGSize(width: 640, height: 420),
            CGSize(width: 980, height: 520),
            CGSize(width: 1800, height: 560)
        ] {
            let layout = WorkHeroBackgroundLayout.resolve(size: size)

            #expect(layout.imageFrame.minX >= 0)
            #expect(layout.imageFrame.minY >= 0)
            #expect(layout.imageFrame.width >= 0)
            #expect(layout.imageFrame.height >= 0)
            #expect(layout.imageFrame.maxX <= size.width + 0.001)
            #expect(layout.edgeFadeWidth > 0)
            #expect(layout.textReadableOverlayWidth <= size.width)
        }
    }

    @Test("work hero visual drop routing maps left and right regions")
    func workHeroVisualDropRoutingMapsLeftAndRightRegions() {
        let size = CGSize(width: 1440, height: 520)
        let routing = WorkHeroVisualDropRouting.resolve(size: size)

        #expect(routing.kind(at: CGPoint(x: routing.foregroundFrame.midX, y: routing.foregroundFrame.midY)) == .foreground)
        #expect(routing.kind(at: CGPoint(x: routing.backgroundFrame.midX, y: routing.backgroundFrame.midY)) == .background)
        #expect(routing.kind(at: CGPoint(x: size.width * 0.52, y: size.height - 12)) == nil)
    }

    @Test("work hero visual drop routing keeps frames stable")
    func workHeroVisualDropRoutingKeepsFramesStable() {
        for size in [
            CGSize(width: 640, height: 420),
            CGSize(width: 980, height: 520),
            CGSize(width: 1800, height: 560)
        ] {
            let routing = WorkHeroVisualDropRouting.resolve(size: size)

            #expect(routing.foregroundFrame.minX >= 0)
            #expect(routing.foregroundFrame.minY >= 0)
            #expect(routing.foregroundFrame.width >= 0)
            #expect(routing.foregroundFrame.height >= 0)
            #expect(routing.foregroundFrame.maxX <= size.width + 0.001)
            #expect(routing.backgroundFrame.maxX <= size.width + 0.001)
            #expect(routing.foregroundFrame.maxX <= routing.backgroundFrame.minX + 0.001)
        }
    }

    @Test("work hero feather mask clamps fade width")
    func workHeroFeatherMaskClampsFadeWidth() {
        let small = WorkHeroFeatherMaskMetrics.resolve(size: CGSize(width: 220, height: 120), baseFadeWidth: 180)
        let wide = WorkHeroFeatherMaskMetrics.resolve(size: CGSize(width: 820, height: 420), baseFadeWidth: 110)

        #expect(small.fadeWidth <= 120 * 0.42)
        #expect(small.fadeWidth >= 24)
        #expect(wide.fadeWidth == 110)
    }

    @Test("work hero feather mask preserves center area")
    func workHeroFeatherMaskPreservesCenterArea() {
        let metrics = WorkHeroFeatherMaskMetrics.resolve(size: CGSize(width: 820, height: 420), baseFadeWidth: 110)

        #expect(metrics.centerRect.minX == metrics.fadeWidth)
        #expect(metrics.centerRect.minY == metrics.fadeWidth)
        #expect(metrics.centerRect.width > 0)
        #expect(metrics.centerRect.height > 0)
        #expect(metrics.centerRect.maxX < metrics.size.width)
        #expect(metrics.centerRect.maxY < metrics.size.height)
    }

    @Test("character detail hero keeps information centered with bottom breathing room")
    func characterDetailHeroKeepsInformationCenteredWithBottomBreathingRoom() {
        let metrics = CharacterDetailHeroLayoutMetrics.resolve(
            containerHeight: CharacterDetailHeroLayoutMetrics.minHeight,
            informationHeight: 300
        )

        #expect(metrics.informationTopInset == metrics.informationBottomInset)
        #expect(metrics.informationBottomInset > 0)
        #expect(CharacterDetailHeroLayoutMetrics.verticalPadding >= 40)
    }

    @Test("character detail hero keeps figure bottom aligned")
    func characterDetailHeroKeepsFigureBottomAligned() {
        let metrics = CharacterDetailHeroLayoutMetrics.resolve(informationHeight: 300)

        #expect(metrics.figureBottomInset == CharacterDetailHeroLayoutMetrics.verticalPadding)
        #expect(CharacterDetailHeroLayoutMetrics.figureHeight > metrics.contentHeight)
    }

    @Test("character hero gives tall portraits room and stacks at narrow widths")
    func characterHeroSupportsTallPortraitsAndNarrowWidths() {
        let layout = CharacterDetailHeroLayoutMetrics.self
        #expect(layout.figureHeight > layout.figureWidth)
        #expect(layout.narrowFigureHeight > layout.figureWidth)
        #expect(layout.minimumWideContentWidth >= layout.minimumInformationWidth + layout.columnSpacing + layout.figureWidth)
        #expect(layout.minHeight >= layout.figureHeight + layout.verticalPadding * 2 - 10)
        let longIntroduction = layout.resolve(informationHeight: 900)
        #expect(longIntroduction.informationTopInset == 0)
        #expect(longIntroduction.informationBottomInset == 0)
    }

    @Test("character portrait bounds keep thin figures and ignore near transparent pixels")
    func characterPortraitBoundsKeepThinFigures() {
        let width = 40
        let height = 80
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 4..<76 {
            for x in 17..<23 {
                pixels[(y * width + x) * 4 + 3] = 255
            }
        }
        pixels[3] = CharacterPortraitImageProcessor.alphaThreshold

        let visible = pixels.withUnsafeBufferPointer {
            CharacterPortraitImageProcessor.visibleBounds(
                pixels: $0, width: width, height: height,
                bytesPerRow: width * 4, samplesPerPixel: 4, alphaIndex: 3
            )
        }
        #expect(visible == CGRect(x: 17, y: 4, width: 6, height: 72))
        let padded = CharacterPortraitImageProcessor.paddedBounds(
            visible!, canvasWidth: width, canvasHeight: height
        )
        #expect(padded.minX < visible!.minX)
        #expect(padded.maxX > visible!.maxX)
        #expect(padded.width < CGFloat(width))
        #expect(padded.height <= CGFloat(height))
    }

    @Test("character portrait display trims a square canvas with transparent margins")
    func characterPortraitDisplayTrimsSquareCanvas() throws {
        let source = try portraitFixture(width: 80, height: 80, opaqueRect: CGRect(x: 36, y: 6, width: 8, height: 68))
        let result = try #require(CharacterPortraitImageProcessor.displayData(from: source))
        let bitmap = try #require(NSBitmapImageRep(data: result))
        #expect(bitmap.pixelsWide < 20)
        #expect(bitmap.pixelsHigh > 68)
        #expect(bitmap.pixelsHigh <= 80)

        let asymmetric = try portraitFixture(width: 80, height: 80, opaqueRect: CGRect(x: 36, y: 2, width: 8, height: 20))
        let asymmetricResult = try #require(CharacterPortraitImageProcessor.displayData(from: asymmetric))
        let cropped = try #require(NSBitmapImageRep(data: asymmetricResult))
        let opaquePixels = (0..<cropped.pixelsHigh).reduce(0) { count, y in
            count + (0..<cropped.pixelsWide).filter { x in
                (cropped.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }.count
        }
        #expect(opaquePixels == 8 * 20)
    }

    @Test("transparent landscape logos lose empty vertical margins")
    func landscapeLogoTrimming() throws {
        let source = try portraitFixture(
            width: 120, height: 60,
            opaqueRect: CGRect(x: 10, y: 25, width: 100, height: 10)
        )
        let result = try #require(CharacterPortraitImageProcessor.displayData(from: source))
        let bitmap = try #require(NSBitmapImageRep(data: result))
        #expect(bitmap.pixelsWide >= 100 && bitmap.pixelsWide < 120)
        #expect(bitmap.pixelsHigh >= 10 && bitmap.pixelsHigh < 30)
    }

    @Test("opaque, empty, and unreadable portraits retain their fallback behavior")
    func characterPortraitFallbacks() throws {
        let opaque = try portraitFixture(width: 12, height: 20, opaqueRect: CGRect(x: 0, y: 0, width: 12, height: 20))
        #expect(CharacterPortraitImageProcessor.displayData(from: opaque) == opaque)
        let empty = try portraitFixture(width: 12, height: 20, opaqueRect: .zero)
        #expect(CharacterPortraitImageProcessor.displayData(from: empty) == nil)
        #expect(CharacterPortraitImageProcessor.displayData(from: Data("not an image".utf8)) == nil)
    }

    @Test("only work and character lists show artwork")
    func characterCardLayoutSelection() {
        #expect(TagSummaryCardLayout.resolve(category: .work, selectedTab: .character) == .characterPortrait)
        #expect(TagSummaryCardLayout.resolve(category: .work, selectedTab: .parody) == .landscape)
        #expect(TagSummaryCardLayout.resolve(category: .creator, selectedTab: .artist) == .textOnly)
        #expect(TagSummaryCardLayout.resolve(category: .creator, selectedTab: .group) == .textOnly)
        #expect(TagSummaryCardLayout.resolve(category: .tags, selectedTab: .character) == .textOnly)
        #expect(!TagSummaryCardLayout.textOnly.hasImage)
        #expect(TagSummaryCardLayout.landscape.hasImage)
        #expect(TagSummaryCardLayout.characterPortrait.hasImage)
        #expect(TagSummaryCardLayout.textOnly.nameLineLimit == 2)
        #expect(TagSummaryCardLayout.landscape.nameLineLimit == 1)
        #expect(TagSummaryCardLayout.textOnly.columnWidthRange.lowerBound < TagSummaryCardLayout.landscape.columnWidthRange.lowerBound)
        #expect(abs(TagSummaryCardLayout.characterPortrait.aspectRatio - CGFloat(2.0 / 3.0)) < 0.0001)
        #expect(TagSummaryCardLayout.characterPortrait.columnWidthRange == 210...300)
        #expect(abs(TagSummaryCardLayout.landscape.aspectRatio - CGFloat(3.0 / 2.0)) < 0.0001)
        #expect(TagSummaryCardLayout.landscape.columnWidthRange == 240...360)
        #expect(TagSummaryCardLayout.characterPortrait.informationHeight > TagSummaryCardLayout.landscape.informationHeight)
    }

    @Test("category toolbar appears only on the active base page")
    func categoryToolbarVisibility() {
        for category in TagCategory.allCases {
            let destination = LibraryDestination.tagCategory(category)
            #expect(TagCategoryToolbarVisibility.isVisible(baseDestination: destination, detailPath: []))
            #expect(!TagCategoryToolbarVisibility.isVisible(baseDestination: destination, detailPath: [.workDetail(1)]))
            #expect(!TagCategoryToolbarVisibility.isVisible(baseDestination: destination, detailPath: [.bookDetail("book-1")]))
        }
        #expect(!TagCategoryToolbarVisibility.isVisible(baseDestination: .home, detailPath: []))
        #expect(!TagCategoryToolbarVisibility.isVisible(baseDestination: .search, detailPath: []))
    }

    @Test("category sorting uses a menu below the compact width")
    func categoryToolbarCompactThreshold() {
        let width = TagCategoryToolbarLayout.compactDetailWidth
        #expect(TagCategoryToolbarLayout.isCompact(detailWidth: width - 1))
        #expect(!TagCategoryToolbarLayout.isCompact(detailWidth: width))
        #expect(!TagCategoryToolbarLayout.isCompact(detailWidth: width + 1))
    }

    @Test("toolbar choices keep one selection and use available symbols")
    func categoryToolbarSelectionControls() {
        #expect(ExclusiveToolbarSelection.next(current: TagCategoryTab.parody, option: .character, isOn: true) == .character)
        #expect(ExclusiveToolbarSelection.next(current: TagCategoryTab.character, option: .character, isOn: false) == .character)
        #expect(ExclusiveToolbarSelection.next(current: TagSortStrategy.count, option: .alphabetical, isOn: true) == .alphabetical)
        #expect(ExclusiveToolbarSelection.next(current: SortDirection.descending, option: .ascending, isOn: true) == .ascending)
        #expect(ExclusiveToolbarSelection.next(current: Optional(TagNamespaceGroup.female), option: .male, isOn: true) == .male)
        #expect(ExclusiveToolbarSelection.next(current: Optional(TagNamespaceGroup.male), option: .male, isOn: false) == .male)

        let symbols = TagCategoryTab.allCases.map(\.toolbarSystemImage)
            + TagNamespaceDisplayMode.allCases.map(\.toolbarSystemImage)
            + TagSortStrategy.allCases.map(\.toolbarSystemImage)
            + SortDirection.allCases.map(\.toolbarSystemImage)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test("tag namespace menu is available only for populated grouped tags")
    func tagNamespaceToolbarMenuAvailability() {
        #expect(TagNamespaceToolbarMenu.displayOrder == [.flat, .grouped])
        #expect(TagNamespaceToolbarMenu.shouldShow(displayMode: .grouped, hasGroups: true))
        #expect(!TagNamespaceToolbarMenu.shouldShow(displayMode: .grouped, hasGroups: false))
        #expect(!TagNamespaceToolbarMenu.shouldShow(displayMode: .flat, hasGroups: true))
        #expect(!TagNamespaceToolbarMenu.shouldShow(displayMode: .flat, hasGroups: false))
    }

    @Test("direction control alternates and category search clears only on a scope change")
    func categoryToolbarDirectionAndSearchScope() {
        #expect(SortDirection.descending.next == .ascending)
        #expect(SortDirection.descending.next.next == .descending)

        let work = TagCategorySearchScope.resolve(
            category: .work, tab: .parody, displayMode: .grouped, group: nil
        )
        let character = TagCategorySearchScope.resolve(
            category: .work, tab: .character, displayMode: .grouped, group: nil
        )
        let creator = TagCategorySearchScope.resolve(
            category: .creator, tab: .artist, displayMode: .grouped, group: nil
        )
        let allTags = TagCategorySearchScope.resolve(
            category: .tags, tab: nil, displayMode: .flat, group: nil
        )
        let female = TagCategorySearchScope.resolve(
            category: .tags, tab: nil, displayMode: .grouped, group: .female
        )
        let male = TagCategorySearchScope.resolve(
            category: .tags, tab: nil, displayMode: .grouped, group: .male
        )
        #expect(TagCategorySearchScope.query("love", afterChangingFrom: work, to: work) == "love")
        #expect(TagCategorySearchScope.query("love", afterChangingFrom: work, to: character).isEmpty)
        #expect(TagCategorySearchScope.query("love", afterChangingFrom: work, to: creator).isEmpty)
        #expect(TagCategorySearchScope.query("love", afterChangingFrom: allTags, to: female).isEmpty)
        #expect(TagCategorySearchScope.query("love", afterChangingFrom: female, to: male).isEmpty)
    }

    @Test("hover lift fits grid gaps and honors reduced motion")
    func tagCardHoverLift() {
        let scale = TagSummaryCardHoverMetrics.hoveredScale
        #expect(scale > 1 && scale < 1.05)
        #expect(TagSummaryCardHoverMetrics.scale(isHovering: true, reduceMotion: false) == scale)
        #expect(TagSummaryCardHoverMetrics.scale(isHovering: true, reduceMotion: true) == 1)
        #expect(TagSummaryCardHoverMetrics.scale(isHovering: false, reduceMotion: false) == 1)
        let widestCard = TagSummaryCardLayout.landscape.columnWidthRange.upperBound
        let tallestCard = TagSummaryCardLayout.characterPortrait.columnWidthRange.upperBound
            / TagSummaryCardLayout.characterPortrait.aspectRatio
            + TagSummaryCardLayout.characterPortrait.informationHeight
            + TagSummaryGridMetrics.cardInformationSpacing
        #expect(widestCard * (scale - 1) < TagSummaryGridMetrics.columnSpacing)
        #expect(tallestCard * (scale - 1) < TagSummaryGridMetrics.rowSpacing)
    }

    @Test("portrait placement keeps manual scale and offsets after image trimming")
    func characterPortraitPlacementUsesManualValues() {
        let profile = TagVisualProfile(
            tagID: 1,
            foregroundScale: 1.4,
            foregroundOffsetX: -0.1,
            foregroundOffsetY: 0.2
        )
        let placement = CharacterPortraitPlacement(profile: profile)
        #expect(placement.scale == 1.4)
        #expect(placement.offset(in: CGSize(width: 240, height: 360)) == CGSize(width: -24, height: 72))
        let defaultPlacement = CharacterPortraitPlacement(profile: nil)
        #expect(defaultPlacement.scale == 1)
        #expect(defaultPlacement.offset(in: CGSize(width: 240, height: 360)) == .zero)
    }

    @Test("work detail surface roles keep hero stronger than shelf")
    func workDetailSurfaceRolesKeepHeroStrongerThanShelf() {
        #expect(WorkDetailSurfaceRole.hero.cornerRadius > WorkDetailSurfaceRole.shelf.cornerRadius)
        #expect(WorkDetailSurfaceRole.hero.strokeOpacity > WorkDetailSurfaceRole.shelf.strokeOpacity)
        #expect(WorkDetailSurfaceRole.hero.shadowOpacity > WorkDetailSurfaceRole.shelf.shadowOpacity)
        #expect(WorkDetailSurfaceRole.hero.shadowRadius > WorkDetailSurfaceRole.shelf.shadowRadius)
        #expect(WorkDetailSurfaceRole.hero.shadowYOffset > WorkDetailSurfaceRole.shelf.shadowYOffset)
    }

    @Test("work character shelf visual state uses quiet placeholder without foreground")
    func workCharacterShelfVisualStateUsesQuietPlaceholderWithoutForeground() {
        let withForeground = WorkCharacterShelfVisualState.resolve(hasForegroundAsset: true)
        let withoutForeground = WorkCharacterShelfVisualState.resolve(hasForegroundAsset: false)

        #expect(!withForeground.showsPlaceholder)
        #expect(withForeground.characterShadowOpacity > 0)
        #expect(withoutForeground.showsPlaceholder)
        #expect(withoutForeground.characterShadowOpacity == 0)
    }

    @Test("delete book confirmation code is four digits and exact match only")
    func deleteBookConfirmationCodeMatchesExactly() {
        #expect(DeleteBookConfirmationCode.generate(randomNumber: { 7 }) == "0007")
        #expect(DeleteBookConfirmationCode.generate(randomNumber: { 42 }) == "0042")
        #expect(DeleteBookConfirmationCode.generate(randomNumber: { 12345 }) == "9999")
        #expect(DeleteBookConfirmationCode.matches(input: "0042", code: "0042"))
        #expect(DeleteBookConfirmationCode.matches(input: " 0042 ", code: "0042"))
        #expect(!DeleteBookConfirmationCode.matches(input: "42", code: "0042"))
    }

    @Test("app data directory defaults to system application support")
    func appDataDirectoryDefaultsToSystemApplicationSupport() throws {
        let root = try AppDataDirectory.rootURL(environment: [:], createIfNeeded: false)

        #expect(root.lastPathComponent == "NyaEH")
        #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test("app data directory migrates the old production directory")
    func appDataDirectoryMigratesLegacyProductionData() throws {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let legacyDirectory = supportDirectory.appendingPathComponent(LegacyNaming.applicationSupportDirectory, isDirectory: true)
        let markerURL = legacyDirectory.appendingPathComponent(LegacyNaming.databaseFilename)

        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: markerURL)
        defer {
            try? fileManager.removeItem(at: supportDirectory.deletingLastPathComponent())
        }

        let root = try AppDataDirectory.rootURL(
            environment: [:],
            applicationSupportDirectory: supportDirectory,
            createIfNeeded: true
        )

        #expect(root.lastPathComponent == "NyaEH")
        #expect(fileManager.fileExists(atPath: root.appendingPathComponent(LegacyNaming.databaseFilename).path))
        #expect(!fileManager.fileExists(atPath: legacyDirectory.path))
    }

    @Test("app data directory uses environment override")
    func appDataDirectoryUsesEnvironmentOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let root = try AppDataDirectory.rootURL(
            environment: [AppDataDirectory.overrideEnvironmentKey: directory.path],
            createIfNeeded: true
        )

        #expect(root.path == directory.path)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("app data directory expands tilde in override")
    func appDataDirectoryExpandsTildeInOverride() throws {
        let root = try AppDataDirectory.rootURL(
            environment: [AppDataDirectory.overrideEnvironmentKey: "~/NyaEHDevData"],
            createIfNeeded: false
        )

        #expect(!root.path.contains("~"))
        #expect(root.path.hasSuffix("/NyaEHDevData"))
    }

    @Test("preferences persist through user defaults")
    @MainActor
    func preferencesPersistThroughUserDefaults() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let languageDomain = "com.nyaeh.test.language.\(UUID().uuidString)"
        let languageDefaults = UserDefaults(suiteName: languageDomain)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            languageDefaults.removePersistentDomain(forName: languageDomain)
        }

        let preferences = AppPreferences(
            userDefaults: defaults,
            applicationLanguageDefaults: languageDefaults,
            applicationLanguageDomain: languageDomain
        )
        preferences.themeMode = .dark
        preferences.selectLanguage(.ja)
        preferences.isTagTranslationEnabled = true
        preferences.isCoverSimilarityVersionRecommendationEnabled = true
        preferences.isSemanticSeriesRecommendationEnabled = true
        preferences.bookTitleDisplayMode = .compactJapaneseTitle

        let restored = AppPreferences(
            userDefaults: defaults,
            applicationLanguageDefaults: languageDefaults,
            applicationLanguageDomain: languageDomain
        )
        #expect(restored.themeMode == .dark)
        #expect(restored.language == .ja)
        #expect(restored.isTagTranslationEnabled)
        #expect(restored.isCoverSimilarityVersionRecommendationEnabled)
        #expect(restored.isSemanticSeriesRecommendationEnabled)
        #expect(restored.bookTitleDisplayMode == .compactJapaneseTitle)
    }

    @Test("last library scan timestamp persists through user defaults")
    @MainActor
    func lastLibraryScanTimestampPersistsThroughUserDefaults() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        preferences.lastLibraryScanCompletedAt = 1_772_345_678_900

        let restored = AppPreferences(userDefaults: defaults)
        #expect(restored.lastLibraryScanCompletedAt == 1_772_345_678_900)

        restored.lastLibraryScanCompletedAt = nil
        let cleared = AppPreferences(userDefaults: defaults)
        #expect(cleared.lastLibraryScanCompletedAt == nil)
    }

    @Test("card width preferences default normalize and persist")
    @MainActor
    func cardWidthPreferencesDefaultNormalizeAndPersist() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.homeCardWidth == BookCardMetrics.defaultWidth)
        #expect(preferences.advancedSearchCardWidth == BookCardMetrics.defaultWidth)
        #expect(preferences.libraryShelfCardWidth == BookCardMetrics.defaultWidth)

        preferences.homeCardWidth = 111
        preferences.advancedSearchCardWidth = 133
        preferences.libraryShelfCardWidth = 999

        #expect(preferences.homeCardWidth == BookCardMetrics.minimumWidth)
        #expect(preferences.advancedSearchCardWidth == 136)
        #expect(preferences.libraryShelfCardWidth == BookCardMetrics.maximumWidth)

        let restored = AppPreferences(userDefaults: defaults)
        #expect(restored.homeCardWidth == BookCardMetrics.minimumWidth)
        #expect(restored.advancedSearchCardWidth == 136)
        #expect(restored.libraryShelfCardWidth == BookCardMetrics.maximumWidth)
    }

    @Test("cover similarity distance defaults clamps and persists")
    @MainActor
    func coverSimilarityDistanceDefaultsClampsAndPersists() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.coverSimilarityMaximumDistance == 20)

        preferences.coverSimilarityMaximumDistance = 39.6
        #expect(preferences.coverSimilarityMaximumDistance == 40)

        let restored = AppPreferences(userDefaults: defaults)
        #expect(restored.coverSimilarityMaximumDistance == 40)

        restored.coverSimilarityMaximumDistance = 999
        #expect(restored.coverSimilarityMaximumDistance == 80)
    }

    @Test("accent color preferences default and persist")
    @MainActor
    func accentColorPreferencesDefaultAndPersist() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.accentColorMode == .blue)
        #expect(preferences.resolvedAccentColor != nil)

        preferences.accentColorMode = .system
        preferences.customAccentColorHex = "#336699CC"

        var restored = AppPreferences(userDefaults: defaults)
        #expect(restored.accentColorMode == .system)
        #expect(restored.resolvedAccentColor == nil)
        #expect(restored.customAccentColorHex == "#336699CC")

        restored.accentColorMode = .custom
        restored = AppPreferences(userDefaults: defaults)
        #expect(restored.accentColorMode == .custom)
        #expect(restored.customAccentColorHex == "#336699CC")
        #expect(AppAccentColor.custom.nsColor(customHex: restored.customAccentColorHex) != nil)
    }

    @Test("invalid custom accent color falls back safely")
    @MainActor
    func invalidCustomAccentColorFallsBackSafely() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("not-a-color", forKey: "NyaEH.accentColor.customHex")
        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.customAccentColorHex == "#0A84FFFF")

        preferences.accentColorMode = .custom
        preferences.customAccentColorHex = "#11223344"
        preferences.customAccentColorHex = "still-not-a-color"
        #expect(preferences.customAccentColorHex == "#11223344")
        #expect(AppAccentColor.custom.nsColor(customHex: preferences.customAccentColorHex) != nil)
    }

    @Test("tag translation display is disabled by default")
    @MainActor
    func tagTranslationDisplayIsDisabledByDefault() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(!preferences.isTagTranslationEnabled)
    }

    @Test("book title display mode defaults to original title")
    @MainActor
    func bookTitleDisplayModeDefaultsToOriginalTitle() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.bookTitleDisplayMode == .originalTitle)
    }

    @Test("reader initial load limit defaults persists and snaps")
    @MainActor
    func readerInitialLoadLimitDefaultsPersistsAndSnaps() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.readerInitialLoadLimit == 100)

        preferences.readerInitialLoadLimit = 128
        let restored = AppPreferences(userDefaults: defaults)
        #expect(restored.readerInitialLoadLimit == 150)

        restored.readerInitialLoadLimit = 0
        #expect(restored.readerInitialLoadLimit == 0)

        restored.readerInitialLoadLimit = 999
        #expect(restored.readerInitialLoadLimit == 200)
    }

    @Test("reader hover preview delay defaults persists and snaps")
    @MainActor
    func readerHoverPreviewDelayDefaultsPersistsAndSnaps() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.readerHoverPreviewDelayMilliseconds == 500)

        preferences.readerHoverPreviewDelayMilliseconds = 700
        let restored = AppPreferences(userDefaults: defaults)
        #expect(restored.readerHoverPreviewDelayMilliseconds == 700)

        restored.readerHoverPreviewDelayMilliseconds = 20
        #expect(restored.readerHoverPreviewDelayMilliseconds == 200)

        restored.readerHoverPreviewDelayMilliseconds = 5_000
        #expect(restored.readerHoverPreviewDelayMilliseconds == 700)
    }

    @Test("reader display preferences default persist and recover invalid values")
    @MainActor
    func readerDisplayPreferencesDefaultPersistAndRecoverInvalidValues() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(
            userDefaults: defaults,
            credentialStore: InMemoryCredentialStore()
        )
        #expect(preferences.readerDisplayPreferences == .defaultValue)

        preferences.readerDisplayPreferences = ReaderDisplayPreferences(
            layoutMode: .doublePage,
            fitMode: .custom,
            zoom: 2.4,
            showsThumbnails: true
        )
        let restored = AppPreferences(
            userDefaults: defaults,
            credentialStore: InMemoryCredentialStore()
        )
        #expect(restored.readerDisplayPreferences.layoutMode == .doublePage)
        #expect(restored.readerDisplayPreferences.fitMode == .custom)
        #expect(restored.readerDisplayPreferences.zoom == 2.4)
        #expect(restored.readerDisplayPreferences.showsThumbnails)

        restored.readerDisplayPreferences = ReaderDisplayPreferences(
            layoutMode: .continuous,
            fitMode: .custom,
            zoom: 20,
            showsThumbnails: true
        )
        #expect(restored.readerDisplayPreferences.zoom == ReaderDisplayPreferences.maximumZoom)

        defaults.set("unknown-layout", forKey: "NyaEH.reader.display.layoutMode")
        defaults.set("unknown-fit", forKey: "NyaEH.reader.display.fitMode")
        defaults.set(Double.nan, forKey: "NyaEH.reader.display.zoom")
        defaults.removeObject(forKey: "NyaEH.reader.display.showsThumbnails")
        let recovered = AppPreferences(
            userDefaults: defaults,
            credentialStore: InMemoryCredentialStore()
        )
        #expect(recovered.readerDisplayPreferences == .defaultValue)
    }

    @Test("reader display preferences use the configured development suite")
    @MainActor
    func readerDisplayPreferencesUseConfiguredDevelopmentSuite() {
        let suiteName = "com.nyaeh.test.reader-display.\(UUID().uuidString)"
        let isolatedSuiteName = "com.nyaeh.test.reader-display.isolated.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: isolatedSuiteName)?.removePersistentDomain(forName: isolatedSuiteName)
        }

        let defaults = AppPreferences.defaultUserDefaults(
            environment: [AppPreferences.userDefaultsSuiteEnvironmentKey: suiteName]
        )
        let preferences = AppPreferences(
            userDefaults: defaults,
            credentialStore: InMemoryCredentialStore()
        )
        preferences.readerDisplayPreferences = ReaderDisplayPreferences(
            layoutMode: .continuous,
            fitMode: .fitWidth,
            zoom: 1.75,
            showsThumbnails: true
        )

        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        #expect(isolatedDefaults.string(forKey: "NyaEH.reader.display.layoutMode") == "continuous")
        #expect(isolatedDefaults.string(forKey: "NyaEH.reader.display.fitMode") == "fitWidth")
        #expect(isolatedDefaults.double(forKey: "NyaEH.reader.display.zoom") == 1.75)
        #expect(isolatedDefaults.bool(forKey: "NyaEH.reader.display.showsThumbnails"))

        let otherPreferences = AppPreferences(
            userDefaults: UserDefaults(suiteName: isolatedSuiteName)!,
            credentialStore: InMemoryCredentialStore()
        )
        #expect(!otherPreferences.readerDisplayPreferences.showsThumbnails)
    }

    @Test("reader window frame persists in its configured suite and ignores damaged values")
    @MainActor
    func readerWindowFramePersistsInConfiguredSuite() {
        let developmentSuite = "com.nyaeh.test.reader-frame.development.\(UUID().uuidString)"
        let productionSuite = "com.nyaeh.test.reader-frame.production.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: developmentSuite)?.removePersistentDomain(forName: developmentSuite)
            UserDefaults(suiteName: productionSuite)?.removePersistentDomain(forName: productionSuite)
        }

        let developmentDefaults = AppPreferences.defaultUserDefaults(
            environment: [AppPreferences.userDefaultsSuiteEnvironmentKey: developmentSuite]
        )
        let developmentPreferences = AppPreferences(
            userDefaults: developmentDefaults,
            credentialStore: InMemoryCredentialStore()
        )
        let frame = CGRect(x: 120, y: 90, width: 1_240, height: 780)
        developmentPreferences.saveReaderWindowFrame(frame)

        let restoredDevelopmentPreferences = AppPreferences(
            userDefaults: UserDefaults(suiteName: developmentSuite)!,
            credentialStore: InMemoryCredentialStore()
        )
        let productionPreferences = AppPreferences(
            userDefaults: UserDefaults(suiteName: productionSuite)!,
            credentialStore: InMemoryCredentialStore()
        )
        #expect(restoredDevelopmentPreferences.savedReaderWindowFrame() == frame)
        #expect(productionPreferences.savedReaderWindowFrame() == nil)

        developmentDefaults.set("0,0,not-a-number,700", forKey: "NyaEH.reader.window.frame")
        #expect(developmentPreferences.savedReaderWindowFrame() == nil)
    }

    @Test("main-window size and sidebar width persist in the configured suite")
    @MainActor
    func mainWindowGeometryPersistsInConfiguredSuite() throws {
        let suite = "com.nyaeh.test.main-window.\(UUID())"
        let otherSuite = "\(suite).other"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }
        let preferences = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        let otherPreferences = AppPreferences(userDefaults: otherDefaults, credentialStore: InMemoryCredentialStore())
        let size = CGSize(width: 1_240, height: 760)

        #expect(preferences.savedMainWindowSize() == nil)
        #expect(preferences.savedMainSidebarWidth() == nil)
        preferences.saveMainWindowSize(size)
        preferences.saveMainSidebarWidth(256.4)
        preferences.saveMainWindowSize(CGSize(width: CGFloat.infinity, height: 760))
        preferences.saveMainSidebarWidth(0)
        preferences.saveMainSidebarWidth(.nan)

        let restored = AppPreferences(
            userDefaults: try #require(UserDefaults(suiteName: suite)),
            credentialStore: InMemoryCredentialStore()
        )
        #expect(restored.savedMainWindowSize() == size)
        #expect(restored.savedMainSidebarWidth() == 256)
        #expect(otherPreferences.savedMainWindowSize() == nil)
        #expect(otherPreferences.savedMainSidebarWidth() == nil)

        defaults.set([1240, 0], forKey: "NyaEH.mainWindow.size")
        defaults.set("invalid", forKey: "NyaEH.mainWindow.sidebarWidth")
        #expect(restored.savedMainWindowSize() == nil)
        #expect(restored.savedMainSidebarWidth() == nil)
    }

    @Test("restored window size respects the available display and existing minimum")
    func mainWindowGeometryClampsRestoredSize() {
        let available = CGSize(width: 1_440, height: 900)
        #expect(MainWindowGeometry.initialSize(nil, availableSize: available) == nil)
        #expect(MainWindowGeometry.initialSize(.zero, availableSize: available) == nil)
        #expect(MainWindowGeometry.initialSize(CGSize(width: 2_000, height: 600), availableSize: available)
                == CGSize(width: 1_440, height: 600))
        #expect(MainWindowGeometry.initialSize(CGSize(width: 700, height: 400), availableSize: available)
                == MainWindowGeometry.minimumContentSize)
        let smallDisplay = CGSize(width: 800, height: 500)
        #expect(MainWindowGeometry.initialSize(available, availableSize: smallDisplay) == smallDisplay)
        #expect(MainWindowGeometry.sidebarWidth(100) == MainWindowGeometry.minimumSidebarWidth)
        #expect(MainWindowGeometry.sidebarWidth(800) == MainWindowGeometry.maximumSidebarWidth)
    }

    @Test("only a user drag on the visible main sidebar saves its width")
    @MainActor
    func mainSidebarWidthIgnoresWindowLayoutAndHiddenSidebar() throws {
        let suite = "com.nyaeh.test.main-sidebar.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        let observer = MainSidebarWidthObserver.ObserverView(preferences: preferences)
        let split = NSSplitView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 600))
        split.isVertical = true
        let sidebar = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.addSubview(observer)
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(NSView(frame: CGRect(x: 261, y: 0, width: 739, height: 600)))
        sidebar.setFrameSize(CGSize(width: 260, height: 600))

        func postResize(_ source: NSSplitView, userResize: Bool, dividerIndex: Int = 0) {
            NotificationCenter.default.post(
                name: NSSplitView.didResizeSubviewsNotification,
                object: source,
                userInfo: ["NSSplitViewDividerIndex": dividerIndex, "NSSplitViewUserResizeKey": userResize]
            )
        }

        postResize(split, userResize: true)
        #expect(preferences.savedMainSidebarWidth() == 260)

        sidebar.setFrameSize(CGSize(width: 180, height: 600))
        postResize(split, userResize: false)
        postResize(split, userResize: true, dividerIndex: 1)
        #expect(preferences.savedMainSidebarWidth() == 260)

        sidebar.isHidden = true
        postResize(split, userResize: true)
        #expect(preferences.savedMainSidebarWidth() == 260)

        sidebar.isHidden = false
        postResize(split, userResize: true)
        #expect(preferences.savedMainSidebarWidth() == 180)
    }

    @Test("pagination defaults persist and snap")
    @MainActor
    func paginationDefaultsPersistAndSnap() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.advancedSearchPageSize == 30)
        #expect(preferences.libraryCollectionPageSize == 30)
        #expect(preferences.tagCategoryPageSize == 30)
        #expect(preferences.collectionCandidatePageSize == 20)
        #expect(preferences.versionCandidatePageSize == 20)

        preferences.advancedSearchPageSize = 20
        preferences.libraryCollectionPageSize = 50
        preferences.tagCategoryPageSize = 100
        preferences.collectionCandidatePageSize = 100
        preferences.versionCandidatePageSize = 44

        let restored = AppPreferences(userDefaults: defaults)
        #expect(restored.advancedSearchPageSize == 20)
        #expect(restored.libraryCollectionPageSize == 50)
        #expect(restored.tagCategoryPageSize == 100)
        #expect(restored.collectionCandidatePageSize == 30)
        #expect(restored.versionCandidatePageSize == 30)

        restored.tagCategoryPageSize = 44
        #expect(restored.tagCategoryPageSize == 50)
        restored.collectionCandidatePageSize = 10
        restored.versionCandidatePageSize = 25
        #expect(restored.collectionCandidatePageSize == 10)
        #expect(restored.versionCandidatePageSize == 20)
    }

    @Test("management page size changes publish on page one and persist independently", arguments: [true, false])
    @MainActor
    func managementCandidatePageSizePublishesObservationChanges(isSeries: Bool) {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        let keyPath: ReferenceWritableKeyPath<AppPreferences, Int> = isSeries
            ? \.collectionCandidatePageSize : \.versionCandidatePageSize
        let otherKeyPath: ReferenceWritableKeyPath<AppPreferences, Int> = isSeries
            ? \.versionCandidatePageSize : \.collectionCandidatePageSize
        let candidates = Array(0..<100)
        let didChange = ObservationChangeFlag()
        let initialPage = withObservationTracking {
            Pagination.pageItems(candidates, page: 1, pageSize: preferences[keyPath: keyPath])
        } onChange: {
            didChange.markChanged()
        }
        #expect(initialPage.count == 20)

        preferences[keyPath: keyPath] = 30
        #expect(didChange.value)
        #expect(Pagination.pageItems(candidates, page: 1, pageSize: preferences[keyPath: keyPath]).count == 30)
        #expect(Pagination.pageCount(itemCount: candidates.count, pageSize: preferences[keyPath: keyPath]) == 4)
        #expect(preferences[keyPath: otherKeyPath] == 20)

        let restored = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        #expect(restored[keyPath: keyPath] == 30)
        #expect(restored[keyPath: otherKeyPath] == 20)

        let normalizedChange = ObservationChangeFlag()
        withObservationTracking {
            _ = preferences[keyPath: keyPath]
        } onChange: {
            normalizedChange.markChanged()
        }
        preferences[keyPath: keyPath] = 11
        #expect(normalizedChange.value)
        #expect(preferences[keyPath: keyPath] == 10)
        #expect(Pagination.pageItems(candidates, page: 1, pageSize: preferences[keyPath: keyPath]).count == 10)
        let normalized = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        #expect(normalized[keyPath: keyPath] == 10)
        #expect(normalized[keyPath: otherKeyPath] == 20)
    }

    @Test("advanced search page size publishes observation changes")
    @MainActor
    func advancedSearchPageSizePublishesObservationChanges() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        let didChange = ObservationChangeFlag()
        withObservationTracking {
            _ = preferences.advancedSearchPageSize
        } onChange: {
            didChange.markChanged()
        }

        preferences.advancedSearchPageSize = 50

        #expect(didChange.value)
        #expect(preferences.advancedSearchPageSize == 50)
    }

    @Test("saved searches replace duplicates and delete through atomic updates")
    @MainActor
    func savedSearchesReplaceDuplicatesAndDeleteThroughAtomicUpdates() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        let original = SavedBookSearch(
            name: "Original",
            query: "artist:test",
            scope: .all,
            mode: .broad,
            sortKey: .posted,
            sortDirection: .descending,
            layout: .card
        )
        let replacement = SavedBookSearch(
            name: "Replacement",
            query: "artist:test",
            scope: .all,
            mode: .broad,
            sortKey: .rating,
            sortDirection: .ascending,
            layout: .expandedRow
        )

        preferences.saveSearch(original)
        preferences.saveSearch(replacement)

        #expect(preferences.savedSearches == [replacement])
        #expect(AppPreferences(userDefaults: defaults).savedSearches == [replacement])

        preferences.removeSavedSearch(id: replacement.id)

        #expect(preferences.savedSearches.isEmpty)
        #expect(AppPreferences(userDefaults: defaults).savedSearches.isEmpty)
    }

    @Test("advanced search facet panel expansion persists")
    @MainActor
    func advancedSearchFacetPanelExpansionPersists() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.isAdvancedSearchFacetPanelExpanded)

        preferences.isAdvancedSearchFacetPanelExpanded = false

        let restored = AppPreferences(userDefaults: defaults)
        #expect(!restored.isAdvancedSearchFacetPanelExpanded)
    }

    @Test("series and version candidate pane visibility persists independently")
    @MainActor
    func managementCandidatePaneVisibilityPersists() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        let otherSuiteName = "com.nyaeh.test.management-panes.\(UUID().uuidString)"
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: otherSuiteName)?.removePersistentDomain(forName: otherSuiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.isCollectionCandidateAreaVisible)
        #expect(preferences.isVersionCandidateAreaVisible)

        preferences.isCollectionCandidateAreaVisible = false
        let restored = AppPreferences(userDefaults: defaults)
        #expect(!restored.isCollectionCandidateAreaVisible)
        #expect(restored.isVersionCandidateAreaVisible)

        restored.isVersionCandidateAreaVisible = false
        let restoredAgain = AppPreferences(userDefaults: defaults)
        #expect(!restoredAgain.isCollectionCandidateAreaVisible)
        #expect(!restoredAgain.isVersionCandidateAreaVisible)

        let isolated = AppPreferences(
            userDefaults: UserDefaults(suiteName: otherSuiteName)!,
            credentialStore: InMemoryCredentialStore()
        )
        #expect(isolated.isCollectionCandidateAreaVisible)
        #expect(isolated.isVersionCandidateAreaVisible)
    }

    @Test("advanced search header pinning persists")
    @MainActor
    func advancedSearchHeaderPinningPersists() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.isAdvancedSearchHeaderPinned)

        preferences.isAdvancedSearchHeaderPinned = false

        let restored = AppPreferences(userDefaults: defaults)
        #expect(!restored.isAdvancedSearchHeaderPinned)
    }

    @Test("advanced search collection member expansion persists")
    @MainActor
    func advancedSearchCollectionMemberExpansionPersists() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(!preferences.isAdvancedSearchCollectionMembersExpanded)

        preferences.isAdvancedSearchCollectionMembersExpanded = true

        let restored = AppPreferences(userDefaults: defaults)
        #expect(restored.isAdvancedSearchCollectionMembersExpanded)
    }

    @Test("home insight chart expansion persists")
    @MainActor
    func homeInsightChartExpansionPersists() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(!preferences.isHomeInsightChartsExpanded)

        preferences.isHomeInsightChartsExpanded = true
        let expanded = AppPreferences(userDefaults: defaults)
        #expect(expanded.isHomeInsightChartsExpanded)

        expanded.isHomeInsightChartsExpanded = false
        let collapsed = AppPreferences(userDefaults: defaults)
        #expect(!collapsed.isHomeInsightChartsExpanded)
    }

    @Test("pagination slices and clamps pages")
    func paginationSlicesAndClampsPages() {
        let items = Array(1...65)

        #expect(Pagination.pageCount(itemCount: 0, pageSize: 30) == 1)
        #expect(Pagination.pageCount(itemCount: 65, pageSize: 30) == 3)
        #expect(Pagination.clampedPage(9, itemCount: 65, pageSize: 30) == 3)
        #expect(Pagination.pageItems(items, page: 1, pageSize: 30) == Array(1...30))
        #expect(Pagination.pageItems(items, page: 3, pageSize: 30) == Array(61...65))
        #expect(Pagination.pageItems(items, page: 99, pageSize: 30) == Array(61...65))
        #expect(Pagination.pageItems(items, page: 1, pageSize: 0).isEmpty)
    }

    @Test("reader hover preview sizing favors available height")
    func readerHoverPreviewSizingFavorsAvailableHeight() {
        let size = BookReaderHoverPreviewSizer.previewSize(
            imageSize: CGSize(width: 800, height: 1_600),
            availableSize: CGSize(width: 1_000, height: 900),
            visibleScreenHeight: 1_000
        )

        #expect(abs(size.height - 765) < 0.5)
        #expect(size.width <= 976)
    }

    @Test("reader hover preview sizing clamps wide images to available width")
    func readerHoverPreviewSizingClampsWideImagesToAvailableWidth() {
        let size = BookReaderHoverPreviewSizer.previewSize(
            imageSize: CGSize(width: 1_600, height: 600),
            availableSize: CGSize(width: 820, height: 900),
            visibleScreenHeight: 1_000
        )

        #expect(abs(size.width - 796) < 0.5)
        #expect(size.height < 765)
    }

    @Test("reader hover preview sizing enlarges tiny images within bounds")
    func readerHoverPreviewSizingEnlargesTinyImagesWithinBounds() {
        let size = BookReaderHoverPreviewSizer.previewSize(
            imageSize: CGSize(width: 80, height: 120),
            availableSize: CGSize(width: 900, height: 700),
            visibleScreenHeight: 1_000
        )

        #expect(size.width >= 220)
        #expect(size.height >= 260)
        #expect(size.height <= 595)
    }

    @Test("reader hover preview placement flips near right edge")
    func readerHoverPreviewPlacementFlipsNearRightEdge() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let origin = BookReaderHoverPreviewPlacement.origin(
            previewSize: CGSize(width: 360, height: 600),
            pointerInScreen: CGPoint(x: 930, y: 420),
            tileFrameInScreen: CGRect(x: 900, y: 360, width: 80, height: 120),
            visibleFrame: visibleFrame
        )

        #expect(origin.x < 900)
        #expect(origin.x >= visibleFrame.minX + 12)
        #expect(origin.x + 360 <= visibleFrame.maxX - 12)
    }

    @Test("reader hover preview placement clamps vertical edges")
    func readerHoverPreviewPlacementClampsVerticalEdges() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let topOrigin = BookReaderHoverPreviewPlacement.origin(
            previewSize: CGSize(width: 320, height: 600),
            pointerInScreen: CGPoint(x: 200, y: 790),
            tileFrameInScreen: CGRect(x: 120, y: 730, width: 80, height: 120),
            visibleFrame: visibleFrame
        )
        let bottomOrigin = BookReaderHoverPreviewPlacement.origin(
            previewSize: CGSize(width: 320, height: 600),
            pointerInScreen: CGPoint(x: 200, y: 20),
            tileFrameInScreen: CGRect(x: 120, y: 10, width: 80, height: 120),
            visibleFrame: visibleFrame
        )

        #expect(topOrigin.y + 600 <= visibleFrame.maxY - 12)
        #expect(bottomOrigin.y >= visibleFrame.minY + 12)
    }

    @Test("reader hover preview placement keeps large previews visible")
    func readerHoverPreviewPlacementKeepsLargePreviewsVisible() {
        let visibleFrame = CGRect(x: 100, y: 80, width: 1_200, height: 900)
        let previewSize = CGSize(width: 1_000, height: 760)
        let origin = BookReaderHoverPreviewPlacement.origin(
            previewSize: previewSize,
            pointerInScreen: CGPoint(x: 650, y: 500),
            tileFrameInScreen: CGRect(x: 600, y: 440, width: 80, height: 120),
            visibleFrame: visibleFrame
        )

        #expect(origin.x >= visibleFrame.minX + 12)
        #expect(origin.y >= visibleFrame.minY + 12)
        #expect(origin.x + previewSize.width <= visibleFrame.maxX - 12)
        #expect(origin.y + previewSize.height <= visibleFrame.maxY - 12)
    }

    @Test("compact title removes common metadata wrappers")
    func compactTitleRemovesCommonMetadataWrappers() {
        let title = "123456 - (C86) [海通信 (なまもななせ)] 【DL版】YAZAWA Nico no Mezase! GraDol（Love Live!）"

        #expect(BookTitleFormatter.compactTitle(title) == "YAZAWA Nico no Mezase! GraDol")
        #expect(BookTitleFormatter.compactTitle("123456 title") == "title")
        #expect(BookTitleFormatter.compactTitle("[Group] (Event) 【Extra】 （Series） Body") == "Body")
    }

    @Test("title display modes apply fallback rules")
    func titleDisplayModesApplyFallbackRules() {
        let book = LibraryBook(
            title: "(C86) [Circle] English Title",
            hash: "hash",
            filepath: "/tmp/book.zip",
            titleJpn: "(C86) [サークル] 日本語タイトル"
        )
        let noJapanese = LibraryBook(
            title: "(C86) [Circle] English Title",
            hash: "hash2",
            filepath: "/tmp/book2.zip"
        )
        let emptyCompact = LibraryBook(
            title: "(C86) [Circle]",
            hash: "hash3",
            filepath: "/tmp/book3.zip"
        )

        #expect(BookTitleFormatter.displayTitle(for: book, mode: .originalTitle) == "(C86) [Circle] English Title")
        #expect(BookTitleFormatter.displayTitle(for: book, mode: .japaneseTitle) == "(C86) [サークル] 日本語タイトル")
        #expect(BookTitleFormatter.displayTitle(for: book, mode: .compactTitle) == "English Title")
        #expect(BookTitleFormatter.displayTitle(for: book, mode: .compactJapaneseTitle) == "日本語タイトル")
        #expect(BookTitleFormatter.displayTitle(for: noJapanese, mode: .japaneseTitle) == noJapanese.title)
        #expect(BookTitleFormatter.displayTitle(for: noJapanese, mode: .compactJapaneseTitle) == "English Title")
        #expect(BookTitleFormatter.displayTitle(for: emptyCompact, mode: .compactTitle) == emptyCompact.title)
    }

    @Test("title display modes cycle in detail order")
    func titleDisplayModesCycleInDetailOrder() {
        #expect(BookTitleDisplayMode.originalTitle.next == .japaneseTitle)
        #expect(BookTitleDisplayMode.japaneseTitle.next == .compactTitle)
        #expect(BookTitleDisplayMode.compactTitle.next == .compactJapaneseTitle)
        #expect(BookTitleDisplayMode.compactJapaneseTitle.next == .originalTitle)
    }

    @Test("cover theme color falls back without cover")
    func coverThemeColorFallsBackWithoutCover() {
        let book = LibraryBook(title: "No Cover", hash: "hash", filepath: "/tmp/no-cover.cbz")

        #expect(CoverThemeColorExtractor.themeColor(coverPath: "/tmp/missing-cover.jpg") == nil)
        #expect(CoverThemeColorExtractor.themeColor(for: book).isEqual(CoverThemeColorExtractor.fallbackColor))
    }

    @Test("cover theme color cache returns fallback then caches resolved color")
    func coverThemeColorCacheReturnsFallbackThenCachesResolvedColor() async {
        let counter = CoverThemeColorResolveCounter()
        let cache = CoverThemeColorCache { _ in
            counter.increment()
            return "#112233FF"
        }

        #expect(cache.fallbackColor(coverPath: "/tmp/cover.jpg").isEqual(CoverThemeColorExtractor.fallbackColor))
        let first = await cache.resolveColor(coverPath: "/tmp/cover.jpg")
        let second = await cache.resolveColor(coverPath: "/tmp/cover.jpg")

        #expect(!first.cacheHit)
        #expect(second.cacheHit)
        #expect(first.color.nyaehHexString == "#112233FF")
        #expect(second.color.nyaehHexString == "#112233FF")
        #expect(counter.value == 1)
    }

    @Test("metadata batch preferences default and persist")
    @MainActor
    func metadataBatchPreferencesDefaultAndPersist() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        #expect(preferences.metadataBatchIntervalStrategy == .random)
        #expect(preferences.metadataBatchMinDelaySeconds == 8)
        #expect(preferences.metadataBatchMaxDelaySeconds == 20)
        #expect(preferences.metadataBatchRetryCount == 2)
        #expect(preferences.metadataBatchLimit == 50)

        preferences.metadataBatchMinDelaySeconds = 13
        preferences.metadataBatchMaxDelaySeconds = 7
        preferences.metadataBatchRetryCount = 9
        preferences.metadataBatchLimit = 900

        let restored = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        #expect(restored.metadataBatchMinDelaySeconds == 12)
        #expect(restored.metadataBatchMaxDelaySeconds == 12)
        #expect(restored.metadataBatchRetryCount == 5)
        #expect(restored.metadataBatchLimit == 200)

        restored.metadataBatchMinDelaySeconds = 59
        restored.metadataBatchMaxDelaySeconds = 121
        #expect(restored.metadataBatchMinDelaySeconds == 60)
        #expect(restored.metadataBatchMaxDelaySeconds == 120)

        restored.metadataBatchLimit = 0
        #expect(restored.metadataBatchLimit == 0)
    }

    @Test("proxy preferences default persist and normalize")
    @MainActor
    func proxyPreferencesDefaultPersistAndNormalize() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        #expect(!preferences.isProxyEnabled)
        #expect(preferences.proxyType == .http)
        #expect(preferences.proxyHost.isEmpty)
        #expect(preferences.proxyPort == 7890)

        preferences.isProxyEnabled = true
        preferences.proxyType = .socks
        preferences.proxyHost = "127.0.0.1"
        preferences.proxyPort = 70_000

        let restored = AppPreferences(userDefaults: defaults, credentialStore: InMemoryCredentialStore())
        #expect(restored.isProxyEnabled)
        #expect(restored.proxyType == .socks)
        #expect(restored.proxyHost == "127.0.0.1")
        #expect(restored.proxyPort == 65_535)
        #expect(restored.proxySettings.isUsable)
    }

    @Test("default user defaults can use environment suite")
    @MainActor
    func defaultUserDefaultsCanUseEnvironmentSuite() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let defaults = AppPreferences.defaultUserDefaults(
            environment: [AppPreferences.userDefaultsSuiteEnvironmentKey: suiteName]
        )
        defaults.set(ThemeMode.dark.rawValue, forKey: "NyaEH.themeMode")

        let restored = UserDefaults(suiteName: suiteName)!
        #expect(restored.string(forKey: "NyaEH.themeMode") == ThemeMode.dark.rawValue)
    }

    @Test("development credential store reads writes and removes plaintext credentials")
    func developmentCredentialStoreReadsWritesAndRemovesPlaintextCredentials() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCredentialStore(appDataRoot: directory)

        #expect(try store.string(forKey: "missing") == "")

        try store.set("secret", forKey: "NyaEH.exhentai.igneous")
        #expect(try store.string(forKey: "NyaEH.exhentai.igneous") == "secret")
        let credentialsDirectory = directory.appendingPathComponent("Credentials", isDirectory: true)
        let credentialsFile = credentialsDirectory.appendingPathComponent("credentials.json")
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: credentialsDirectory.path)[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(atPath: credentialsFile.path)[.posixPermissions] as? NSNumber
        #expect(directoryPermissions?.intValue == 0o700)
        #expect(filePermissions?.intValue == 0o600)
        #expect(try FileCredentialStore(appDataRoot: directory).string(forKey: "NyaEH.exhentai.igneous") == "secret")
        #expect(try FileManager.default.contentsOfDirectory(atPath: credentialsDirectory.path) == ["credentials.json"])

        try store.removeValue(forKey: "NyaEH.exhentai.igneous")
        #expect(try store.string(forKey: "NyaEH.exhentai.igneous") == "")
    }

    @Test("credential write failures are reported")
    func credentialWriteFailureIsReported() {
        let store = FileCredentialStore(appDataRoot: URL(fileURLWithPath: "/dev/null/invalid"))
        #expect(throws: Error.self) { try store.set("secret", forKey: "token") }
    }

    @Test("credential store factory uses development plaintext when requested")
    func credentialStoreFactoryUsesDevelopmentPlaintextWhenRequested() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CredentialStoreFactory.appDefault(
            environment: [
                AppDataDirectory.overrideEnvironmentKey: directory.path,
                CredentialStoreFactory.environmentKey: CredentialStoreFactory.developmentPlaintextValue
            ]
        )

        #expect(store is FileCredentialStore)
    }

    @Test("credential store factory defaults to local file")
    func credentialStoreFactoryDefaultsToLocalFile() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CredentialStoreFactory.appDefault(environment: [AppDataDirectory.overrideEnvironmentKey: directory.path])

        #expect(store is FileCredentialStore)
    }

    @Test("credentials persist through credential store")
    @MainActor
    func credentialsPersistThroughCredentialStore() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let credentialStore = InMemoryCredentialStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = AppPreferences(userDefaults: defaults, credentialStore: credentialStore)
        preferences.exhentaiIgneous = "igneous-value"
        preferences.exhentaiIPBPassHash = "pass-hash"
        preferences.exhentaiIPBMemberID = "member-id"
        preferences.exhentaiStar = "star-value"

        let restored = AppPreferences(userDefaults: defaults, credentialStore: credentialStore)
        #expect(restored.exhentaiIgneous == "igneous-value")
        #expect(restored.exhentaiIPBPassHash == "pass-hash")
        #expect(restored.exhentaiIPBMemberID == "member-id")
        #expect(restored.exhentaiStar == "star-value")
        #expect(defaults.string(forKey: "NyaEH.exhentai.igneous") == nil)
    }

    @Test("legacy defaults are not read during file credential setup")
    @MainActor
    func legacyCredentialsAreNotReadDuringFileCredentialSetup() throws {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let credentialStore = FileCredentialStore(appDataRoot: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("old-igneous", forKey: "NyaEH.exhentai.igneous")

        let preferences = AppPreferences(userDefaults: defaults, credentialStore: credentialStore)

        #expect(preferences.exhentaiIgneous == "")
        #expect(try credentialStore.string(forKey: "NyaEH.exhentai.igneous") == "")
        #expect(defaults.string(forKey: "NyaEH.exhentai.igneous") == "old-igneous")
    }

    @Test("old credential keys are ignored")
    @MainActor
    func legacyUserDefaultsCredentialsAreIgnored() {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let credentialStore = InMemoryCredentialStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("old-igneous", forKey: "NyaEH.exhentai.igneous")
        defaults.set("old-pass-hash", forKey: "NyaEH.exhentai.ipbPassHash")
        defaults.set("old-member-id", forKey: "NyaEH.exhentai.ipbMemberID")
        defaults.set("old-star", forKey: "NyaEH.exhentai.star")

        let preferences = AppPreferences(userDefaults: defaults, credentialStore: credentialStore)

        #expect(preferences.exhentaiIgneous == "")
        #expect(preferences.exhentaiIPBPassHash == "")
        #expect(preferences.exhentaiIPBMemberID == "")
        #expect(preferences.exhentaiStar == "")
        #expect(defaults.string(forKey: "NyaEH.exhentai.igneous") == "old-igneous")
    }

    @Test("library root path persists through user defaults")
    @MainActor
    func libraryRootPathPersistsThroughUserDefaults() throws {
        let suiteName = TestPreferencesHelper.Suite.appPreferences
        TestPreferencesHelper.resetDomain(named: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let preferences = AppPreferences(userDefaults: defaults)
        try preferences.setLibraryRoot(url: directory)

        let restored = AppPreferences(userDefaults: defaults)
        #expect(restored.libraryRootPath == directory.path)
        #expect(restored.libraryRootBookmarkData != nil)
        #expect(
            try restored.resolvedLibraryRootURL()?.resolvingSymlinksInPath().path
                == directory.resolvingSymlinksInPath().path
        )
    }

    @Test("book detail top card grid uses three equal columns at wide widths")
    func bookDetailTopCardGridUsesThreeEqualColumnsAtWideWidths() {
        let spacing: CGFloat = 14
        let availableWidth: CGFloat = 1240
        let columns = BookDetailTopCardGridMetrics.columns(for: availableWidth, spacing: spacing)
        let columnWidth = BookDetailTopCardGridMetrics.columnWidth(
            availableWidth: availableWidth,
            columns: columns,
            spacing: spacing
        )

        #expect(columns == 3)
        #expect(abs(columnWidth * CGFloat(columns) + spacing * CGFloat(columns - 1) - availableWidth) < 0.001)
    }

    @Test("book detail top card grid uses two equal columns at medium widths")
    func bookDetailTopCardGridUsesTwoEqualColumnsAtMediumWidths() {
        let spacing: CGFloat = 14
        let availableWidth: CGFloat = 720
        let columns = BookDetailTopCardGridMetrics.columns(for: availableWidth, spacing: spacing)
        let columnWidth = BookDetailTopCardGridMetrics.columnWidth(
            availableWidth: availableWidth,
            columns: columns,
            spacing: spacing
        )

        #expect(columns == 2)
        #expect(abs(columnWidth * CGFloat(columns) + spacing * CGFloat(columns - 1) - availableWidth) < 0.001)
    }

    @Test("book detail top card grid falls back to one column at narrow widths")
    func bookDetailTopCardGridFallsBackToOneColumnAtNarrowWidths() {
        let availableWidth: CGFloat = 260
        let columns = BookDetailTopCardGridMetrics.columns(for: availableWidth)
        let columnWidth = BookDetailTopCardGridMetrics.columnWidth(
            availableWidth: availableWidth,
            columns: columns
        )

        #expect(columns == 1)
        #expect(columnWidth == availableWidth)
        #expect(columnWidth >= 0)
    }

    @Test("book detail tag flow rows stay within available width")
    func bookDetailTagFlowRowsStayWithinAvailableWidth() {
        let items = [
            BookDetailTagFlowMetrics.Item(index: 0, size: CGSize(width: 70, height: 28)),
            BookDetailTagFlowMetrics.Item(index: 1, size: CGSize(width: 82, height: 28)),
            BookDetailTagFlowMetrics.Item(index: 2, size: CGSize(width: 64, height: 28)),
            BookDetailTagFlowMetrics.Item(index: 3, size: CGSize(width: 96, height: 28))
        ]
        let rows = BookDetailTagFlowMetrics.rows(for: items, availableWidth: 170, spacing: 8)

        #expect(rows.count > 1)
        for row in rows {
            #expect(row.width <= 170)
        }
    }

    @Test("book detail sticky header progress clamps before threshold")
    func bookDetailStickyHeaderProgressClampsBeforeThreshold() {
        #expect(BookDetailStickyHeaderMetrics.progress(for: 0) == 0)
        #expect(BookDetailStickyHeaderMetrics.progress(for: -20) == 0)
        #expect(BookDetailStickyHeaderMetrics.progress(for: -.infinity) == 0)
    }

    @Test("book detail sticky header progress advances through collapse distance")
    func bookDetailStickyHeaderProgressAdvancesThroughCollapseDistance() {
        let midpoint = BookDetailStickyHeaderMetrics.startOffset
            + BookDetailStickyHeaderMetrics.collapseDistance / 2

        #expect(abs(BookDetailStickyHeaderMetrics.progress(for: midpoint) - 0.5) < 0.001)
    }

    @Test("book detail sticky header progress clamps after collapse distance")
    func bookDetailStickyHeaderProgressClampsAfterCollapseDistance() {
        let finalOffset = BookDetailStickyHeaderMetrics.startOffset
            + BookDetailStickyHeaderMetrics.collapseDistance

        #expect(BookDetailStickyHeaderMetrics.progress(for: finalOffset) == 1)
        #expect(BookDetailStickyHeaderMetrics.progress(for: finalOffset + 500) == 1)
        #expect(BookDetailStickyHeaderMetrics.progress(for: .infinity) == 0)
    }

    @Test("book detail sticky header presentation offset clamps after collapse")
    func bookDetailStickyHeaderPresentationOffsetClampsAfterCollapse() {
        let finalOffset = BookDetailStickyHeaderMetrics.startOffset
            + BookDetailStickyHeaderMetrics.collapseDistance

        #expect(BookDetailStickyHeaderMetrics.presentationOffset(for: -20) == BookDetailStickyHeaderMetrics.startOffset)
        #expect(BookDetailStickyHeaderMetrics.presentationOffset(for: 120) == 120)
        #expect(BookDetailStickyHeaderMetrics.presentationOffset(for: finalOffset + 500) == finalOffset)
        #expect(!BookDetailStickyHeaderMetrics.shouldPublishPresentationOffset(120.5, previous: 120))
        #expect(BookDetailStickyHeaderMetrics.shouldPublishPresentationOffset(121, previous: 120))
        #expect(BookDetailStickyHeaderMetrics.shouldPublishPresentationOffset(finalOffset, previous: finalOffset - 0.4))
    }

    @Test("book detail sticky header phase tracks collapsed state")
    func bookDetailStickyHeaderPhaseTracksCollapsedState() {
        let finalOffset = BookDetailStickyHeaderMetrics.startOffset
            + BookDetailStickyHeaderMetrics.collapseDistance

        #expect(BookDetailStickyHeaderMetrics.phase(for: 0) == .expanded)
        #expect(BookDetailStickyHeaderMetrics.phase(for: 120) == .collapsing)
        #expect(BookDetailStickyHeaderMetrics.phase(for: finalOffset) == .collapsed)
        #expect(BookDetailStickyHeaderMetrics.phase(for: finalOffset + 100) == .collapsed)
    }

    @Test("book detail hero motion returns expanded state at progress zero")
    func bookDetailHeroMotionReturnsExpandedStateAtProgressZero() {
        let layout = BookDetailHeroMotionMetrics.layout(containerWidth: 1400, scrollOffset: 0, progress: 0)

        #expect(layout.cardFrame.height == BookDetailHeroMotionMetrics.expandedCardHeight)
        #expect(layout.coverFrame.size == BookDetailHeroMotionMetrics.expandedCoverSize)
        #expect(layout.titleFrame.minY == layout.coverFrame.minY)
        #expect(layout.titleFrame.height == BookDetailHeroMotionMetrics.defaultExpandedTitleColumnHeight)
        #expect(layout.titleSize == BookDetailHeroMotionMetrics.expandedTitleSize)
        #expect(layout.titleLineLimit == nil)
        #expect(layout.secondaryOpacity == 1)
    }

    @Test("book detail hero motion returns collapsed state at progress one")
    func bookDetailHeroMotionReturnsCollapsedStateAtProgressOne() {
        let layout = BookDetailHeroMotionMetrics.layout(containerWidth: 1400, scrollOffset: 300, progress: 1)

        #expect(layout.cardFrame.height == BookDetailHeroMotionMetrics.collapsedCardHeight)
        #expect(layout.coverFrame.size == BookDetailHeroMotionMetrics.collapsedCoverSize)
        #expect(abs(layout.coverFrame.midY - layout.cardFrame.midY) < 0.001)
        #expect(layout.titleSize == BookDetailHeroMotionMetrics.collapsedTitleSize)
        #expect(layout.titleLineLimit == 1)
        #expect(layout.secondaryOpacity == 0)
    }

    @Test("book detail hero motion interpolates between expanded and collapsed states")
    func bookDetailHeroMotionInterpolatesBetweenExpandedAndCollapsedStates() {
        let layout = BookDetailHeroMotionMetrics.layout(containerWidth: 1400, scrollOffset: 110, progress: 0.5)

        #expect(layout.cardFrame.height < BookDetailHeroMotionMetrics.expandedCardHeight)
        #expect(layout.cardFrame.height > BookDetailHeroMotionMetrics.collapsedCardHeight)
        #expect(layout.coverFrame.width < BookDetailHeroMotionMetrics.expandedCoverSize.width)
        #expect(layout.coverFrame.width > BookDetailHeroMotionMetrics.collapsedCoverSize.width)
        #expect(layout.titleSize < BookDetailHeroMotionMetrics.expandedTitleSize)
        #expect(layout.titleSize > BookDetailHeroMotionMetrics.collapsedTitleSize)
    }

    @Test("book detail hero cover keeps one aspect ratio throughout collapse")
    func bookDetailHeroCoverKeepsOneAspectRatioThroughoutCollapse() {
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let layout = BookDetailHeroMotionMetrics.layout(
                containerWidth: 1400,
                scrollOffset: 220 * progress,
                progress: progress
            )
            let aspectRatio = layout.coverFrame.width / layout.coverFrame.height

            #expect(abs(aspectRatio - BookDetailHeroMotionMetrics.coverAspectRatio) < 0.000_001)
        }
    }

    @Test("book detail hero expanded category bottom aligns with content bottom")
    func bookDetailHeroExpandedCategoryBottomAlignsWithContentBottom() {
        let titleColumnHeight: CGFloat = 180
        let layout = BookDetailHeroMotionMetrics.layout(
            containerWidth: 1400,
            scrollOffset: 0,
            progress: 0,
            expandedTitleColumnHeight: titleColumnHeight
        )
        let contentBottom = layout.cardFrame.maxY - BookDetailHeroMotionMetrics.heroInnerPadding

        #expect(layout.categoryFrame.minX == layout.titleFrame.minX)
        #expect(abs(layout.categoryFrame.maxY - contentBottom) < 0.001)
    }

    @Test("book detail hero expanded card grows with tall title column")
    func bookDetailHeroExpandedCardGrowsWithTallTitleColumn() {
        let defaultHeight = BookDetailHeroMotionMetrics.expandedCardHeight(
            titleColumnHeight: BookDetailHeroMotionMetrics.defaultExpandedTitleColumnHeight
        )
        let tallTitleColumnHeight: CGFloat = 520
        let tallHeight = BookDetailHeroMotionMetrics.expandedCardHeight(titleColumnHeight: tallTitleColumnHeight)
        let layout = BookDetailHeroMotionMetrics.layout(
            containerWidth: 1400,
            scrollOffset: 0,
            progress: 0,
            expandedTitleColumnHeight: tallTitleColumnHeight
        )
        let expectedTallHeight = BookDetailHeroMotionMetrics.heroInnerPadding * 2
            + tallTitleColumnHeight
            + BookDetailHeroMotionMetrics.titleCategorySpacing
            + BookDetailHeroMotionMetrics.expandedCategoryHeight

        #expect(defaultHeight >= BookDetailHeroMotionMetrics.minimumExpandedCardHeight)
        #expect(tallHeight > defaultHeight)
        #expect(abs(tallHeight - expectedTallHeight) < 0.001)
        #expect(layout.cardFrame.height == tallHeight)
        #expect(layout.categoryFrame.maxY <= layout.cardFrame.maxY - BookDetailHeroMotionMetrics.heroInnerPadding + 0.001)
        #expect(layout.titleFrame.maxY + BookDetailHeroMotionMetrics.titleCategorySpacing <= layout.categoryFrame.minY + 0.001)
    }

    @Test("book detail hero collapsed category follows title column")
    func bookDetailHeroCollapsedCategoryFollowsTitleColumn() {
        let layout = BookDetailHeroMotionMetrics.layout(containerWidth: 1400, scrollOffset: 300, progress: 1)

        #expect(layout.categoryFrame.minX == layout.titleFrame.minX)
        #expect(layout.categoryFrame.minY > layout.titleFrame.maxY)
    }

    @Test("book detail hero motion content left centers capped content width")
    func bookDetailHeroMotionContentLeftCentersCappedContentWidth() {
        #expect(BookDetailHeroMotionMetrics.contentLeft(containerWidth: 1000) == 0)
        #expect(BookDetailHeroMotionMetrics.contentLeft(containerWidth: 1400) == 80)
        #expect(BookDetailHeroMotionMetrics.contentWidth(containerWidth: 2000) == BookDetailHeroMotionMetrics.maxContentWidth)
        #expect(BookDetailHeroMotionMetrics.contentRight(containerWidth: 1400) == 1320)
    }

    @Test("book detail hero motion title stays inside wide content bounds")
    func bookDetailHeroMotionTitleStaysInsideWideContentBounds() {
        let containerWidth: CGFloat = 2000
        let expanded = BookDetailHeroMotionMetrics.layout(containerWidth: containerWidth, scrollOffset: 0, progress: 0)
        let collapsed = BookDetailHeroMotionMetrics.layout(containerWidth: containerWidth, scrollOffset: 300, progress: 1)
        let contentRight = BookDetailHeroMotionMetrics.contentRight(containerWidth: containerWidth)
        let expandedTitleRight = contentRight
            - BookDetailHeroMotionMetrics.detailHorizontalPadding
            - BookDetailHeroMotionMetrics.heroInnerPadding
            - BookDetailHeroMotionMetrics.expandedTitleTrailingReservedWidth
        let collapsedTitleRight = contentRight
            - BookDetailHeroMotionMetrics.detailHorizontalPadding
            - BookDetailHeroMotionMetrics.stickyHeaderHorizontalPadding
            - BookDetailHeroMotionMetrics.collapsedTitleTrailingReservedWidth

        #expect(expanded.cardFrame.maxX <= contentRight - BookDetailHeroMotionMetrics.detailHorizontalPadding + 0.001)
        #expect(collapsed.cardFrame.maxX <= contentRight - BookDetailHeroMotionMetrics.detailHorizontalPadding + 0.001)
        #expect(expanded.titleFrame.maxX <= expandedTitleRight + 0.001)
        #expect(collapsed.titleFrame.maxX <= collapsedTitleRight + 0.001)
        #expect(expanded.categoryFrame.maxX <= contentRight - BookDetailHeroMotionMetrics.detailHorizontalPadding + 0.001)
        #expect(collapsed.categoryFrame.maxX <= contentRight - BookDetailHeroMotionMetrics.detailHorizontalPadding + 0.001)
        #expect(expanded.copyButtonFrame.maxX <= contentRight - BookDetailHeroMotionMetrics.detailHorizontalPadding + 0.001)
        #expect(collapsed.copyButtonFrame.maxX <= contentRight - BookDetailHeroMotionMetrics.detailHorizontalPadding + 0.001)
        #expect(expanded.readingButtonFrame.maxX <= contentRight - BookDetailHeroMotionMetrics.detailHorizontalPadding + 0.001)
        #expect(collapsed.readingButtonFrame.maxX <= contentRight - BookDetailHeroMotionMetrics.detailHorizontalPadding + 0.001)
        #expect(expanded.copyButtonFrame.maxX <= expanded.readingButtonFrame.minX)
        #expect(collapsed.copyButtonFrame.maxX <= collapsed.readingButtonFrame.minX)
    }

    @Test("book detail title mode hint uses title mode localization keys")
    func bookDetailTitleModeHintUsesTitleModeLocalizationKeys() {
        for mode in BookTitleDisplayMode.allCases {
            #expect(BookDetailTitleModeHint.titleKey(for: mode) == mode.titleKey)
        }
    }

    @Test("book detail reading action policy chooses start or continue")
    func bookDetailReadingActionPolicyChoosesStartOrContinue() {
        let unfinished = BookReadingState(
            bookID: 1,
            currentPageIndex: 12,
            totalPages: 42,
            updatedAt: 100,
            completedAt: nil
        )
        let completed = BookReadingState(
            bookID: 1,
            currentPageIndex: 41,
            totalPages: 42,
            updatedAt: 120,
            completedAt: 121
        )

        #expect(BookDetailReadingActionPolicy.titleKey(for: nil) == .readerStart)
        #expect(BookDetailReadingActionPolicy.initialPage(for: nil) == 0)
        #expect(BookDetailReadingActionPolicy.titleKey(for: completed) == .readerStart)
        #expect(BookDetailReadingActionPolicy.initialPage(for: completed) == 0)
        #expect(BookDetailReadingActionPolicy.titleKey(for: unfinished) == .readerContinue)
        #expect(BookDetailReadingActionPolicy.initialPage(for: unfinished) == 12)
    }
}

private final class InMemoryCredentialStore: CredentialStore {
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String {
        values[key] ?? ""
    }

    func set(_ value: String, forKey key: String) {
        values[key] = value
    }

    func removeValue(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

private final class CoverThemeColorResolveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
