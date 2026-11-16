import Testing
@testable import NyaEHCore

@Suite("Floating pagination presentation")
struct FloatingPaginationPresentationTests {
    @Test("pagination is hidden only when there are no items")
    func paginationVisibility() {
        #expect(!FloatingPaginationPresentation.showsPagination(itemCount: 0))
        #expect(!FloatingPaginationPresentation.showsPagination(itemCount: -1))
        #expect(FloatingPaginationPresentation.showsPagination(itemCount: 1))
        #expect(FloatingPaginationPresentation.showsPagination(itemCount: 100))
    }
}
