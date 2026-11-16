// 本文件定义 TagVisualProfile 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct TagVisualProfile: Equatable, Codable, Sendable {
    var tagID: Tag.DatabaseID
    var foregroundAssetPath: String?
    var foregroundScale: Double
    var foregroundOffsetX: Double
    var foregroundOffsetY: Double
    var backgroundAssetPath: String?
    var backgroundScale: Double
    var backgroundOffsetX: Double
    var backgroundOffsetY: Double
    var backgroundColorHex: String?
    var backgroundColorSource: TagVisualBackgroundColorSource
    var createdAt: Int64
    var updatedAt: Int64

    init(
        tagID: Tag.DatabaseID,
        foregroundAssetPath: String? = nil,
        foregroundScale: Double = 1,
        foregroundOffsetX: Double = 0,
        foregroundOffsetY: Double = 0,
        backgroundAssetPath: String? = nil,
        backgroundScale: Double = 1,
        backgroundOffsetX: Double = 0,
        backgroundOffsetY: Double = 0,
        backgroundColorHex: String? = nil,
        backgroundColorSource: TagVisualBackgroundColorSource = .generated,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.tagID = tagID
        self.foregroundAssetPath = foregroundAssetPath
        self.foregroundScale = foregroundScale
        self.foregroundOffsetX = foregroundOffsetX
        self.foregroundOffsetY = foregroundOffsetY
        self.backgroundAssetPath = backgroundAssetPath
        self.backgroundScale = backgroundScale
        self.backgroundOffsetX = backgroundOffsetX
        self.backgroundOffsetY = backgroundOffsetY
        self.backgroundColorHex = backgroundColorHex
        self.backgroundColorSource = backgroundColorSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func empty(tagID: Tag.DatabaseID) -> TagVisualProfile {
        TagVisualProfile(tagID: tagID)
    }
}

enum TagVisualBackgroundColorSource: String, Codable, Sendable {
    case generated
    case image
    case manual
}

struct StoredTagVisualAsset: Equatable, Sendable {
    var relativePath: String
    var themeColorHex: String?
}

enum TagVisualDropImportKind: Sendable {
    case foreground
    case background
}

struct TagVisualAssetTarget: Hashable, Sendable {
    var tagID: Tag.DatabaseID
    var namespace: String
    var name: String
    var rawValue: String
}
