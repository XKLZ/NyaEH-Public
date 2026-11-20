import Foundation
import Testing
@testable import NyaEHCore

struct AppLanguagePreferenceTests {
    @Test("all five languages persist in the host domain and activate on the next launch", arguments: AppLanguage.concreteLanguages)
    @MainActor
    func supportedLanguages(language: AppLanguage) {
        let (legacy, application, legacyDomain, domain) = isolatedDefaults()
        defer { clean(legacy, application, legacyDomain, domain) }

        let current = preferences(legacy, application, domain)
        let oldLanguage = current.localizer.language
        current.selectLanguage(language)
        #expect(current.language == language)
        #expect(current.localizer.language == oldLanguage)
        #expect(current.languageChangeRequiresRestart)
        #expect(application.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == [language.localizationIdentifier!])
        #expect(legacy.object(forKey: AppLanguagePreferenceStore.legacyKey) == nil)

        let relaunched = preferences(legacy, application, domain)
        #expect(relaunched.language == language)
        #expect(relaunched.localizer.language == language)
        #expect(!relaunched.languageChangeRequiresRestart)
    }

    @Test("system choice removes only the host override and remains pending until relaunch")
    @MainActor
    func systemChoice() {
        let (legacy, application, legacyDomain, domain) = isolatedDefaults()
        defer { clean(legacy, application, legacyDomain, domain) }
        application.set(["ja"], forKey: "AppleLanguages")
        let current = preferences(legacy, application, domain)
        #expect(current.language == .ja)
        current.selectLanguage(.system)
        #expect(current.language == .system)
        #expect(current.localizer.language == .ja)
        #expect(current.languageChangeRequiresRestart)
        #expect(application.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        let relaunched = preferences(legacy, application, domain)
        #expect(relaunched.language == .system)
        #expect(!relaunched.languageChangeRequiresRestart)
    }

    @Test("a legacy explicit language migrates once while a macOS app choice takes precedence")
    @MainActor
    func migration() {
        let (legacy, application, legacyDomain, domain) = isolatedDefaults()
        defer { clean(legacy, application, legacyDomain, domain) }
        legacy.set("zhHant", forKey: AppLanguagePreferenceStore.legacyKey)
        let migrated = preferences(legacy, application, domain)
        #expect(migrated.language == .zhHant)
        #expect(migrated.languageChangeRequiresRestart)
        #expect(legacy.object(forKey: AppLanguagePreferenceStore.legacyKey) == nil)
        #expect(application.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == ["zh-Hant"])
        #expect(!preferences(legacy, application, domain).languageChangeRequiresRestart)

        legacy.set("ko", forKey: AppLanguagePreferenceStore.legacyKey)
        application.set(["ja"], forKey: "AppleLanguages")
        let alreadyChosen = preferences(legacy, application, domain)
        #expect(alreadyChosen.language == .ja)
        #expect(!alreadyChosen.languageChangeRequiresRestart)
        #expect(legacy.object(forKey: AppLanguagePreferenceStore.legacyKey) == nil)
    }

    @Test("development and QA host language domains are isolated")
    @MainActor
    func hostIsolation() {
        let (devLegacy, devApplication, devLegacyDomain, devDomain) = isolatedDefaults()
        let (qaLegacy, qaApplication, qaLegacyDomain, qaDomain) = isolatedDefaults()
        defer {
            clean(devLegacy, devApplication, devLegacyDomain, devDomain)
            clean(qaLegacy, qaApplication, qaLegacyDomain, qaDomain)
        }
        preferences(devLegacy, devApplication, devDomain).selectLanguage(.ko)
        #expect(preferences(devLegacy, devApplication, devDomain).language == .ko)
        #expect(preferences(qaLegacy, qaApplication, qaDomain).language == .system)
        #expect(qaApplication.persistentDomain(forName: qaDomain)?["AppleLanguages"] == nil)
    }

    @Test("failed restart leaves the current application running")
    @MainActor
    func restartFailure() async {
        var terminated = false
        do {
            try await AppRelauncher.relaunch(
                bundleURL: URL(fileURLWithPath: "/tmp/NyaEHQA.app"),
                launch: { _ in false },
                terminate: { terminated = true }
            )
            Issue.record("Expected a restart failure")
        } catch {
            #expect(!terminated)
        }
    }

    private func isolatedDefaults() -> (UserDefaults, UserDefaults, String, String) {
        let legacyDomain = TestRunResources.newDefaultsDomain()
        let applicationDomain = TestRunResources.newDefaultsDomain()
        return (UserDefaults(suiteName: legacyDomain)!, UserDefaults(suiteName: applicationDomain)!, legacyDomain, applicationDomain)
    }

    private func clean(_ legacy: UserDefaults, _ application: UserDefaults, _ legacyDomain: String, _ domain: String) {
        application.removePersistentDomain(forName: domain)
        legacy.removePersistentDomain(forName: legacyDomain)
    }

    @MainActor
    private func preferences(_ legacy: UserDefaults, _ application: UserDefaults, _ domain: String) -> AppPreferences {
        AppPreferences(
            userDefaults: legacy,
            credentialStore: EmptyCredentialStore(),
            applicationLanguageDefaults: application,
            applicationLanguageDomain: domain
        )
    }
}

private struct EmptyCredentialStore: CredentialStore {
    func string(forKey key: String) -> String { "" }
    func set(_ value: String, forKey key: String) {}
    func removeValue(forKey key: String) {}
}
