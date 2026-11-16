// 本文件定义 BookStatus 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum BookStatus: String, Codable, CaseIterable, Sendable {
    case unscanned
    case correct
    case broken
    case missing

    var titleKey: L10nKey {
        switch self {
        case .unscanned:
            return .unscanned
        case .correct:
            return .correct
        case .broken:
            return .broken
        case .missing:
            return .missing
        }
    }
}
