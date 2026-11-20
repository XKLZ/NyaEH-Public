import Foundation

enum CoverPrivacyMode: String, CaseIterable, Codable, Sendable {
    case off, blur, conceal

    var titleKey: L10nKey {
        switch self {
        case .off: .disabled
        case .blur: .coverPrivacyBlur
        case .conceal: .coverPrivacyConceal
        }
    }
}

enum CoverPrivacyPage: String, CaseIterable, Codable, Sendable {
    case home, search
    // Keep the persisted key from the original combined category/topic setting.
    case topic = "category"

    var titleKey: L10nKey {
        switch self {
        case .home: .home
        case .search: .search
        case .topic: .coverPrivacyCategory
        }
    }
}

struct CoverPrivacyRule: Codable, Hashable, Sendable {
    var mode: CoverPrivacyMode = .off
    var strength = 50
    var revealDelay: Double = 1

    static let never: Double = -1

    var normalized: Self {
        var result = self
        result.strength = min(100, max(1, strength))
        // Unrepresentable or negative waits must never accidentally reveal immediately.
        if !revealDelay.isFinite || revealDelay < 0 || revealDelay >= Double(Int64.max) / 1_000_000_000 {
            result.revealDelay = Self.never
        }
        return result
    }

    func blurRadius(shortEdge: CGFloat) -> CGFloat {
        max(1, shortEdge * CGFloat(strength) / 400)
    }
}

struct CoverPrivacyOverride: Codable, Equatable, Sendable {
    var mode: CoverPrivacyMode?
    var strength: Int?
    var revealDelay: Double?
}

struct CoverPrivacyPreferences: Codable, Equatable, Sendable {
    var global = CoverPrivacyRule()
    private var pages: [String: CoverPrivacyOverride] = [:]

    subscript(page: CoverPrivacyPage) -> CoverPrivacyOverride {
        get { pages[page.rawValue] ?? CoverPrivacyOverride() }
        set { pages[page.rawValue] = newValue == CoverPrivacyOverride() ? nil : newValue }
    }

    func rule(for page: CoverPrivacyPage?) -> CoverPrivacyRule {
        guard let page else { return global.normalized }
        let override = self[page]
        return CoverPrivacyRule(mode: override.mode ?? global.mode,
                                strength: override.strength ?? global.strength,
                                revealDelay: override.revealDelay ?? global.revealDelay).normalized
    }
}

struct CoverRevealContext: Hashable {
    let bookID: String
    let path: String?
    let rule: CoverPrivacyRule
}

/// A pending deadline belongs to one uninterrupted hover on one representation of a cover.
struct CoverRevealState {
    struct Request: Equatable {
        let generation: UInt64
        let deadline: ContinuousClock.Instant
    }

    private var generation: UInt64 = 0
    private var context: CoverRevealContext?
    private var pending: Request?
    private var revealed = false

    func isRevealed(for current: CoverRevealContext) -> Bool {
        revealed && context == current
    }

    mutating func update(for current: CoverRevealContext, hovered: Bool, allowed: Bool,
                         now: ContinuousClock.Instant) -> Request? {
        generation &+= 1
        context = current
        pending = nil
        revealed = false
        let delay = current.rule.revealDelay
        guard hovered, allowed, current.rule.mode != .off, delay >= 0 else { return nil }
        if delay == 0 {
            revealed = true
            return nil
        }
        let request = Request(generation: generation, deadline: now.advanced(by: .seconds(delay)))
        pending = request
        return request
    }

    mutating func complete(_ request: Request, now: ContinuousClock.Instant) {
        guard pending == request, now >= request.deadline else { return }
        pending = nil
        revealed = true
    }
}
