import Foundation

enum TestPreferencesHelper {
    /// Fixed suite names to avoid creating UUID-based plist files in ~/Library/Preferences/.
    /// Reusing the same suite across runs means no garbage accumulation.
    enum Suite {
        static let appPreferences = "com.nyaeh.test.preferences"
        static let localHighlight = "com.nyaeh.test.localhighlight"
        static let localHighlightController = "com.nyaeh.test.localhighlight-controller"
    }

    /// Reset a UserDefaults persistent domain to a clean state before a test runs.
    static func resetDomain(named suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}
