import SwiftUI

struct CoverPrivacySettings: View {
    @Bindable var preferences: AppPreferences
    let localizer: AppLocalizer
    @State private var page: CoverPrivacyPage?

    private var effective: CoverPrivacyRule { preferences.coverPrivacy.rule(for: page) }

    var body: some View {
        Section(localizer.string(.coverPrivacy)) {
            Picker(localizer.string(.coverPrivacyScope), selection: $page) {
                Text(localizer.string(.coverPrivacyGlobal)).tag(CoverPrivacyPage?.none)
                ForEach(CoverPrivacyPage.allCases, id: \.self) { scope in
                    Text(localizer.string(scope.titleKey)).tag(Optional(scope))
                }
            }
            Picker(localizer.string(.coverPrivacyMode), selection: modeBinding) {
                if page != nil { Text(localizer.string(.coverPrivacyInherit)).tag(CoverPrivacyMode?.none) }
                ForEach(CoverPrivacyMode.allCases, id: \.self) { mode in
                    Text(localizer.string(mode.titleKey)).tag(Optional(mode))
                }
            }
            if effective.mode == .blur {
                let inherited = page.map { preferences.coverPrivacy[$0].strength == nil } ?? false
                if let page {
                    Toggle(localizer.string(.coverPrivacyInheritStrength), isOn: Binding {
                        preferences.coverPrivacy[page].strength == nil
                    } set: { inherit in
                        preferences.coverPrivacy[page].strength = inherit ? nil : effective.strength
                    })
                }
                LabeledContent(localizer.string(.coverPrivacyStrength)) {
                    Slider(value: Binding {
                        Double(effective.strength)
                    } set: { value in
                        if let page { preferences.coverPrivacy[page].strength = Int(value.rounded()) }
                        else { preferences.coverPrivacy.global.strength = Int(value.rounded()) }
                    }, in: 1...100, step: 1)
                    .frame(maxWidth: 150)
                    .accessibilityLabel(localizer.string(.coverPrivacyStrength))
                    .disabled(inherited)
                    Text(effective.strength, format: .number).monospacedDigit()
                }
            }
            Picker(localizer.string(.coverPrivacyReveal), selection: delayChoice) {
                if page != nil { Text(localizer.string(.coverPrivacyInherit)).tag(DelayChoice.inherit) }
                Text(localizer.string(.coverPrivacyAfter)).tag(DelayChoice.after)
                Text(localizer.string(.coverPrivacyNever)).tag(DelayChoice.never)
            }
            if effective.revealDelay >= 0 {
                HStack {
                    Text(localizer.string(.coverPrivacySeconds))
                    Spacer()
                    TextField(localizer.string(.coverPrivacySeconds), value: Binding {
                        effective.revealDelay
                    } set: { value in
                        guard value.isFinite, value == -1 || value >= 0,
                              value < Double(Int64.max) / 1_000_000_000 else { return }
                        setDelay(value)
                    }, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(localizer.string(.coverPrivacySeconds))
                    .accessibilityIdentifier("coverPrivacy.seconds")
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .disabled(delayChoice.wrappedValue == .inherit)
                }
            }
            if let page {
                Button(localizer.string(.coverPrivacyResetPage)) {
                    preferences.coverPrivacy[page] = CoverPrivacyOverride()
                }
                .disabled(preferences.coverPrivacy[page] == CoverPrivacyOverride())
            }
            LabeledContent(localizer.string(.coverPrivacyPreview)) {
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach([48, 100], id: \.self) { width in
                        sample(width: CGFloat(width))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(localizer.string(.coverPrivacyPreview))
                            .accessibilityIdentifier("coverPrivacy.sample.\(width)")
                    }
                }
            }
        }
    }

    private var modeBinding: Binding<CoverPrivacyMode?> {
        Binding {
            if let page { return preferences.coverPrivacy[page].mode }
            return preferences.coverPrivacy.global.mode
        } set: { mode in
            if let page { preferences.coverPrivacy[page].mode = mode }
            else if let mode { preferences.coverPrivacy.global.mode = mode }
        }
    }

    private enum DelayChoice: Hashable { case inherit, after, never }

    private var delayChoice: Binding<DelayChoice> {
        Binding {
            if let page, preferences.coverPrivacy[page].revealDelay == nil { return .inherit }
            return effective.revealDelay == CoverPrivacyRule.never ? .never : .after
        } set: { choice in
            switch choice {
            case .inherit:
                if let page { preferences.coverPrivacy[page].revealDelay = nil }
            case .after: setDelay(effective.revealDelay < 0 ? 1 : effective.revealDelay)
            case .never: setDelay(CoverPrivacyRule.never)
            }
        }
    }

    private func setDelay(_ value: Double) {
        if let page { preferences.coverPrivacy[page].revealDelay = value }
        else { preferences.coverPrivacy.global.revealDelay = value }
    }

    @ViewBuilder
    private func sample(width: CGFloat) -> some View {
        let height = width * 1.3
        let rule = effective
        let illustration = ZStack {
            LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "mountain.2.fill")
                .font(.system(size: width * 0.55))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: 5))
        if rule.mode == .off {
            illustration
        } else {
            CoverPrivacySurface(context: CoverRevealContext(bookID: page?.rawValue ?? "global", path: nil, rule: rule),
                                width: width, height: height, cornerRadius: 5) { illustration }
        }
    }
}
