// 本文件定义 CollectionRecommendationRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol CollectionRecommendationRepository {
    func fetchPending(
        kind: CollectionRecommendationKind,
        targetCollectionID: BookCollection.DatabaseID?
    ) throws -> [CollectionRecommendation]
    func fetchPendingAddToCollectionCounts() throws -> [BookCollection.DatabaseID: Int]
    func fetchMemberBookIDs(recommendationID: CollectionRecommendation.DatabaseID) throws -> [LibraryBook.DatabaseID]
    func pendingCount(involving bookIDs: Set<LibraryBook.DatabaseID>) throws -> Int
    func resetDismissed(involving bookID: LibraryBook.DatabaseID) throws
    func fetchDismissedCreateDecisions() throws -> [CollectionRecommendationDecisionSnapshot]
    func replacePending(with candidates: [CollectionRecommendationCandidate]) throws
    func mergePendingIncremental(
        with candidates: [CollectionRecommendationCandidate],
        affectedBookIDs: Set<LibraryBook.DatabaseID>,
        affectedCollectionIDs: Set<BookCollection.DatabaseID>
    ) throws
    func updateStatus(recommendationID: CollectionRecommendation.DatabaseID, status: CollectionRecommendationStatus) throws
    func latestRefreshCompletedAt() throws -> Int64?
}
