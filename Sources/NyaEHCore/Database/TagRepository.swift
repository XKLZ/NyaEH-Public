// 本文件定义 TagRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol TagRepository {
    func rebuildTags(forBookID bookID: LibraryBook.DatabaseID, tagsJSON: String) throws
    func rebuildAllTags(from books: [LibraryBook]) throws
    func indexedBookTagCount() throws -> Int
    func summaries(namespace: String?) throws -> [TagSummary]
    func summaries(namespace: String?, languageCode: String?) throws -> [TagSummary]
    func topSummaries(namespaces: [String], limit: Int, languageCode: String?) throws -> [TagSummary]
    func tags(forBookID bookID: LibraryBook.DatabaseID) throws -> [Tag]
    func bookIDs(namespace: String, name: String) throws -> [LibraryBook.DatabaseID]
    func followedTagIDs() throws -> Set<Tag.DatabaseID>
    func setFollowed(tagID: Tag.DatabaseID, isFollowed: Bool) throws
    func upsertTranslation(tagID: Tag.DatabaseID, languageCode: String, translatedName: String) throws
    func fetchAllTags() throws -> [Tag]
    func materializeTranslations(
        _ translations: [ExternalTagTranslation],
        languageCode: String,
        source: String,
        sourceRevision: String
    ) throws -> Int
    func translation(for tag: Tag, languageCode: String) throws -> TagResolvedTranslation?
}
