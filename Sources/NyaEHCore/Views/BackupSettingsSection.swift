import AppKit
import SwiftUI

struct BackupSettingsSection: View {
    @Bindable var store: MaintenanceStore
    let localizer: AppLocalizer

    @State private var listing = BackupListing()
    @State private var revision = 0
    @State private var selected: Set<UUID> = []
    @State private var includeImages = false
    @State private var pendingRestore: BackupCommand?
    @State private var pendingDelete: [BackupEntry]?
    @State private var readError: String?

    var body: some View {
        Section(localizer.string(.backupAndRestore)) {
            Text(localizer.string(.backupDescription)).font(.footnote).foregroundStyle(.secondary)
            LabeledContent(localizer.string(.backupLocation)) {
                Text(listing.destination).font(.caption).textSelection(.enabled)
            }
            HStack {
                Button(localizer.string(.backupChoose), action: chooseDestination)
                    .accessibilityIdentifier("backup.chooseLocation")
                Button(localizer.string(.backupLocal)) { run(.destination(nil)) }
            }
            Toggle(localizer.string(.backupImages), isOn: $includeImages)
            HStack {
                Button(localizer.string(.exportBackup), action: export)
                Button(localizer.string(.importFromThisApp), action: restoreFile)
            }
            if store.isManagingBackup { ProgressView().controlSize(.small) }
            if listing.pending { Text(localizer.string(.backupDue)) }
            if let issue = readError ?? store.backupMessage ?? listing.issue {
                Text(issue).font(.footnote).textSelection(.enabled)
            }
        }
        .disabled(store.isManagingBackup)

        Section(localizer.string(.backupManaged)) {
            if listing.entries.isEmpty { Text(localizer.string(.backupEmpty)).foregroundStyle(.secondary) }
            rows(for: listing.entries.filter { !$0.legacy })
            if listing.entries.contains(where: \.legacy) {
                Text(localizer.string(.backupLegacy)).font(.subheadline.weight(.semibold))
                rows(for: listing.entries.filter(\.legacy))
            }
            LabeledContent(localizer.string(.backupTotal), value: size(listing.entries))
            HStack {
                Button(localizer.string(.restore)) {
                    if let id = selected.first { pendingRestore = .restoreEntry(id) }
                }
                .disabled(selected.count != 1)
                .accessibilityIdentifier("backup.restoreSelection")
                Button(localizer.string(.moveToTrash), role: .destructive) {
                    pendingDelete = listing.entries.filter { selected.contains($0.id) }
                }
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("backup.trashSelection")
            }
        }
        .disabled(store.isManagingBackup)
        .onReceive(NotificationCenter.default.publisher(for: BackupInventory.didChange).receive(on: RunLoop.main)) { _ in revision += 1 }
        .task(id: revision) {
            guard let backups = store.backups else { return }
            do {
                let result = try await Task.detached(priority: .utility) { try backups.listing() }.value
                try Task.checkCancellation()
                listing = result
                selected.formIntersection(result.entries.map(\.id))
                readError = nil
            } catch { if !Task.isCancelled { readError = error.localizedDescription } }
        }
        .confirmationDialog(localizer.string(.confirmRestore), isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        ), presenting: pendingRestore) { command in
            Button(localizer.string(.restore), role: .destructive) { run(command) }
        } message: { _ in Text(localizer.string(.restoreWarning)) }
        .confirmationDialog(localizer.string(.moveToTrash), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { items in
            Button(localizer.string(.moveToTrash), role: .destructive) { run(.delete(Set(items.map(\.id)))) }
        } message: { items in
            Text(String(format: localizer.string(.backupDeleteFormat), items.count, size(items)))
        }
    }

    private func rows(for items: [BackupEntry]) -> some View {
        ForEach(items) { item in
            Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                if value { selected.insert(item.id) } else { selected.remove(item.id) }
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(localizer.string(item.kind.label))
                        Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
                    }
                    Text([size([item]), localizer.string(item.includesImages ? .backupHasImages : .backupDBOnly),
                          listing.paths[item.id] ?? ""].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if item.pendingRemoval { Text(localizer.string(.backupRemovePending)).font(.caption) }
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("backup.entry." + item.id.uuidString)
        }
    }

    private func size(_ entries: [BackupEntry]) -> String {
        ByteCountFormatter.string(fromByteCount: entries.reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }

    private func run(_ command: BackupCommand) { store.catalog.manageBackup(command, localizer: localizer) }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { run(.destination(url)) }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NyaEH-Backup.nyaehbackup"
        if panel.runModal() == .OK, let url = panel.url { run(.export(url, images: includeImages)) }
    }

    private func restoreFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { pendingRestore = .restoreFile(url) }
    }
}

private extension LibraryBackupKind {
    var label: L10nKey {
        switch self {
        case .automatic: .backupAutoKind
        case .daily: .backupDaily
        case .weekly: .backupWeekly
        case .preImport: .backupImport
        case .preMigration: .backupMigration
        case .preRestore: .backupRestore
        case .preRepair: .backupRepair
        case .manual: .exportBackup
        }
    }
}
