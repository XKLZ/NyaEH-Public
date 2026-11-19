// 卡片只截取 Command 点按。行布局保留原有的辅助点按选择。

import AppKit
import SwiftUI

struct SearchSecondaryClickBridge: NSViewRepresentable {
    let onSecondaryClick: () -> Void

    var commandClickOnly = false

    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.onSecondaryClick = onSecondaryClick
        view.commandClickOnly = commandClickOnly
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: SecondaryClickView, context: Context) {
        nsView.onSecondaryClick = onSecondaryClick
        nsView.commandClickOnly = commandClickOnly
    }

    final class SecondaryClickView: NSView {
        var onSecondaryClick: () -> Void = {}

        var commandClickOnly = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil, let event = window?.currentEvent,
                  SearchSecondaryClickHitPolicy.accepts(
                    eventType: event.type,
                    modifierFlags: event.modifierFlags,
                    commandClickOnly: commandClickOnly
                  ) else {
                return nil
            }
            return self
        }

        override func rightMouseDown(with event: NSEvent) {
            onSecondaryClick()
        }

        override func mouseDown(with event: NSEvent) {
            guard SearchSecondaryClickHitPolicy.accepts(eventType: event.type, modifierFlags: event.modifierFlags,
                                                      commandClickOnly: commandClickOnly) else {
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
        modifierFlags: NSEvent.ModifierFlags = [],
        commandClickOnly: Bool = false
    ) -> Bool {
        switch eventType {
        case .rightMouseDown, .rightMouseUp:
            return !commandClickOnly
        case .leftMouseDown, .leftMouseUp:
            if commandClickOnly { return modifierFlags.contains(.command) && !modifierFlags.contains(.control) }
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
        commandClickHeight: CGFloat? = nil,
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
        .overlay(alignment: .top) {
            SearchSecondaryClickBridge(onSecondaryClick: onToggle, commandClickOnly: commandClickHeight != nil)
                .frame(height: commandClickHeight)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(localizer.string(isSelected ? .batchDeselect : .batchSelect)), onToggle)
    }
}
