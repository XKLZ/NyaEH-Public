import Foundation

enum LegacyNaming {
    static let applicationSupportDirectory = "TreeC"
    static let databaseFilename = "TreeC.sqlite"
    static let languagePreference = "TreeC.language"
    private static let oldPrefix = "TreeC."
    private static let newPrefix = "NyaEH."
    private static let migrationKey = "NyaEH.preferences.namesMigrated"

    static func migratePreferences(in defaults: UserDefaults, domain: String) {
        guard let values = defaults.persistentDomain(forName: domain),
              values[migrationKey] as? Bool != true else { return }
        for (key, value) in values where key.hasPrefix(oldPrefix) && key != languagePreference {
            let suffix = key.dropFirst(oldPrefix.count)
            // Credentials in old defaults were intentionally never imported.
            guard !suffix.hasPrefix("exhentai."), !suffix.hasPrefix("github.") else { continue }
            let newKey = newPrefix + suffix
            if values[newKey] == nil { defaults.set(value, forKey: newKey) }
        }
        defaults.set(true, forKey: migrationKey)
    }

    static func oldCredentialKey(for key: String) -> String? {
        guard key.hasPrefix(newPrefix) else { return nil }
        let suffix = key.dropFirst(newPrefix.count)
        guard suffix.hasPrefix("exhentai.") || suffix == "github.updateToken" else { return nil }
        return oldPrefix + suffix
    }
}
