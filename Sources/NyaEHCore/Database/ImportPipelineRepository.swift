// 本文件定义导入流水线持久化边界。

import Foundation

protocol ImportPipelineRepository {
    func recoverInterruptedWork() throws
    func reconcile(books: [LibraryBook]) throws
    func createBatchFromPendingItems() throws -> ImportPipelineBatch?
    func fetchActiveBatch() throws -> ImportPipelineBatch?
    func fetchItems(batchID: ImportPipelineBatch.ID) throws -> [ImportPipelineItem]
    func fetchAllItems() throws -> [ImportPipelineItem]
    func fetchItem(bookID: LibraryBook.DatabaseID) throws -> ImportPipelineItem?
    func updateBatch(_ batch: ImportPipelineBatch) throws
    func updateItem(_ item: ImportPipelineItem) throws
}
