// 本文件定义 VersionRecommendationRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol VersionRecommendationRepository {
    func fetchPending(kind: VersionRecommendationKind, targetVersionGroupID: BookVersionGroup.DatabaseID?) throws -> [VersionRecommendation]
    func fetchPendingAddToGroupCounts() throws -> [BookVersionGroup.DatabaseID: Int]
    func fetchMemberBookIDs(recommendationID: VersionRecommendation.DatabaseID) throws -> [LibraryBook.DatabaseID]
    func pendingCount(involving bookIDs: Set<LibraryBook.DatabaseID>) throws -> Int
    func resetDismissed(involving bookID: LibraryBook.DatabaseID) throws
    func replacePending(with candidates: [VersionRecommendationCandidate]) throws
    func mergePendingIncremental(
        with candidates: [VersionRecommendationCandidate],
        affectedBookIDs: Set<LibraryBook.DatabaseID>,
        affectedVersionGroupIDs: Set<BookVersionGroup.DatabaseID>
    ) throws
    func updateStatus(recommendationID: VersionRecommendation.DatabaseID, status: VersionRecommendationStatus) throws
    func latestRefreshCompletedAt() throws -> Int64?
}
