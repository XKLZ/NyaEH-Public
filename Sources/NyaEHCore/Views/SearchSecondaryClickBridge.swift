// 本文件只桥接 Search 结果项的右键与 Control-click；其他指针事件继续交给 SwiftUI。

import AppKit
import SwiftUI

struct SearchSecondaryClickBridge: NSViewRepresentable {
    let onSecondaryClick: () -> Void

    init(onSecondaryClick: @escaping () -> Void) {
        self.onSecondaryClick = onSecondaryClick
    }

    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.onSecondaryClick = onSecondaryClick
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: SecondaryClickView, context: Context) {
        nsView.onSecondaryClick = onSecondaryClick
    }

    final class SecondaryClickView: NSView {
        var onSecondaryClick: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = window?.currentEvent,
                  SearchSecondaryClickHitPolicy.accepts(
                    eventType: event.type,
                    modifierFlags: event.modifierFlags
                  ) else {
                return nil
            }
            return self
        }

        override func rightMouseDown(with event: NSEvent) {
            onSecondaryClick()
        }

        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else {
                super.mouseDown(with: event)
                return
            }
            onSecondaryClick()
        }
    }
}

enum SearchSecondaryClickHitPolicy {
    static func accepts(
        eventType: NSEvent.EventType?,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Bool {
        switch eventType {
        case .rightMouseDown, .rightMouseUp:
            return true
        case .leftMouseDown, .leftMouseUp:
            return modifierFlags.contains(.control)
        default:
            return false
        }
    }
}

extension View {
    func searchBatchSelection(
        isSelected: Bool,
        localizer: AppLocalizer,
        outlineInset: CGFloat = -5,
        onToggle: @escaping () -> Void
    ) -> some View {
        overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(outlineInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay { SearchSecondaryClickBridge(onSecondaryClick: onToggle) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(localizer.string(isSelected ? .batchDeselect : .batchSelect)), onToggle)
    }
}
