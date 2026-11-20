import Foundation
import Testing
@testable import NyaEHCore

@Suite("Cover privacy")
struct CoverPrivacyTests {
    @Test func perFieldInheritanceAndReset() {
        var settings = CoverPrivacyPreferences()
        #expect(settings.rule(for: .search) == CoverPrivacyRule(mode: .off, strength: 50, revealDelay: 1))
        settings.global = CoverPrivacyRule(mode: .blur, strength: 40, revealDelay: 1.25)
        settings[.search].revealDelay = -1
        settings[.home].mode = .conceal
        settings[.home].strength = 70
        settings.global.strength = 60
        #expect(settings.rule(for: .search) == CoverPrivacyRule(mode: .blur, strength: 60, revealDelay: -1))
        #expect(settings.rule(for: .home) == CoverPrivacyRule(mode: .conceal, strength: 70, revealDelay: 1.25))
        #expect(settings.rule(for: nil) == settings.global)
        settings[.search] = CoverPrivacyOverride()
        #expect(settings.rule(for: .search) == settings.global)
    }

    @Test @MainActor func restoresPreferencesOnReload() throws {
        let name = TestRunResources.newDefaultsDomain()
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func open() -> AppPreferences {
            AppPreferences(userDefaults: defaults, credentialStore: CoverPrivacyTestCredentials(),
                           applicationLanguageDefaults: defaults, applicationLanguageDomain: name)
        }
        let first = open()
        first.coverPrivacy.global = CoverPrivacyRule(mode: .blur, strength: 81, revealDelay: 0.5)
        first.coverPrivacy[.home].mode = .off
        first.coverPrivacy[.search].revealDelay = -1
        #expect(open().coverPrivacy == first.coverPrivacy)
    }

    @Test func immediateAndNever() {
        let now = ContinuousClock.now
        var state = CoverRevealState()
        let instant = context(delay: 0)
        let never = context(delay: -1)
        let immediateRequest = state.update(for: instant, hovered: true, allowed: true, now: now)
        #expect(immediateRequest == nil)
        #expect(state.isRevealed(for: instant))
        let neverRequest = state.update(for: never, hovered: true, allowed: true, now: now)
        #expect(neverRequest == nil)
        #expect(!state.isRevealed(for: never))
        let inactiveRequest = state.update(for: instant, hovered: true, allowed: false, now: now)
        #expect(inactiveRequest == nil)
        #expect(!state.isRevealed(for: instant))
    }

    @Test func onlyLatestUninterruptedHoverCanReveal() throws {
        let book = context(delay: 0.25)
        let now = ContinuousClock.now
        var state = CoverRevealState()
        let firstRequest = state.update(for: book, hovered: true, allowed: true, now: now)
        let first = try #require(firstRequest)
        state.complete(first, now: now.advanced(by: .milliseconds(249)))
        #expect(!state.isRevealed(for: book))
        _ = state.update(for: book, hovered: false, allowed: true, now: now.advanced(by: .milliseconds(249)))
        let secondRequest = state.update(for: book, hovered: true, allowed: true, now: first.deadline)
        let second = try #require(secondRequest)
        state.complete(first, now: first.deadline)
        #expect(!state.isRevealed(for: book))
        state.complete(second, now: second.deadline)
        #expect(state.isRevealed(for: book))
    }

    @Test func coverSwitchFocusLossAndRuleChangeInvalidateOldRequest() throws {
        let now = ContinuousClock.now
        let first = context(delay: 1)
        let second = context(delay: 1, book: "2")
        let repathed = context(delay: 1, book: "2", path: "new")
        let changed = context(delay: 2, book: "2", path: "new")
        var state = CoverRevealState()
        let firstWaitRequest = state.update(for: first, hovered: true, allowed: true, now: now)
        let firstWait = try #require(firstWaitRequest)
        state.complete(firstWait, now: firstWait.deadline)
        #expect(!state.isRevealed(for: second))
        let switchedRequest = state.update(for: second, hovered: true, allowed: true, now: firstWait.deadline)
        let switched = try #require(switchedRequest)
        let reloadedRequest = state.update(for: repathed, hovered: true, allowed: true, now: switched.deadline)
        let reloaded = try #require(reloadedRequest)
        state.complete(switched, now: switched.deadline)
        #expect(!state.isRevealed(for: repathed))
        let reconfiguredRequest = state.update(for: changed, hovered: true, allowed: true, now: reloaded.deadline)
        let reconfigured = try #require(reconfiguredRequest)
        state.complete(reloaded, now: reloaded.deadline)
        #expect(!state.isRevealed(for: changed))
        _ = state.update(for: changed, hovered: true, allowed: false, now: reconfigured.deadline)
        state.complete(reconfigured, now: reconfigured.deadline)
        #expect(!state.isRevealed(for: changed))
    }

    private func context(delay: Double, book: String = "1", path: String = "cover") -> CoverRevealContext {
        CoverRevealContext(bookID: book, path: path,
                           rule: CoverPrivacyRule(mode: .conceal, revealDelay: delay))
    }
}

private struct CoverPrivacyTestCredentials: CredentialStore {
    func string(forKey key: String) -> String { "" }
    func set(_ value: String, forKey key: String) {}
    func removeValue(forKey key: String) {}
}
