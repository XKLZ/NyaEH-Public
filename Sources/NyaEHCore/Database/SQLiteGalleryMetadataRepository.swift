// 本文件实现 gallery_metadata 缓存读写，外部元数据按代表 hash 与本地书籍关联。

import Foundation
import GRDB

final class SQLiteGalleryMetadataRepository: GalleryMetadataRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetch(hash: String) throws -> GalleryMetadata? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT hash, gallery_id, gallery_token, title, title_jpn, status,
                           rating, tags, pages, posted, filesize, category, url,
                           created_at, updated_at
                    FROM gallery_metadata
                    WHERE hash = ?
                    """,
                arguments: [hash]
            )
            return row.map(Self.metadata(from:))
        }
    }

    func upsert(_ metadata: GalleryMetadata) throws -> GalleryMetadata {
        try dbQueue.write { db in
            var saved = metadata
            saved.updatedAt = Timestamp.nowMilliseconds()

            try db.execute(
                sql: """
                    INSERT INTO gallery_metadata (
                        hash, gallery_id, gallery_token, title, title_jpn, status,
                        rating, tags, pages, posted, filesize, category, url,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(hash) DO UPDATE SET
                        gallery_id = excluded.gallery_id,
                        gallery_token = excluded.gallery_token,
                        title = excluded.title,
                        title_jpn = excluded.title_jpn,
                        status = excluded.status,
                        rating = excluded.rating,
                        tags = excluded.tags,
                        pages = excluded.pages,
                        posted = excluded.posted,
                        filesize = excluded.filesize,
                        category = excluded.category,
                        url = excluded.url,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    saved.hash,
                    saved.galleryID,
                    saved.galleryToken,
                    saved.title,
                    saved.titleJpn,
                    saved.status.rawValue,
                    saved.rating,
                    saved.tags,
                    saved.pages,
                    saved.posted,
                    saved.filesize,
                    saved.category,
                    saved.url,
                    saved.createdAt,
                    saved.updatedAt
                ]
            )

            return saved
        }
    }

    func delete(hash: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM gallery_metadata WHERE hash = ?", arguments: [hash])
        }
    }

    static func metadata(from row: Row) -> GalleryMetadata {
        GalleryMetadata(
            hash: row["hash"],
            galleryID: row["gallery_id"],
            galleryToken: row["gallery_token"],
            title: row["title"],
            titleJpn: row["title_jpn"],
            status: BookStatus(rawValue: row["status"]) ?? .unscanned,
            rating: row["rating"],
            tags: row["tags"],
            pages: row["pages"],
            posted: row["posted"],
            filesize: row["filesize"],
            category: row["category"],
            url: row["url"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
