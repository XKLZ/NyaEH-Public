import Foundation

struct LibraryDeletionOperation: Sendable {
    var bookID: Int64
    var sourcePath: String
    var sourceIdentity: String?
    var coverPath: String?
    var stage: String
    var error: String?
}

struct LibraryDeletionResult: Sendable {
    var bookID: Int64
    var cleanupWarning: String?
}

enum LibraryDeletionError: LocalizedError {
    case unavailable, sourceChanged, uncertain, staleRecommendation, bookUnavailable, commitPending
    var errorDescription: String? {
        switch self {
        case .unavailable: "删除服务不可用。"
        case .sourceChanged: "源文件已经变化，未移动文件。请重新扫描并确认后重试。"
        case .uncertain: "上次移动文件的结果不明确。请检查原文件和废纸篓，再重试删除。"
        case .staleRecommendation: "此推荐已失效，请刷新推荐列表。"
        case .bookUnavailable: "书籍已删除或正在删除，操作已停止。"
        case .commitPending: "文件已移到废纸篓，书库清理待重试。"
        }
    }
}

protocol LibraryDeletionRepository {
    func deletionOperation(bookID: Int64) throws -> LibraryDeletionOperation?
    func deletionOperations() throws -> [LibraryDeletionOperation]
    func prepareDeletion(bookID: Int64, identity: String?) throws -> LibraryDeletionOperation
    func updateDeletion(bookID: Int64, stage: String, error: String?) throws
    func commitDeletion(bookID: Int64) throws
    func finishDeletion(bookID: Int64) throws
}
