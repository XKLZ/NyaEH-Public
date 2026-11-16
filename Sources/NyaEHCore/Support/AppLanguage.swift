// 本文件提供 AppLanguage 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans
    case zhHant
    case ja
    case ko
    case en

    var id: String { rawValue }

    static let concreteLanguages: [AppLanguage] = [.zhHans, .zhHant, .ja, .ko, .en]

    var localizationIdentifier: String? {
        switch self {
        case .system: nil
        case .zhHans: "zh-Hans"
        case .zhHant: "zh-Hant"
        case .ja: "ja"
        case .ko: "ko"
        case .en: "en"
        }
    }

    static func fromLocalizationIdentifier(_ identifier: String) -> AppLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw")
            || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") { return .zhHant }
        if normalized.hasPrefix("zh") { return .zhHans }
        if normalized.hasPrefix("ja") { return .ja }
        if normalized.hasPrefix("ko") { return .ko }
        if normalized.hasPrefix("en") { return .en }
        return nil
    }

    var titleKey: L10nKey {
        switch self {
        case .system:
            return .languageSystem
        case .zhHans:
            return .languageSimplifiedChinese
        case .zhHant:
            return .languageTraditionalChinese
        case .ja:
            return .languageJapanese
        case .ko:
            return .languageKorean
        case .en:
            return .languageEnglish
        }
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .system:
            return Self.resolveSystemLanguage(preferredLanguages: preferredLanguages)
        case .zhHans, .zhHant, .ja, .ko, .en:
            return self
        }
    }

    static func resolveSystemLanguage(preferredLanguages: [String]) -> AppLanguage {
        for language in preferredLanguages {
            let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()

            if normalized.hasPrefix("zh-hant")
                || normalized.hasPrefix("zh-tw")
                || normalized.hasPrefix("zh-hk")
                || normalized.hasPrefix("zh-mo") {
                return .zhHant
            }

            if normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh") {
                return .zhHans
            }

            if normalized.hasPrefix("ja") {
                return .ja
            }

            if normalized.hasPrefix("ko") {
                return .ko
            }

            if normalized.hasPrefix("en") {
                return .en
            }
        }

        return .en
    }
}
