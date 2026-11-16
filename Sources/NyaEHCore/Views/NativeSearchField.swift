import AppKit
import SwiftUI

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var activeTokenRange: NSRange?
    let isActive: Bool
    let onCommit: () -> Void
    let onMoveSuggestion: (SearchSuggestionSelection.Direction) -> Bool
    let onDismissSuggestions: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        makeSearchField(coordinator: context.coordinator)
    }

    func makeSearchField(coordinator: Coordinator) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = normalizedPlaceholder
        field.font = .systemFont(ofSize: 16)
        field.controlSize = .large
        field.cell?.controlSize = .large
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = coordinator
        field.target = coordinator
        field.action = #selector(Coordinator.commitSearch(_:))
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        coordinator.synchronize(field, parent: self)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.synchronize(field, parent: self)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.invalidate()
        field.delegate = nil
        field.target = nil
        field.action = nil
    }

    private var normalizedPlaceholder: String {
        placeholder.isEmpty ? " " : placeholder
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private var parent: NativeSearchField
        private var isSynchronizing = false
        private weak var observedEditor: NSTextView?
        private weak var editingField: NSSearchField?
        private let selectionUpdate = SearchDeferredAction()
        private let focusUpdate = SearchDeferredAction()

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        /// SwiftUI -> AppKit only. Setters and selection notifications can be
        /// synchronous, so no delegate may write bindings inside this boundary.
        func synchronize(_ field: NSSearchField, parent: NativeSearchField) {
            self.parent = parent
            isSynchronizing = true
            defer { isSynchronizing = false }
            if field.stringValue != parent.text {
                selectionUpdate.cancel()
                field.stringValue = parent.text
                if let editor = field.currentEditor() {
                    editor.selectedRange = NSRange(location: (parent.text as NSString).length, length: 0)
                }
                deferActiveTokenRangeUpdate(field)
            }
            if field.placeholderString != parent.normalizedPlaceholder {
                field.placeholderString = parent.normalizedPlaceholder
            }
            if parent.isActive {
                focusUpdate.cancel()
            } else {
                selectionUpdate.cancel()
                resignFirstResponderIfNeeded(field)
            }
        }

        func invalidate() {
            selectionUpdate.cancel()
            focusUpdate.cancel()
            stopObservingSelection()
        }

        @objc func commitSearch(_ sender: NSSearchField) {
            guard !isSynchronizing else { return }
            publishDraft(sender)
            parent.onCommit()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard !isSynchronizing, let field = control as? NSSearchField else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveSuggestion(.next)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveSuggestion(.previous)
            case #selector(NSResponder.cancelOperation(_:)):
                selectionUpdate.cancel()
                return parent.onDismissSuggestions()
            case #selector(NSResponder.insertNewline(_:)):
                publishDraft(field)
                parent.onCommit()
                return true
            default:
                return false
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isSynchronizing, let field = notification.object as? NSSearchField else { return }
            publishDraft(field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard !isSynchronizing, let field = notification.object as? NSSearchField else { return }
            observeSelection(field)
            updateActiveTokenRange(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            stopObservingSelection()
            guard !isSynchronizing, let field = notification.object as? NSSearchField else { return }
            publishDraft(field)
        }

        private func publishDraft(_ field: NSSearchField) {
            selectionUpdate.cancel()
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
            updateActiveTokenRange(field)
        }

        private func observeSelection(_ field: NSSearchField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            guard editor !== observedEditor else { return }
            stopObservingSelection()
            editingField = field
            observedEditor = editor
            // AppKit posts field-editor selection notifications on the main thread.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionDidChange(_:)),
                name: NSTextView.didChangeSelectionNotification,
                object: editor
            )
        }

        private func stopObservingSelection() {
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: observedEditor)
            observedEditor = nil
            editingField = nil
            selectionUpdate.cancel()
        }

        @objc private func selectionDidChange(_ notification: Notification) {
            guard let field = editingField,
                  let editor = observedEditor,
                  field.currentEditor() === editor else { return }
            deferActiveTokenRangeUpdate(field)
        }

        private func deferActiveTokenRangeUpdate(_ field: NSSearchField) {
            selectionUpdate.schedule { [weak self, weak field] in
                guard let self, let field, self.parent.isActive,
                      field.stringValue == self.parent.text else { return }
                self.updateActiveTokenRange(field)
            }
        }

        private func resignFirstResponderIfNeeded(_ field: NSSearchField) {
            guard field.currentEditor() != nil else { return }
            focusUpdate.schedule { [weak self, weak field] in
                guard let self, let field, !self.parent.isActive,
                      let window = field.window,
                      let editor = field.currentEditor(),
                      window.firstResponder === editor else { return }
                window.makeFirstResponder(nil)
            }
        }

        private func updateActiveTokenRange(_ field: NSSearchField) {
            let selectedRange: NSRange
            if let editor = field.currentEditor() {
                if let textView = editor as? NSTextView, textView.hasMarkedText() { return }
                selectedRange = editor.selectedRange
            } else {
                selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
            let range = SearchQueryTextEditor.activeTokenRange(in: field.stringValue, selectedRange: selectedRange)
            if parent.activeTokenRange != range {
                parent.activeTokenRange = range
            }
        }
    }
}
