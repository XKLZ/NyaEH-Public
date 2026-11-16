// 本文件集中描述 Search 滚动阶段和悬停重启规则，避免滚动中的项目穿过鼠标时持续写入视图状态。

import CoreGraphics
import SwiftUI

struct SearchScrollActivityState: Equatable, Sendable {
    private(set) var isScrolling = false

    @discardableResult
    mutating func update(isScrolling: Bool) -> Bool {
        guard self.isScrolling != isScrolling else {
            return false
        }
        self.isScrolling = isScrolling
        return true
    }
}

struct SearchScrollHoverGate: Equatable, Sendable {
    private(set) var requiresPointerMovement = false
    private var pointerBaseline: CGPoint?

    mutating func scrollActivityChanged(isScrolling: Bool) {
        if isScrolling {
            requiresPointerMovement = true
        }
        pointerBaseline = nil
    }

    mutating func pointerBecameActive(at location: CGPoint, isScrolling: Bool) -> Bool {
        guard !isScrolling else {
            pointerBaseline = nil
            return false
        }
        guard requiresPointerMovement else {
            pointerBaseline = location
            return true
        }
        guard let pointerBaseline else {
            self.pointerBaseline = location
            return false
        }

        let distance = hypot(location.x - pointerBaseline.x, location.y - pointerBaseline.y)
        self.pointerBaseline = location
        guard distance >= 1 else {
            return false
        }
        requiresPointerMovement = false
        return true
    }

    mutating func pointerEnded() {
        pointerBaseline = nil
    }
}

private struct SearchScrollActivityEnvironmentKey: EnvironmentKey {
    static let defaultValue = SearchScrollActivityState()
}

extension EnvironmentValues {
    var searchScrollActivity: SearchScrollActivityState {
        get { self[SearchScrollActivityEnvironmentKey.self] }
        set { self[SearchScrollActivityEnvironmentKey.self] = newValue }
    }
}
