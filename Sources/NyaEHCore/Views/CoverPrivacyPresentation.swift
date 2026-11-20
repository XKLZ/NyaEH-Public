import SwiftUI

extension EnvironmentValues {
    // Background routes, departing transition layers and navigation-only covers must stay protected.
    @Entry var coverPrivacyRevealAllowed = true
}
