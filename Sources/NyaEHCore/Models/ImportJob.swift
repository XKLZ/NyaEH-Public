// 本文件定义 ImportJob 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct ImportJob: Codable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var databaseID: DatabaseID?
    var sourcePath: String
    var status: ImportJobStatus
    var message: String?
    var createdAt: Date
    var updatedAt: Date
}

enum ImportJobStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}
