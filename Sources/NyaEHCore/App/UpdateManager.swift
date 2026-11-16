import Foundation
import Sparkle
import AppKit
import Observation

enum GitHubUpdateAccess: Equatable {
    case publicRepository
    case unavailable(String)
}

struct GitHubUpdateAccessService {
    static let accessCheckURL = URL(string: "https://api.github.com/repos/XKLZ/NyaEH-Public/contents/updates/appcast.xml?ref=main")!
    let requestStatus: @Sendable (URLRequest) async throws -> Int

    init(session: URLSession = .shared) {
        requestStatus = { request in
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return response.statusCode
        }
    }

    init(requestStatus: @escaping @Sendable (URLRequest) async throws -> Int) {
        self.requestStatus = requestStatus
    }

    func resolve() async -> GitHubUpdateAccess {
        var request = URLRequest(url: Self.accessCheckURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        do {
            let status = try await requestStatus(request)
            return status == 200 ? .publicRepository : .unavailable("GitHub HTTP \(status)")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}

@MainActor
@Observable
final class UpdateManager: NSObject, SPUUpdaterDelegate {
    static let feedURL = URL(string: "https://raw.githubusercontent.com/XKLZ/NyaEH-Public/main/updates/appcast.xml")!
    private let preferences: AppPreferences
    private let accessService: GitHubUpdateAccessService
    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startRequested = false
    @ObservationIgnored private var configurationTask: Task<Void, Never>?
    @ObservationIgnored private var settingsObservations: [NSKeyValueObservation] = []
    private(set) var access: GitHubUpdateAccess = .unavailable("")
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var allowsAutomaticUpdates = false

    init(preferences: AppPreferences, accessService: GitHubUpdateAccessService = GitHubUpdateAccessService()) {
        self.preferences = preferences
        self.accessService = accessService
        super.init()
        // Sparkle delegates are weak. The scene retains this manager for the app lifetime.
        refreshUpdateSettings()
        let updater = controller.updater
        settingsObservations = [
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshUpdateSettings() }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshUpdateSettings() }
            }
        ]
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        refreshUpdateSettings()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard controller.updater.allowsAutomaticUpdates else { return }
        controller.updater.automaticallyDownloadsUpdates = enabled
        refreshUpdateSettings()
    }

    private func refreshUpdateSettings() {
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
    }

    func start() {
        guard !startRequested else { return }
        startRequested = true
        configurationTask = Task { [weak self] in
            guard let self else { return }
            await self.configure()
        }
    }

    func checkForUpdates() {
        configurationTask?.cancel()
        configurationTask = Task { [weak self] in
            guard let self else { return }
            await self.configure()
            guard !Task.isCancelled else { return }
            if self.started && self.access == .publicRepository {
                self.controller.checkForUpdates(nil)
            } else {
                let alert = NSAlert()
                let localizer = self.preferences.localizer
                alert.messageText = localizer.string(.checkForUpdates)
                if case .unavailable(let message) = self.access, !message.isEmpty {
                    alert.informativeText = message
                } else {
                    alert.informativeText = localizer.string(.updateServiceUnavailable)
                }
                alert.runModal()
            }
        }
    }

    private func configure() async {
        let result = await accessService.resolve()
        guard !Task.isCancelled else { return }
        access = result
        guard result == .publicRepository else { return }
        if !started {
            controller.startUpdater()
            started = true
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL.absoluteString }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard access == .publicRepository else {
            throw NSError(domain: "NyaEH.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: preferences.localizer.string(.updateServiceUnavailable)])
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    }
}
