// 本文件提供 NyaEHError 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation

enum NyaEHError: LocalizedError {
    case missingDatabaseDirectory
    case bookHasNoID
    case unreadableArchive(String)
    case libraryFolderPermissionRequired
    case archiveContainsNoImages
    case tagTranslationRepositoryUnavailable
    case tagVisualProfileRepositoryUnavailable
    case tagVisualAssetInvalid
    case tagVisualDropImageUnavailable
    case tagTranslationManifestMissing
    case tagTranslationArchiveInvalid
    case versionSeriesConflict
    case groupingRepositoryUnavailable
    case importUnavailable
    case importFileMissing(String)
    case importInvalidSource(String)
    case sourceFileMissing(String)
    case coverVectorStorageUnavailable
    case coverVectorSchemaMismatch
    case coverVectorCoverMissing
    case coverVectorGenerationFailed
    case coverVectorElementTypeUnsupported
    case semanticTitleStorageUnavailable
    case semanticTitleSchemaMismatch
    case semanticTitleModelUnavailable
    case semanticTitleAssetsUnavailable
    case semanticTitleVectorGenerationFailed
    case databaseMaintenanceUnavailable
    case databaseInvariantViolation(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabaseDirectory:
            "Unable to locate the Application Support directory."
        case .bookHasNoID:
            "The book record has no database ID."
        case .unreadableArchive(let path):
            "Unable to read archive: \(path)"
        case .libraryFolderPermissionRequired:
            "Library folder access is not available. Re-select the library folder in Settings, then try loading the reader again."
        case .archiveContainsNoImages:
            "The archive contains no supported image files."
        case .tagTranslationRepositoryUnavailable:
            "Tag translation storage is unavailable."
        case .tagVisualProfileRepositoryUnavailable:
            "Tag visual profile storage is unavailable."
        case .tagVisualAssetInvalid:
            "The selected tag image could not be read."
        case .tagVisualDropImageUnavailable:
            "The dropped item did not contain a readable image."
        case .tagTranslationManifestMissing:
            "Tag translation manifest is missing."
        case .tagTranslationArchiveInvalid:
            "The tag translation JSON database did not contain readable translations."
        case .versionSeriesConflict:
            "These versions belong to different series. Choose one series for the versions before combining them."
        case .groupingRepositoryUnavailable:
            "Library grouping storage is unavailable."
        case .importUnavailable:
            "External import storage is unavailable."
        case .importFileMissing(let filename):
            "The import folder is missing \(filename)."
        case .importInvalidSource(let message):
            "The import source is invalid: \(message)"
        case .sourceFileMissing(let path):
            "The source file is missing: \(path)"
        case .coverVectorStorageUnavailable:
            "Cover vector storage is unavailable."
        case .coverVectorSchemaMismatch:
            "Cover vector storage uses an incompatible feature shape. Rebuild the cover vector database."
        case .coverVectorCoverMissing:
            "The cached cover image is missing."
        case .coverVectorGenerationFailed:
            "Unable to generate a cover feature print."
        case .coverVectorElementTypeUnsupported:
            "The cover feature print format is unsupported."
        case .semanticTitleStorageUnavailable:
            "Semantic title vector storage is unavailable."
        case .semanticTitleSchemaMismatch:
            "Semantic title vectors use an incompatible model profile. Rebuild the semantic title index."
        case .semanticTitleModelUnavailable:
            "The system CJK contextual embedding model is unavailable."
        case .semanticTitleAssetsUnavailable:
            "The CJK contextual embedding assets are not downloaded."
        case .semanticTitleVectorGenerationFailed:
            "Unable to generate a semantic title vector."
        case .databaseMaintenanceUnavailable:
            "Database maintenance is unavailable."
        case .databaseInvariantViolation(let message):
            "Database invariant violation: \(message)"
        }
    }
}
