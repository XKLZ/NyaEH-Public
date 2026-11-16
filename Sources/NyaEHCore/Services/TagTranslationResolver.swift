// 本文件把原始标签和本地翻译缓存合成为界面展示摘要，供详情页、搜索和分类页复用。

import Foundation

struct TagTranslationResolver {
    let repository: any TagRepository
    let languageCode: String

    init(
        repository: any TagRepository,
        languageCode: String = EhTagTranslationCache.languageCode
    ) {
        self.repository = repository
        self.languageCode = languageCode
    }

    func resolvedName(for tag: Tag) throws -> String {
        try repository.translation(for: tag, languageCode: languageCode)?.translatedName ?? tag.name
    }

    func resolvedName(for tag: Tag, isEnabled: Bool) throws -> String {
        guard isEnabled else {
            return tag.name
        }

        return try resolvedName(for: tag)
    }

    func resolvedTranslation(for tag: Tag) throws -> TagResolvedTranslation? {
        try repository.translation(for: tag, languageCode: languageCode)
    }

    func resolvedTranslation(for tag: Tag, isEnabled: Bool) throws -> TagResolvedTranslation? {
        guard isEnabled else {
            return nil
        }

        return try resolvedTranslation(for: tag)
    }
}
