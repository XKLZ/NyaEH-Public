// 本文件定义 GalleryMetadataRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol GalleryMetadataRepository {
    func fetch(hash: String) throws -> GalleryMetadata?
    func upsert(_ metadata: GalleryMetadata) throws -> GalleryMetadata
    func delete(hash: String) throws
}
