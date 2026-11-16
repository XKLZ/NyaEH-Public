import Foundation

/// Keeps the host application's AppleLanguages value as the only persisted language selection.
/// The legacy key is consumed once in the current host's domains.
struct AppLanguagePreferenceStore {
    static let legacyKey = LegacyNaming.languagePreference
    static let appleLanguagesKey = "AppleLanguages"

    let legacyDefaults: UserDefaults
    let applicationDefaults: UserDefaults
    let applicationDomain: String

    struct StartupState {
        let selected: AppLanguage
        let migrated: Bool
        let error: String?
    }

    func loadAndMigrate() -> StartupState {
        let currentValue = applicationDefaults.persistentDomain(forName: applicationDomain)?[Self.appleLanguagesKey]
        let currentSelection = (currentValue as? [String])?.first
            .flatMap(AppLanguage.fromLocalizationIdentifier) ?? .system
        guard let legacyValue = legacyDefaults.string(forKey: Self.legacyKey) else {
            return StartupState(selected: currentSelection, migrated: false, error: nil)
        }

        // An existing macOS per-app choice is already authoritative.
        if currentValue != nil {
            legacyDefaults.removeObject(forKey: Self.legacyKey)
            return StartupState(selected: currentSelection, migrated: false, error: nil)
        }

        guard let legacyLanguage = AppLanguage(rawValue: legacyValue), legacyLanguage != .system else {
            legacyDefaults.removeObject(forKey: Self.legacyKey)
            return StartupState(selected: .system, migrated: false, error: nil)
        }
        do {
            try save(legacyLanguage)
            legacyDefaults.removeObject(forKey: Self.legacyKey)
            return StartupState(selected: legacyLanguage, migrated: true, error: nil)
        } catch {
            return StartupState(selected: legacyLanguage, migrated: false, error: error.localizedDescription)
        }
    }

    func save(_ language: AppLanguage) throws {
        let prior = applicationDefaults.persistentDomain(forName: applicationDomain)?[Self.appleLanguagesKey]
        if let identifier = language.localizationIdentifier {
            applicationDefaults.set([identifier], forKey: Self.appleLanguagesKey)
        } else {
            applicationDefaults.removeObject(forKey: Self.appleLanguagesKey)
        }
        guard applicationDefaults.synchronize() else {
            if let prior { applicationDefaults.set(prior, forKey: Self.appleLanguagesKey) }
            else { applicationDefaults.removeObject(forKey: Self.appleLanguagesKey) }
            _ = applicationDefaults.synchronize()
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
