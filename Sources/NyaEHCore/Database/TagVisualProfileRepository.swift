// 本文件定义 TagVisualProfileRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol TagVisualProfileRepository {
    func profiles(tagIDs: [Tag.DatabaseID]) throws -> [Tag.DatabaseID: TagVisualProfile]
    func profile(tagID: Tag.DatabaseID) throws -> TagVisualProfile?
    func upsert(_ profile: TagVisualProfile) throws -> TagVisualProfile
    func clearForegroundAsset(tagID: Tag.DatabaseID) throws -> TagVisualProfile?
    func clearBackgroundAsset(tagID: Tag.DatabaseID) throws -> TagVisualProfile?
}
