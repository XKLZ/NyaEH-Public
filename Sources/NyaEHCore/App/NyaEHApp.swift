// Shared scene: validate test host identity before constructing any persistent dependency.
import SwiftUI
import Combine

@MainActor
private final class NyaEHSceneDependencies {
    let appModel = NyaEHAppModel()
    let preferences = AppPreferences()
    let localHighlightServer = LocalHighlightServerController()
    private var volumeWatcher: AnyCancellable?
    let updateManager: UpdateManager?

    init(runtime: TestRuntime?) {
        volumeWatcher = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .receive(on: RunLoop.main)
            .sink { [weak appModel] _ in appModel?.catalog.reconcileBackups() }
        appModel.catalog.advancedSearchShowsIndividualBooks = preferences.isAdvancedSearchCollectionMembersExpanded
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        updateManager = runtime == nil && Bundle.main.bundleIdentifier == "com.gazelee.NyaEH" && !publicKey.isEmpty
            ? UpdateManager(preferences: preferences) : nil
    }
}

public struct NyaEHScene: Scene {
    @State private var dependencies: NyaEHSceneDependencies?
    private let developmentConfiguration: NyaEHDevelopmentConfiguration?
    private let startupError: String?

    public init(developmentConfiguration: NyaEHDevelopmentConfiguration? = nil) {
        self.developmentConfiguration = developmentConfiguration
        do {
            let runtime = try TestRuntime.current.get()
            if developmentConfiguration != nil && runtime == nil {
                throw TestRuntime.failure("开发宿主必须通过项目脚本启动。")
            }
            startupError = nil
            _dependencies = State(initialValue: NyaEHSceneDependencies(runtime: runtime))
        } catch {
            startupError = error.localizedDescription
            _dependencies = State(initialValue: nil)
        }
    }

    public var body: some Scene {
        WindowGroup {
            if let dependencies {
                mainContent(dependencies)
            } else {
                VStack(spacing: 16) {
                    Text("测试启动被阻止").font(.title)
                    Text(startupError ?? "启动配置无效").textSelection(.enabled)
                }.padding(32).frame(width: 540)
            }
        }
        .windowStyle(.titleBar)
        .defaultWindowPlacement { _, context in
            WindowPlacement(size: MainWindowGeometry.initialSize(
                dependencies?.preferences.savedMainWindowSize(),
                availableSize: context.defaultDisplay.visibleRect.size
            ))
        }
        .commands {
            if let dependencies { NyaEHCommands(preferences: dependencies.preferences, updateManager: dependencies.updateManager) }
        }
        Settings {
            if let dependencies {
                SettingsView(preferences: dependencies.preferences, store: dependencies.appModel.maintenance, localHighlightServer: dependencies.localHighlightServer, updateManager: dependencies.updateManager)
                    .managedFocusAppearance()
                    .preferredColorScheme(dependencies.preferences.themeMode.colorScheme)
                    .tint(dependencies.preferences.resolvedAccentColor)
                    .environment(\.nyaehAccentColor, dependencies.preferences.effectiveAccentColor)
            }
        }
    }

    private func mainContent(_ dependencies: NyaEHSceneDependencies) -> some View {
        let appModel = dependencies.appModel
        let preferences = dependencies.preferences
        let localHighlightServer = dependencies.localHighlightServer
        return
            ContentView(
                appModel: appModel,
                preferences: preferences,
                developmentConfiguration: developmentConfiguration
            )
                .managedFocusAppearance()
                .background {
                    if let runtime = try? TestRuntime.current.get() { TestWindowIdentity(name: runtime.name) }
                }
                .toolbar {
                    if let runtime = try? TestRuntime.current.get() {
                        ToolbarItem(placement: .principal) {
                            Text(runtime.name).font(.caption)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
                .frame(
                    minWidth: MainWindowGeometry.minimumContentSize.width,
                    minHeight: MainWindowGeometry.minimumContentSize.height
                )
                .background { MainWindowSizeObserver(preferences: preferences).allowsHitTesting(false) }
                .preferredColorScheme(preferences.themeMode.colorScheme)
                .tint(preferences.resolvedAccentColor)
                .environment(\.nyaehAccentColor, preferences.effectiveAccentColor)
                .task {
                    dependencies.updateManager?.start()
                    appModel.catalog.refresh()
                    if appModel.catalog.loadError == nil {
                        do { try TestRuntime.current.get()?.writeReady() }
                        catch { appModel.catalog.loadError = error.localizedDescription }
                    }
                    localHighlightServer.updateBooks(appModel.catalog.books)
                    if (try? TestRuntime.current.get())?.profile != "qa" { localHighlightServer.apply(preferences: preferences) }
                }
                .onChange(of: appModel.changeBus.revision) { _, _ in
                    localHighlightServer.updateBooks(appModel.catalog.books)
                }
                .onChange(of: preferences.isLocalHighlightServerEnabled) { _, _ in
                    if (try? TestRuntime.current.get())?.profile != "qa" { localHighlightServer.apply(preferences: preferences) }
                }
                .onChange(of: preferences.localHighlightServerPort) { _, _ in
                    if (try? TestRuntime.current.get())?.profile != "qa" { localHighlightServer.apply(preferences: preferences) }
                }
    }
}
