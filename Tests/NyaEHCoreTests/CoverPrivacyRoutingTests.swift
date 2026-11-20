import Testing
@testable import NyaEHCore

@Suite("Cover privacy navigation")
struct CoverPrivacyRoutingTests {
    @Test func pageFollowsTheDisplayedDestination() {
        #expect(CoverPrivacyPage.allCases == [.home, .search, .topic])
        #expect(CoverPrivacyPage(rawValue: "category") == .topic)
        #expect(LibraryDestination.tagCategory(.work).coverPrivacyPage == nil)
        #expect(LibraryDestination.home.coverPrivacyPage == .home)
        #expect(LibraryDestination.search.coverPrivacyPage == .search)
        #expect(LibraryDestination.favoriteManagement.coverPrivacyPage == nil)
        #expect(LibraryDestination.collectionManagement.coverPrivacyPage == nil)
        #expect(LibraryDestination.versionManagement.coverPrivacyPage == nil)
        #expect(LibraryDestination.importLibrary.coverPrivacyPage == nil)
        #expect(LibraryDestination.developmentTools.coverPrivacyPage == nil)
        #expect(LibraryRoute.collectionDetail("collection-1").coverPrivacyPage == nil)
        #expect(LibraryRoute.bookDetail("book").coverPrivacyPage == nil)
        #expect(LibraryRoute.workDetail(1).coverPrivacyPage == .topic)
        #expect(LibraryRoute.characterDetail(1).coverPrivacyPage == .topic)
    }
}
