// 本文件定义跨扫描、导入和索引任务共享的展示快照。

import Foundation

enum LibraryTaskKind: String, Identifiable, Sendable {
    case scan
    case metadata
    case importPipeline
    case externalImport
    case workCharacterIndex
    case collectionRecommendations
    case versionRecommendations
    case coverVectors
    case semanticTitleVectors
    case tagTranslations
    case lastFailure

    var id: String { rawValue }
}

enum LibraryTaskRunState: Sendable {
    case running
    case paused
    case completed
    case failed
}

struct LibraryTaskSnapshot: Identifiable, Sendable {
    var kind: LibraryTaskKind
    var title: String
    var detail: String?
    var state: LibraryTaskRunState
    var fractionCompleted: Double?
    var canPause = false
    var canResume = false
    var canCancel = false

    var id: String { kind.id }
}

struct LibraryTaskFailure: Sendable {
    var kind: LibraryTaskKind
    var title: String
    var detail: String
    var canRetry: Bool
}
