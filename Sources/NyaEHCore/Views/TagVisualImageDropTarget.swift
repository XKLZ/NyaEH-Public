// 本文件提供标签视觉图片拖放控件，把拖放交互和图片读取状态从设置界面拆开。

import AppKit
import OSLog
import SwiftUI

struct TagVisualImageDropTargetModifier: ViewModifier {
    let kind: TagVisualDropImportKind
    let localizer: AppLocalizer
    var isEnabled = true
    var capturesAllHitTests = false
    var cornerRadius: CGFloat = 8
    let hasExistingAsset: () -> Bool
    let onImport: (Data) -> Void
    let onError: (String) -> Void

    @State private var isDropTargeted = false
    @State private var pendingDroppedImageData: Data?
    @State private var showsReplaceConfirmation = false
    @Environment(\.tagVisualDropTargetsEnabled) private var areTagVisualDropTargetsEnabled

    func body(content: Content) -> some View {
        let isActive = isEnabled && areTagVisualDropTargetsEnabled

        content
            .overlay {
                if isActive {
                    TagVisualPasteboardDropBridge(
                        capturesAllHitTests: capturesAllHitTests,
                        isTargeted: $isDropTargeted,
                        onDrop: handlePasteboardDrop(_:)
                    )
                }
            }
            .overlay {
                if isDropTargeted && isActive {
                    TagVisualDropHighlight(kind: kind, cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
                }
            }
            .animation(.snappy(duration: 0.16), value: isDropTargeted)
            .onDrop(
                of: isActive ? TagDropImageLoader.supportedTypeIdentifiers : [],
                isTargeted: $isDropTargeted,
                perform: handleDrop(providers:)
            )
            .confirmationDialog(
                localizer.string(kind.replaceConfirmationTitleKey),
                isPresented: $showsReplaceConfirmation,
                titleVisibility: .visible
            ) {
                Button(localizer.string(.tagCardReplaceImage), role: .destructive) {
                    if let pendingDroppedImageData {
                        onImport(pendingDroppedImageData)
                    }
                    pendingDroppedImageData = nil
                }

                Button(localizer.string(.cancel), role: .cancel) {
                    pendingDroppedImageData = nil
                }
            } message: {
                Text(localizer.string(kind.replaceConfirmationMessageKey))
            }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard isEnabled, areTagVisualDropTargetsEnabled else {
            return false
        }

        Task {
            do {
                let imageData = try await TagDropImageLoader.imageData(from: providers)
                await MainActor.run {
                    if hasExistingAsset() {
                        pendingDroppedImageData = imageData
                        showsReplaceConfirmation = true
                    } else {
                        onImport(imageData)
                    }
                }
            } catch {
                await MainActor.run {
                    onError("\(localizer.string(.tagCardDropImageFailed)): \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    private func handlePasteboardDrop(_ pasteboard: NSPasteboard) {
        guard isEnabled, areTagVisualDropTargetsEnabled else {
            return
        }

        Task {
            do {
                let imageData = try await TagPasteboardImageLoader.imageData(from: pasteboard)
                await MainActor.run {
                    importOrConfirm(imageData)
                }
            } catch {
                await MainActor.run {
                    onError("\(localizer.string(.tagCardDropImageFailed)): \(error.localizedDescription)")
                }
            }
        }
    }

    private func importOrConfirm(_ imageData: Data) {
        if hasExistingAsset() {
            pendingDroppedImageData = imageData
            showsReplaceConfirmation = true
        } else {
            onImport(imageData)
        }
    }
}

struct TagVisualDropHighlight: View {
    let kind: TagVisualDropImportKind
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.88), lineWidth: 2)
                }

            Image(systemName: kind.dropSystemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.32), in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
        }
    }
}

private struct TagVisualPasteboardDropBridge: NSViewRepresentable {
    let capturesAllHitTests: Bool
    @Binding var isTargeted: Bool
    let onDrop: (NSPasteboard) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.capturesAllHitTests = capturesAllHitTests
        view.onTargetedChange = { isTargeted = $0 }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.capturesAllHitTests = capturesAllHitTests
        nsView.onTargetedChange = { isTargeted = $0 }
        nsView.onDrop = onDrop
    }

    final class DropView: NSView {
        var capturesAllHitTests = false
        var onTargetedChange: (Bool) -> Void = { _ in }
        var onDrop: (NSPasteboard) -> Void = { _ in }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes(TagPasteboardImageLoader.readablePasteboardTypes)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard TagVisualPasteboardDropHitPolicy.acceptsHit(
                for: window?.currentEvent?.type,
                capturesAllHitTests: capturesAllHitTests
            ) else {
                return nil
            }
            return super.hitTest(point)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onTargetedChange(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargetedChange(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargetedChange(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            true
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargetedChange(false)
            onDrop(sender.draggingPasteboard)
            return true
        }
    }
}

enum TagVisualPasteboardDropHitPolicy {
    static func acceptsHit(for eventType: NSEvent.EventType?, capturesAllHitTests: Bool = false) -> Bool {
        if capturesAllHitTests {
            return true
        }

        switch eventType {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .mouseMoved,
             .mouseEntered,
             .mouseExited,
             .cursorUpdate,
             .scrollWheel,
             .magnify,
             .swipe,
             .rotate,
             .beginGesture,
             .endGesture,
             .pressure,
             .tabletPoint,
             .tabletProximity:
            return false
        case nil:
            return true
        default:
            return true
        }
    }
}

private struct TagVisualDropTargetsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var tagVisualDropTargetsEnabled: Bool {
        get { self[TagVisualDropTargetsEnabledKey.self] }
        set { self[TagVisualDropTargetsEnabledKey.self] = newValue }
    }
}

private struct TagVisualDropTargetSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private extension View {
    func readTagVisualDropTargetSize(_ size: Binding<CGSize>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TagVisualDropTargetSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(TagVisualDropTargetSizeKey.self) { newSize in
            size.wrappedValue = newSize
        }
    }
}

extension View {
    @ViewBuilder
    func tagVisualImageDropTarget(
        kind: TagVisualDropImportKind,
        localizer: AppLocalizer,
        isEnabled: Bool = true,
        capturesAllHitTests: Bool = false,
        cornerRadius: CGFloat = 8,
        hasExistingAsset: @escaping () -> Bool,
        onImport: @escaping (Data) -> Void,
        onError: @escaping (String) -> Void
    ) -> some View {
        if isEnabled {
            modifier(
                TagVisualImageDropTargetModifier(
                    kind: kind,
                    localizer: localizer,
                    isEnabled: isEnabled,
                    capturesAllHitTests: capturesAllHitTests,
                    cornerRadius: cornerRadius,
                    hasExistingAsset: hasExistingAsset,
                    onImport: onImport,
                    onError: onError
                )
            )
        } else {
            self
        }
    }

}

extension TagVisualDropImportKind {
    var dropSystemImage: String {
        switch self {
        case .foreground:
            "photo.badge.plus"
        case .background:
            "photo.on.rectangle.angled"
        }
    }

    var replaceConfirmationTitleKey: L10nKey {
        switch self {
        case .foreground:
            .tagCardReplaceImageConfirmationTitle
        case .background:
            .tagCardReplaceBackgroundImageConfirmationTitle
        }
    }

    var replaceConfirmationMessageKey: L10nKey {
        switch self {
        case .foreground:
            .tagCardReplaceImageConfirmationMessage
        case .background:
            .tagCardReplaceBackgroundImageConfirmationMessage
        }
    }

    var diagnosticName: String {
        switch self {
        case .foreground:
            "foreground"
        case .background:
            "background"
        }
    }
}

enum TagVisualDropDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "NyaEH",
        category: "TagVisualDrop"
    )

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
