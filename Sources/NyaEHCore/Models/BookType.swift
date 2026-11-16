// 本文件定义 BookType 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum BookType: String, Codable, CaseIterable, Sendable {
    case archive
    case folder
    case unknown

    var titleKey: L10nKey {
        switch self {
        case .archive:
            return .archive
        case .folder:
            return .folder
        case .unknown:
            return .unknownType
        }
    }
}
