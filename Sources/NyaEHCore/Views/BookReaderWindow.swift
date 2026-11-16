// 本文件实现轻量独立阅读窗口；SwiftUI 持有阅读状态，AppKit 仅负责窗口生命周期与系统事件桥接。

import AppKit
import SwiftUI

@MainActor
final class ModernBookReaderWindowPresenter: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "NyaEH.ModernBookReaderWindow"

    private var window: NSWindow?
    private var onWindowFrameChange: ((CGRect) -> Void)?
    private var windowMoveSaveTask: Task<Void, Never>?
    private var isWindowFullScreen = false

    func show(
        title: String,
        pages: [BookReaderLoadedPage],
        initialPageID: Int,
        totalPages: Int,
        localizer: AppLocalizer,
        archiveSession: ReaderArchiveSession,
        displayPreferences: ReaderDisplayPreferences,
        onDisplayPreferencesChange: @escaping (ReaderDisplayPreferences) -> Void,
        savedWindowFrame: CGRect?,
        onWindowFrameChange: @escaping (CGRect) -> Void,
        onProgress: @escaping (Int, Int, Bool?) -> Void,
        onFlushProgress: @escaping () -> Void
    ) {
        let view = ModernBookReaderWindowView(
            pages: pages,
            initialPageID: initialPageID,
            totalPages: totalPages,
            localizer: localizer,
            archiveSession: archiveSession,
            displayPreferences: displayPreferences,
            onDisplayPreferencesChange: onDisplayPreferencesChange,
            onProgress: onProgress,
            onFlushProgress: onFlushProgress,
            onClose: { [weak self] in self?.close() }
        )
        let hostingController = NSHostingController(rootView: view)
        self.onWindowFrameChange = onWindowFrameChange

        if let window {
            hideStandardWindowButtons(in: window)
            window.contentViewController = hostingController
            window.title = title
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let sourceScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = sourceScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let initialFrame = ReaderWindowPlacementPolicy.initialFrame(in: visibleFrame)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isOpaque = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.minSize = ReaderWindowPlacementPolicy.minimumSize
        hideStandardWindowButtons(in: window)

        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        if let savedWindowFrame {
            let restoredFrame = ReaderWindowPlacementPolicy.restoredFrame(
                savedWindowFrame,
                visibleFrames: visibleFrames,
                fallbackVisibleFrame: visibleFrame
            )
            window.setFrame(restoredFrame, display: false)
            if restoredFrame != savedWindowFrame {
                onWindowFrameChange(restoredFrame)
            }
        } else if window.setFrameUsingName(Self.frameAutosaveName) {
            let migratedFrame = ReaderWindowPlacementPolicy.restoredFrame(
                window.frame,
                visibleFrames: visibleFrames,
                fallbackVisibleFrame: visibleFrame
            )
            window.setFrame(migratedFrame, display: false)
            onWindowFrameChange(migratedFrame)
        } else {
            window.setFrame(initialFrame, display: false)
        }
        window.contentViewController = hostingController
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let fullscreenWindow = notification.object as? NSWindow,
              fullscreenWindow === window else {
            return
        }
        windowMoveSaveTask?.cancel()
        isWindowFullScreen = true
        hideStandardWindowButtons(in: fullscreenWindow)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let fullscreenWindow = notification.object as? NSWindow,
              fullscreenWindow === window else {
            return
        }
        isWindowFullScreen = false
        hideStandardWindowButtons(in: fullscreenWindow)
        saveWindowFrame(fullscreenWindow)
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow,
              movedWindow === window,
              ReaderWindowFramePersistencePolicy.shouldSave(
                isFullScreen: isWindowFullScreen || movedWindow.styleMask.contains(.fullScreen)
              ) else {
            return
        }
        windowMoveSaveTask?.cancel()
        windowMoveSaveTask = Task { @MainActor [weak self, weak movedWindow] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard let self, let movedWindow, movedWindow === self.window else { return }
            self.saveWindowFrame(movedWindow)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else {
            return
        }
        saveWindowFrame(resizedWindow)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        windowMoveSaveTask?.cancel()
        windowMoveSaveTask = nil
        saveWindowFrame(closingWindow)
        closingWindow.contentViewController = nil
        closingWindow.delegate = nil
        window = nil
        onWindowFrameChange = nil
    }

    private func saveWindowFrame(_ window: NSWindow) {
        guard ReaderWindowFramePersistencePolicy.shouldSave(
            isFullScreen: isWindowFullScreen || window.styleMask.contains(.fullScreen)
        ) else {
            return
        }
        onWindowFrameChange?(window.frame)
    }

    private func hideStandardWindowButtons(in window: NSWindow) {
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
    }
}

private struct ModernBookReaderWindowView: View {
    private struct ContinuousScrollRequest: Equatable {
        let id = UUID()
        let index: Int
    }

    private enum HoveredPageZone {
        case previous
        case next
    }

    let initialPageID: Int
    let totalPages: Int
    let localizer: AppLocalizer
    let archiveSession: ReaderArchiveSession
    let onDisplayPreferencesChange: (ReaderDisplayPreferences) -> Void
    let onProgress: (Int, Int, Bool?) -> Void
    let onFlushProgress: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPageIndex: Int
    @State private var pageCache: [Int: BookReaderLoadedPage]
    @State private var pageLoadError: String?
    @State private var layoutMode: ReaderLayoutMode
    @State private var fitMode: ReaderFitMode
    @State private var zoom: Double
    @State private var showsThumbnails: Bool
    @State private var thumbnailCache: [Int: ReaderDecodedThumbnail] = [:]
    @State private var thumbnailLoadingIndices: Set<Int> = []
    @State private var visibleThumbnailPages: Set<Int> = []
    @State private var jumpPage = 1
    @State private var isJumpPageEditing = false
    @State private var hostWindow: NSWindow?
    @State private var isFullScreen = false
    @State private var controlsVisible = true
    @State private var isPointerOverControls = false
    @State private var isPointerOverThumbnailSidebar = false
    @State private var isDisplayOptionsPresented = false
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var hoveredPageZone: HoveredPageZone?
    @State private var continuousScrollRequest: ContinuousScrollRequest?
    @State private var visibleContinuousPages: Set<Int> = []
    @FocusState private var isJumpPageFocused: Bool

    init(
        pages: [BookReaderLoadedPage],
        initialPageID: Int,
        totalPages: Int,
        localizer: AppLocalizer,
        archiveSession: ReaderArchiveSession,
        displayPreferences: ReaderDisplayPreferences,
        onDisplayPreferencesChange: @escaping (ReaderDisplayPreferences) -> Void,
        onProgress: @escaping (Int, Int, Bool?) -> Void,
        onFlushProgress: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.initialPageID = initialPageID
        self.totalPages = totalPages
        self.localizer = localizer
        self.archiveSession = archiveSession
        self.onDisplayPreferencesChange = onDisplayPreferencesChange
        self.onProgress = onProgress
        self.onFlushProgress = onFlushProgress
        self.onClose = onClose
        let normalizedDisplayPreferences = displayPreferences.normalized()
        let initialIndex = ReaderNavigationPolicy.alignedIndex(
            initialPageID,
            totalPages: totalPages,
            layout: normalizedDisplayPreferences.layoutMode
        )
        _currentPageIndex = State(initialValue: initialIndex)
        _pageCache = State(initialValue: Dictionary(uniqueKeysWithValues: pages.map { ($0.index, $0) }))
        _layoutMode = State(initialValue: normalizedDisplayPreferences.layoutMode)
        _fitMode = State(initialValue: normalizedDisplayPreferences.fitMode)
        _zoom = State(initialValue: normalizedDisplayPreferences.zoom)
        _showsThumbnails = State(initialValue: normalizedDisplayPreferences.showsThumbnails)
        _jumpPage = State(initialValue: initialIndex + 1)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            readerContent
                .ignoresSafeArea()

            if showsThumbnails {
                thumbnailSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }

            windowDragRegion
                .zIndex(2)

            if controlsVisible {
                controls
                    .transition(.opacity)
                    .zIndex(3)
            }

            ReaderInputBridge(
                window: hostWindow,
                isScrollPagingEnabled: ReaderInputPolicy.pagesWithScroll(
                    layout: layoutMode,
                    isPointerOverControls: isPointerOverControls,
                    isPointerOverThumbnailSidebar: isPointerOverThumbnailSidebar
                ),
                isThumbnailSidebarPresented: showsThumbnails,
                onCommand: handle,
                onActivity: revealControls
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .background(ReaderHostWindowReader(window: $hostWindow))
        .frame(minWidth: ReaderWindowPlacementPolicy.minimumSize.width,
               minHeight: ReaderWindowPlacementPolicy.minimumSize.height)
        .task(id: currentPageIndex) { await loadWindow(around: currentPageIndex) }
        .onAppear {
            reportProgress()
            revealControls()
            if showsThumbnails {
                requestThumbnailLoad(around: currentPageIndex)
            }
        }
        .onDisappear {
            controlsHideTask?.cancel()
            onFlushProgress()
            pageCache.removeAll()
            thumbnailCache.removeAll()
            thumbnailLoadingIndices.removeAll()
            visibleThumbnailPages.removeAll()
        }
        .onContinuousHover { phase in
            if case .active = phase {
                revealControls()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            onFlushProgress()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard notification.object as? NSWindow === hostWindow else { return }
            isFullScreen = true
            revealControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard notification.object as? NSWindow === hostWindow else { return }
            isFullScreen = false
            revealControls()
        }
        .onReceive(ReaderMemoryPressureMonitor.shared.publisher) { _ in
            retainVisiblePagesOnly()
            retainVisibleThumbnailsOnly()
        }
        .onChange(of: currentPageIndex) { _, newValue in
            if !isJumpPageEditing {
                jumpPage = newValue + 1
            }
            reportProgress()
            if showsThumbnails {
                requestThumbnailLoad(around: newValue)
            }
        }
        .onChange(of: isJumpPageFocused) { _, focused in
            if focused {
                pinControls()
            } else {
                if isJumpPageEditing {
                    commitJumpPageEdit()
                }
                scheduleControlsHide()
            }
        }
        .onChange(of: isDisplayOptionsPresented) { _, presented in
            if presented {
                pinControls()
            } else {
                scheduleControlsHide()
            }
        }
    }

    private var windowDragRegion: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            Spacer()
        }
        .allowsHitTesting(true)
    }

    private var controls: some View {
        VStack {
            Spacer()

            FloatingGlassPanel(cornerRadius: 20, horizontalPadding: 12, verticalPadding: 9) {
                lightweightControls
            }
            .onHover { hovering in
                isPointerOverControls = hovering
                if hovering {
                    pinControls()
                } else {
                    scheduleControlsHide()
                }
            }
        }
        .padding(.bottom, 24)
        .padding(.horizontal, 72)
    }

    private var lightweightControls: some View {
        ZStack {
            pageNavigator

            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    thumbnailSidebarButton
                    displayOptionsButton
                }
                    .frame(width: 76, alignment: .leading)

                Spacer(minLength: 0)

                windowButtons
                    .frame(width: 76, alignment: .trailing)
            }
        }
        .frame(width: 410)
        .controlSize(.small)
    }

    private var thumbnailSidebar: some View {
        HStack {
            ReaderThumbnailSidebar(
                totalPages: totalPages,
                currentPageIndex: currentPageIndex,
                selectedRange: ReaderNavigationPolicy.visiblePageRange(
                    currentIndex: currentPageIndex,
                    totalPages: totalPages,
                    layout: layoutMode
                ),
                thumbnails: thumbnailCache,
                loadingIndices: thumbnailLoadingIndices,
                localizer: localizer,
                onSelectPage: selectThumbnailPage,
                onPageVisibilityChange: updateThumbnailPageVisibility
            )
            .onHover { hovering in
                isPointerOverThumbnailSidebar = hovering
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.top, 42)
        .padding(.bottom, 88)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var pageNavigator: some View {
        HStack(spacing: 6) {
            Button(action: goPrevious) {
                Label(localizer.string(.previousPage), systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .focusEffectDisabled()
            .disabled(!canGoPrevious)
            .help("\(localizer.string(.previousPage)) (← / Page Up)")

            Group {
                if isJumpPageEditing {
                    HStack(spacing: 4) {
                        TextField(localizer.string(.pages), value: $jumpPage, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 48)
                            .focused($isJumpPageFocused)
                            .onSubmit(commitJumpPageEdit)
                            .onExitCommand(perform: cancelJumpPageEdit)

                        Text("/ \(totalPages)")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                } else {
                    Button(action: beginJumpPageEdit) {
                        Text(pageIndicator)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                }
            }
            .font(.caption.monospacedDigit())
            .frame(width: 92)
            .help(localizer.string(.pages))

            Button(action: goNext) {
                Label(localizer.string(.nextPage), systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .focusEffectDisabled()
            .disabled(!canGoNext)
            .help("\(localizer.string(.nextPage)) (→ / Space / Page Down)")
        }
    }

    private var displayOptionsButton: some View {
        Button {
            isDisplayOptionsPresented.toggle()
        } label: {
            Label(localizer.string(.readerFitMode), systemImage: "rectangle.on.rectangle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .focusEffectDisabled()
        .help("\(localizer.string(.readerFitMode)) (W / H / A / + / - / 0)")
        .popover(isPresented: $isDisplayOptionsPresented, arrowEdge: .bottom) {
            ReaderDisplayOptionsPopover(
                layoutMode: layoutModeBinding,
                fitMode: fitModeBinding,
                zoom: zoomBinding,
                localizer: localizer
            )
        }
    }

    private var thumbnailSidebarButton: some View {
        Button(action: toggleThumbnailSidebar) {
            Label(
                localizer.string(
                    showsThumbnails ? .readerHideThumbnails : .readerShowThumbnails
                ),
                systemImage: "sidebar.left"
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(showsThumbnails ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .focusEffectDisabled()
        .help(
            "\(localizer.string(showsThumbnails ? .readerHideThumbnails : .readerShowThumbnails)) (⌥⌘S)"
        )
    }

    private var windowButtons: some View {
        HStack(spacing: 6) {
            Button(action: toggleFullScreen) {
                Label(
                    localizer.string(.readerFullscreen),
                    systemImage: isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .focusEffectDisabled()
            .help("\(localizer.string(.readerFullscreen)) (F)")

            Button(action: onClose) {
                Label(localizer.string(.readerClose), systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .focusEffectDisabled()
            .help("\(localizer.string(.readerClose)) (Esc / ⌘W)")
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        switch layoutMode {
        case .singlePage:
            pagedReaderContent {
                cachedPageSurface(index: currentPageIndex)
            }
        case .doublePage:
            pagedReaderContent {
                HStack(spacing: 2) {
                    cachedPageSurface(index: currentPageIndex)
                    if currentPageIndex + 1 < totalPages {
                        cachedPageSurface(index: currentPageIndex + 1)
                    }
                }
            }
        case .continuous:
            continuousReaderContent
        }
    }

    private func pagedReaderContent<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            ZStack {
                content()

                pageNavigationAffordances
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        handlePageTap(at: value.location, width: proxy.size.width)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    updateHoveredPageZone(at: location.x, width: proxy.size.width)
                case .ended:
                    hoveredPageZone = nil
                }
            }
        }
    }

    private var continuousReaderContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        cachedPageSurface(index: index)
                            .frame(minHeight: 520)
                            .id(index)
                            .onAppear {
                                Task { await loadWindow(around: index) }
                            }
                            .onScrollVisibilityChange(threshold: 0.35) { isVisible in
                                updateContinuousPageVisibility(index: index, isVisible: isVisible)
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 42)
                .padding(.bottom, 96)
            }
            .task {
                await Task.yield()
                proxy.scrollTo(continuousScrollRequest?.index ?? currentPageIndex, anchor: .top)
            }
            .onChange(of: continuousScrollRequest) { _, request in
                guard let request else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo(request.index, anchor: .top)
                }
            }
        }
    }

    private var pageNavigationAffordances: some View {
        HStack {
            if hoveredPageZone == .previous, canGoPrevious {
                navigationAffordance(systemImage: "chevron.left")
                    .padding(.leading, 22)
            } else {
                Color.clear.frame(width: 48)
            }

            Spacer()

            if hoveredPageZone == .next, canGoNext {
                navigationAffordance(systemImage: "chevron.right")
                    .padding(.trailing, 22)
            } else {
                Color.clear.frame(width: 48)
            }
        }
    }

    private func navigationAffordance(systemImage: String) -> some View {
        FloatingGlassPanel(cornerRadius: 18, horizontalPadding: 10, verticalPadding: 9) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }

    private var layoutModeBinding: Binding<ReaderLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { newValue in setLayoutMode(newValue) }
        )
    }

    private var fitModeBinding: Binding<ReaderFitMode> {
        Binding(
            get: { fitMode },
            set: { newValue in setFitMode(newValue) }
        )
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { zoom },
            set: { newValue in setZoom(newValue) }
        )
    }

    private var pageIndicator: String {
        guard let range = ReaderNavigationPolicy.visiblePageRange(
            currentIndex: currentPageIndex,
            totalPages: totalPages,
            layout: layoutMode
        ) else {
            return localizer.pageIndicator(current: 0, total: 0)
        }
        if range.lowerBound == range.upperBound {
            return localizer.pageIndicator(current: range.lowerBound + 1, total: totalPages)
        }
        return "\(range.lowerBound + 1)–\(range.upperBound + 1) / \(totalPages)"
    }

    private var canGoPrevious: Bool {
        ReaderNavigationPolicy.targetIndex(
            from: currentPageIndex,
            direction: .previous,
            totalPages: totalPages,
            layout: layoutMode
        ) != currentPageIndex
    }

    private var canGoNext: Bool {
        ReaderNavigationPolicy.targetIndex(
            from: currentPageIndex,
            direction: .next,
            totalPages: totalPages,
            layout: layoutMode
        ) != currentPageIndex
    }

    private func handle(_ command: ReaderCommand) {
        revealControls()
        switch command {
        case let .navigate(direction):
            navigate(direction)
        case .firstPage:
            moveToPage(0)
        case .lastPage:
            moveToPage(ReaderNavigationPolicy.lastPageIndex(totalPages: totalPages, layout: layoutMode))
        case let .setLayout(mode):
            setLayoutMode(mode)
        case let .setFit(mode):
            setFitMode(mode)
        case .zoomIn:
            setCustomZoom(zoom + 0.1)
        case .zoomOut:
            setCustomZoom(zoom - 0.1)
        case .resetZoom:
            setCustomZoom(1)
        case .toggleThumbnails:
            toggleThumbnailSidebar()
        case .toggleFullscreen:
            toggleFullScreen()
        case .close:
            if isFullScreen || hostWindow?.styleMask.contains(.fullScreen) == true {
                toggleFullScreen()
            } else {
                onClose()
            }
        }
    }

    private func goPrevious() {
        revealControls()
        navigate(.previous)
    }

    private func goNext() {
        revealControls()
        navigate(.next)
    }

    private func navigate(_ direction: ReaderNavigationDirection) {
        let target = ReaderNavigationPolicy.targetIndex(
            from: currentPageIndex,
            direction: direction,
            totalPages: totalPages,
            layout: layoutMode
        )
        moveToPage(target)
    }

    private func moveToPage(_ index: Int) {
        let target = ReaderNavigationPolicy.alignedIndex(index, totalPages: totalPages, layout: layoutMode)
        guard target != currentPageIndex || layoutMode == .continuous else { return }
        currentPageIndex = target
        if layoutMode == .continuous {
            continuousScrollRequest = ContinuousScrollRequest(index: target)
        }
    }

    private func selectThumbnailPage(_ index: Int) {
        moveToPage(index)
        revealControls()
    }

    private func toggleThumbnailSidebar() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showsThumbnails.toggle()
        }
        isPointerOverThumbnailSidebar = false
        if showsThumbnails {
            requestThumbnailLoad(around: currentPageIndex)
        } else {
            visibleThumbnailPages.removeAll()
        }
        persistDisplayPreferences()
        revealControls()
    }

    private func beginJumpPageEdit() {
        jumpPage = currentPageIndex + 1
        isJumpPageEditing = true
        pinControls()
        Task { @MainActor in
            isJumpPageFocused = true
        }
    }

    private func commitJumpPageEdit() {
        guard isJumpPageEditing else { return }
        let target = ReaderPageJumpPolicy.targetIndex(
            pageNumber: jumpPage,
            totalPages: totalPages,
            layout: layoutMode
        )
        isJumpPageEditing = false
        isJumpPageFocused = false
        moveToPage(target)
        jumpPage = target + 1
        scheduleControlsHide()
    }

    private func cancelJumpPageEdit() {
        guard isJumpPageEditing else { return }
        jumpPage = currentPageIndex + 1
        isJumpPageEditing = false
        isJumpPageFocused = false
        scheduleControlsHide()
    }

    private func setLayoutMode(_ mode: ReaderLayoutMode) {
        guard mode != layoutMode else { return }
        let alignedIndex = ReaderNavigationPolicy.alignedIndex(
            currentPageIndex,
            totalPages: totalPages,
            layout: mode
        )
        visibleContinuousPages.removeAll()
        layoutMode = mode
        currentPageIndex = alignedIndex
        if mode == .continuous {
            continuousScrollRequest = ContinuousScrollRequest(index: alignedIndex)
        }
        hoveredPageZone = nil
        persistDisplayPreferences()
        Task { await loadWindow(around: currentPageIndex) }
        revealControls()
    }

    private func setFitMode(_ mode: ReaderFitMode) {
        guard mode != fitMode else {
            revealControls()
            return
        }
        fitMode = mode
        persistDisplayPreferences()
        Task { await loadWindow(around: currentPageIndex) }
        revealControls()
    }

    private func setZoom(_ value: Double) {
        let normalized = ReaderDisplayPreferences.normalizedZoom(value)
        guard normalized != zoom else {
            revealControls()
            return
        }
        zoom = normalized
        persistDisplayPreferences()
        revealControls()
    }

    private func setCustomZoom(_ value: Double) {
        let normalized = ReaderDisplayPreferences.normalizedZoom(value)
        let fitModeChanged = fitMode != .custom
        guard normalized != zoom || fitModeChanged else {
            revealControls()
            return
        }
        zoom = normalized
        fitMode = .custom
        persistDisplayPreferences()
        if fitModeChanged {
            Task { await loadWindow(around: currentPageIndex) }
        }
        revealControls()
    }

    private func persistDisplayPreferences() {
        onDisplayPreferencesChange(
            ReaderDisplayPreferences(
                layoutMode: layoutMode,
                fitMode: fitMode,
                zoom: zoom,
                showsThumbnails: showsThumbnails
            )
        )
    }

    private func toggleFullScreen() {
        hostWindow?.toggleFullScreen(nil)
        revealControls()
    }

    private func handlePageTap(at location: CGPoint, width: CGFloat) {
        guard width > 0 else { return }
        let fraction = location.x / width
        if fraction <= 0.25 {
            goPrevious()
        } else if fraction >= 0.75 {
            goNext()
        } else {
            toggleControls()
        }
    }

    private func updateHoveredPageZone(at x: CGFloat, width: CGFloat) {
        guard width > 0 else {
            hoveredPageZone = nil
            return
        }
        let fraction = x / width
        if fraction <= 0.25 {
            hoveredPageZone = .previous
        } else if fraction >= 0.75 {
            hoveredPageZone = .next
        } else {
            hoveredPageZone = nil
        }
    }

    private func updateContinuousPageVisibility(index: Int, isVisible: Bool) {
        if isVisible {
            visibleContinuousPages.insert(index)
        } else {
            visibleContinuousPages.remove(index)
        }
        guard let topVisibleIndex = visibleContinuousPages.min() else { return }
        currentPageIndex = topVisibleIndex
    }

    private func updateThumbnailPageVisibility(index: Int, isVisible: Bool) {
        if isVisible {
            visibleThumbnailPages.insert(index)
            requestThumbnailLoad(around: index)
        } else {
            visibleThumbnailPages.remove(index)
        }
    }

    private func requestThumbnailLoad(around center: Int) {
        Task(priority: .utility) {
            await loadThumbnailWindow(around: center)
        }
    }

    private func toggleControls() {
        controlsHideTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            controlsVisible.toggle()
        }
        if controlsVisible {
            scheduleControlsHide()
        }
    }

    private func revealControls() {
        if !controlsVisible {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                controlsVisible = true
            }
        }
        scheduleControlsHide()
    }

    private func pinControls() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
    }

    private func scheduleControlsHide() {
        controlsHideTask?.cancel()
        guard !isPointerOverControls,
              !isJumpPageEditing,
              !isJumpPageFocused,
              !isDisplayOptionsPresented else {
            return
        }
        controlsHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2.5))
            } catch {
                return
            }
            guard !isPointerOverControls,
                  !isJumpPageEditing,
                  !isJumpPageFocused,
                  !isDisplayOptionsPresented else {
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
    }

    private func reportProgress() {
        onProgress(currentPageIndex, totalPages, nil)
    }

    @ViewBuilder
    private func cachedPageSurface(index: Int) -> some View {
        if let page = pageCache[index] {
            ReaderPageSurface(page: page, fitMode: fitMode, zoom: zoom)
        } else if let pageLoadError {
            ContentUnavailableView(pageLoadError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.white.opacity(0.8))
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
    }

    @MainActor
    private func loadWindow(around center: Int) async {
        guard totalPages > 0 else { return }
        guard let range = ReaderPageCachePolicy.loadRange(
            center: center,
            totalPages: totalPages,
            layout: layoutMode
        ) else {
            return
        }
        let required = Set(range)
        let missing = required.subtracting(pageCache.keys).sorted()
        if missing.isEmpty {
            pruneCache(around: center)
            return
        }
        do {
            let batch = try await archiveSession.load(indices: missing)
            guard !Task.isCancelled, center == currentPageIndex else { return }
            for page in batch.pages {
                pageCache[page.index] = BookReaderLoadedPage(decodedPage: page)
            }
            pageLoadError = nil
            pruneCache(around: center)
        } catch is CancellationError {
            return
        } catch {
            pageLoadError = error.localizedDescription
        }
    }

    private func retainVisiblePagesOnly() {
        guard let range = ReaderNavigationPolicy.visiblePageRange(
            currentIndex: currentPageIndex,
            totalPages: totalPages,
            layout: layoutMode
        ) else {
            pageCache.removeAll()
            return
        }
        let visible = Set(range)
        pageCache = pageCache.filter { visible.contains($0.key) }
    }

    private func retainVisibleThumbnailsOnly() {
        var retained = visibleThumbnailPages
        if let selectedRange = ReaderNavigationPolicy.visiblePageRange(
            currentIndex: currentPageIndex,
            totalPages: totalPages,
            layout: layoutMode
        ) {
            retained.formUnion(selectedRange)
        }
        thumbnailCache = thumbnailCache.filter { retained.contains($0.key) }
    }

    private func pruneCache(around center: Int) {
        let retained = ReaderPageCachePolicy.retainedIndices(pageCache.keys, center: center, layout: layoutMode)
        pageCache = pageCache.filter { retained.contains($0.key) }
        let visible = Set(
            ReaderNavigationPolicy.visiblePageRange(
                currentIndex: center,
                totalPages: totalPages,
                layout: layoutMode
            ) ?? center...center
        )
        let evicted = ReaderPageCachePolicy.evictedIndices(
            costs: pageCache.mapValues(\.decodedCost),
            center: center,
            visibleIndices: visible,
            costLimit: ReaderPageCachePolicy.costLimit()
        )
        for index in evicted {
            pageCache[index] = nil
        }
    }

    @MainActor
    private func loadThumbnailWindow(around center: Int) async {
        guard showsThumbnails, totalPages > 0 else { return }
        let indices = ReaderThumbnailCachePolicy.loadIndices(
            around: center,
            totalPages: totalPages,
            cachedIndices: Set(thumbnailCache.keys),
            loadingIndices: thumbnailLoadingIndices
        )
        guard !indices.isEmpty else {
            pruneThumbnailCache(around: center)
            return
        }

        thumbnailLoadingIndices.formUnion(indices)
        defer {
            thumbnailLoadingIndices.subtract(indices)
        }

        let batch = await archiveSession.loadThumbnails(
            indices: indices,
            maximumPixelSize: ReaderThumbnailCachePolicy.maximumPixelSize
        )
        guard !Task.isCancelled, showsThumbnails else { return }
        for thumbnail in batch.thumbnails {
            thumbnailCache[thumbnail.index] = thumbnail
        }
        pruneThumbnailCache(around: center)
    }

    private func pruneThumbnailCache(around center: Int) {
        var protected = visibleThumbnailPages
        if let selectedRange = ReaderNavigationPolicy.visiblePageRange(
            currentIndex: currentPageIndex,
            totalPages: totalPages,
            layout: layoutMode
        ) {
            protected.formUnion(selectedRange)
        }
        let evicted = ReaderThumbnailCachePolicy.evictedIndices(
            costs: thumbnailCache.mapValues(\.decodedCost),
            center: center,
            visibleIndices: protected
        )
        for index in evicted {
            thumbnailCache[index] = nil
        }
    }
}

private struct ReaderDisplayOptionsPopover: View {
    @Binding var layoutMode: ReaderLayoutMode
    @Binding var fitMode: ReaderFitMode
    @Binding var zoom: Double
    let localizer: AppLocalizer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localizer.string(.readerLayoutMode))
                .font(.headline)

            Picker(localizer.string(.readerLayoutMode), selection: $layoutMode) {
                Label(localizer.string(.readerSinglePage), systemImage: "rectangle.portrait")
                    .tag(ReaderLayoutMode.singlePage)
                Label(localizer.string(.readerDoublePage), systemImage: "rectangle.split.2x1")
                    .tag(ReaderLayoutMode.doublePage)
                Label(localizer.string(.readerContinuous), systemImage: "rectangle.stack")
                    .tag(ReaderLayoutMode.continuous)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .focusable(false)
            .focusEffectDisabled()

            Divider()

            Text(localizer.string(.readerFitMode))
                .font(.headline)

            Picker(localizer.string(.readerFitMode), selection: $fitMode) {
                Text(localizer.string(.readerFitWidth)).tag(ReaderFitMode.fitWidth)
                Text(localizer.string(.readerFitHeight)).tag(ReaderFitMode.fitHeight)
                Text(localizer.string(.readerActualSize)).tag(ReaderFitMode.actualSize)
                Text(localizer.string(.readerCustomZoom)).tag(ReaderFitMode.custom)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .focusable(false)
            .focusEffectDisabled()

            if fitMode == .custom {
                HStack(spacing: 10) {
                    Button {
                        zoom = max(zoom - 0.05, 0.25)
                    } label: {
                        Label(localizer.string(.readerZoomOut), systemImage: "minus")
                            .labelStyle(.iconOnly)
                    }
                    .focusable(false)
                    .focusEffectDisabled()

                    Slider(value: $zoom, in: 0.25...3, step: 0.05)
                        .focusable(false)
                        .focusEffectDisabled()

                    Button {
                        zoom = min(zoom + 0.05, 3)
                    } label: {
                        Label(localizer.string(.readerZoomIn), systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .focusable(false)
                    .focusEffectDisabled()

                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .frame(width: 310)
    }
}

private struct ReaderPageSurface: View {
    let page: BookReaderLoadedPage
    let fitMode: ReaderFitMode
    let zoom: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = page.image {
                    imageView(image, availableSize: proxy.size)
                } else {
                    ContentUnavailableView(page.displayName, systemImage: "photo")
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

    @ViewBuilder
    private func imageView(_ image: NSImage, availableSize: CGSize) -> some View {
        switch fitMode {
        case .fitWidth:
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: max(availableSize.width - 24, 1))
                .padding(12)
        case .fitHeight:
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: max(availableSize.height - 24, 1))
                .padding(12)
        case .actualSize:
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .frame(width: image.size.width, height: image.size.height)
                    .padding(12)
            }
        case .custom:
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                    .padding(12)
            }
        }
    }
}

private struct ReaderHostWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChange = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onWindowChange = { window = $0 }
        DispatchQueue.main.async {
            window = nsView.window
        }
    }

    final class WindowReaderView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
