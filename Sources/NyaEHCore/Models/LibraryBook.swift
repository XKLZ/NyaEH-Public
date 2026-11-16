// 本文件定义 LibraryBook 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct LibraryBook: Identifiable, Codable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var databaseID: DatabaseID?
    var title: String
    var coverPath: String?
    var hash: String
    var filepath: String
    var type: BookType
    var fileCount: Int?
    var bundleSize: Int64?
    var mtime: Int64?
    var coverHash: String?
    var status: BookStatus
    var date: Int64
    var rating: Double?
    var tags: String
    var titleJpn: String?
    var pages: Int?
    var posted: Int64?
    var filesize: Int64?
    var category: String?
    var url: String?
    var collectionID: Int64?
    var collectionOrder: Int?
    var versionGroupID: Int64?
    var isPrimaryVersion: Bool
    var versionLabel: String?
    var languageCode: String
    var isTranslated: Bool
    var isFullColor: Bool
    var censorship: String
    var hasExtraneousAds: Bool
    var mark: Bool
    var hiddenBook: Bool
    var isUserHidden: Bool
    var readCount: Int
    var lastReadAt: Int64?
    var exist: Bool
    var createdAt: Int64
    var updatedAt: Int64

    var id: String {
        databaseID.map(String.init) ?? filepath
    }

    init(
        databaseID: DatabaseID? = nil,
        title: String,
        coverPath: String? = nil,
        hash: String,
        filepath: String,
        type: BookType = .unknown,
        fileCount: Int? = nil,
        bundleSize: Int64? = nil,
        mtime: Int64? = nil,
        coverHash: String? = nil,
        status: BookStatus = .unscanned,
        date: Int64 = Timestamp.nowMilliseconds(),
        rating: Double? = nil,
        tags: String = "[]",
        titleJpn: String? = nil,
        pages: Int? = nil,
        posted: Int64? = nil,
        filesize: Int64? = nil,
        category: String? = nil,
        url: String? = nil,
        collectionID: Int64? = nil,
        collectionOrder: Int? = nil,
        versionGroupID: Int64? = nil,
        isPrimaryVersion: Bool = true,
        versionLabel: String? = nil,
        languageCode: String = "unknown",
        isTranslated: Bool = false,
        isFullColor: Bool = false,
        censorship: String = "unknown",
        hasExtraneousAds: Bool = false,
        mark: Bool = false,
        hiddenBook: Bool = false,
        isUserHidden: Bool = false,
        readCount: Int = 0,
        lastReadAt: Int64? = nil,
        exist: Bool = true,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.databaseID = databaseID
        self.title = title
        self.coverPath = coverPath
        self.hash = hash
        self.filepath = filepath
        self.type = type
        self.fileCount = fileCount
        self.bundleSize = bundleSize
        self.mtime = mtime
        self.coverHash = coverHash
        self.status = status
        self.date = date
        self.rating = rating
        self.tags = tags
        self.titleJpn = titleJpn
        self.pages = pages
        self.posted = posted
        self.filesize = filesize
        self.category = category
        self.url = url
        self.collectionID = collectionID
        self.collectionOrder = collectionOrder
        self.versionGroupID = versionGroupID
        self.isPrimaryVersion = isPrimaryVersion
        self.versionLabel = versionLabel
        self.languageCode = languageCode
        self.isTranslated = isTranslated
        self.isFullColor = isFullColor
        self.censorship = censorship
        self.hasExtraneousAds = hasExtraneousAds
        self.mark = mark
        self.hiddenBook = hiddenBook
        self.isUserHidden = isUserHidden
        self.readCount = readCount
        self.lastReadAt = lastReadAt
        self.exist = exist
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
