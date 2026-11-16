// 本文件定义 GalleryMetadata 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct GalleryMetadata: Identifiable, Codable, Equatable, Sendable {
    var hash: String
    var galleryID: Int64?
    var galleryToken: String?
    var title: String?
    var titleJpn: String?
    var status: BookStatus
    var rating: Double?
    var tags: String
    var pages: Int?
    var posted: Int64?
    var filesize: Int64?
    var category: String?
    var url: String?
    var createdAt: Int64
    var updatedAt: Int64

    var id: String { hash }

    init(
        hash: String,
        galleryID: Int64? = nil,
        galleryToken: String? = nil,
        title: String? = nil,
        titleJpn: String? = nil,
        status: BookStatus = .unscanned,
        rating: Double? = nil,
        tags: String = "[]",
        pages: Int? = nil,
        posted: Int64? = nil,
        filesize: Int64? = nil,
        category: String? = nil,
        url: String? = nil,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.hash = hash
        self.galleryID = galleryID
        self.galleryToken = galleryToken
        self.title = title
        self.titleJpn = titleJpn
        self.status = status
        self.rating = rating
        self.tags = tags
        self.pages = pages
        self.posted = posted
        self.filesize = filesize
        self.category = category
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
