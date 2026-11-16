import SwiftUI

struct WorkCharacterClaimBadge: View {
    let claim: WorkCharacterClaim
    let localizer: AppLocalizer

    static func description(for claim: WorkCharacterClaim, localizer: AppLocalizer) -> String {
        let title: String
        switch claim.source {
        case .manual: title = localizer.string(.workCharacterConfirmed)
        case .indexed: title = localizer.string(.workCharacterIndexed)
        case .automatic: title = localizer.string(.workCharacterAutomatic)
        }
        guard !claim.evidenceLabels.isEmpty else { return title }
        return "\(title) · \(localizer.string(.workCharacterEvidence)): \(claim.evidenceLabels.joined(separator: ", "))"
    }

    var body: some View {
        Text(localizer.string(.workCharacterAutomatic))
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .help(Self.description(for: claim, localizer: localizer))
            .accessibilityLabel(Self.description(for: claim, localizer: localizer))
            .allowsHitTesting(false)
    }
}

private struct WorkCharacterClaimHint: ViewModifier {
    let claim: WorkCharacterClaim?
    let localizer: AppLocalizer

    func body(content: Content) -> some View {
        if let claim {
            content.accessibilityHint(WorkCharacterClaimBadge.description(for: claim, localizer: localizer))
        } else {
            content
        }
    }
}

extension View {
    func workCharacterClaimHint(_ claim: WorkCharacterClaim?, localizer: AppLocalizer) -> some View {
        modifier(WorkCharacterClaimHint(claim: claim, localizer: localizer))
    }
}

struct WorkCharacterManagementSheet: View {
    @Bindable var store: TagDiscoveryStore
    let workID: Tag.DatabaseID
    let isTagTranslationEnabled: Bool
    let localizer: AppLocalizer

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [WorkCharacterCandidate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private struct AutomaticItem: Identifiable {
        let book: LibraryBook
        let character: TagDisplaySummary
        let claim: WorkCharacterClaim

        var id: String { "\(book.id)-\(character.id)" }
    }

    private var automaticItems: [AutomaticItem] {
        (store.catalog.workDetail(tagID: workID)?.sections ?? []).flatMap { section -> [AutomaticItem] in
            guard let character = section.character else { return [] }
            return section.books.compactMap { book in
                guard let bookID = book.databaseID,
                      let claim = section.claimsByBookID[bookID],
                      claim.source == .automatic else { return nil }
                return AutomaticItem(book: book, character: character, claim: claim)
            }
        }
    }

    private var unclassifiedBooks: [LibraryBook] {
        store.catalog.workDetail(tagID: workID)?.sections.first { $0.character == nil }?.books ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(localizer.string(.workCharacterManage))
                    .font(.title2.bold())
                Spacer()
                Button(localizer.string(.workCharacterDone)) { dismiss() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isLoading {
                        ProgressView()
                    }

                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }

                    if !automaticItems.isEmpty {
                        Text(localizer.string(.workCharacterAutomatic)).font(.headline)
                        ForEach(automaticItems) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(item.book.title) → \(item.character.displayText)")
                                    Text("\(localizer.string(.workCharacterEvidence)): \(item.claim.evidenceLabels.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(localizer.string(.workCharacterConfirmed)) {
                                    setDecision(.confirmed, characterID: item.character.id)
                                }
                                Button(localizer.string(.workCharacterDismissAutomatic)) {
                                    dismissAutomatic(item)
                                }
                            }
                        }
                    }

                    if !unclassifiedBooks.isEmpty {
                        Text(localizer.string(.workCharacterUnclassified)).font(.headline)
                        ForEach(unclassifiedBooks) { book in
                            Text(book.title).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 440)
        .task(id: "\(workID)-\(isTagTranslationEnabled)") { await loadCandidates() }
    }

    private func candidateRow(_ candidate: WorkCharacterCandidate) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.character.displayText).fontWeight(.medium)
                Text(status(for: candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(localizer.string(.workCharacterConfirmed)) {
                setDecision(.confirmed, characterID: candidate.id)
            }
            Button(localizer.string(.workCharacterExclude)) {
                setDecision(.excluded, characterID: candidate.id)
            }
            if candidate.decision != nil {
                Button(localizer.string(.workCharacterClearDecision)) {
                    setDecision(nil, characterID: candidate.id)
                }
            }
        }
    }

    private func status(for candidate: WorkCharacterCandidate) -> String {
        switch candidate.decision {
        case .confirmed: localizer.string(.workCharacterConfirmed)
        case .excluded: localizer.string(.workCharacterExclude)
        case nil:
            if candidate.hasIndexedEvidence { localizer.string(.workCharacterIndexed) }
            else if candidate.automaticBookCount > 0 { localizer.string(.workCharacterAutomatic) }
            else { localizer.string(.workCharacterUnclassified) }
        }
    }

    private func setDecision(_ decision: WorkCharacterManualDecision?, characterID: Tag.DatabaseID) {
        Task {
            do {
                try await store.catalog.setWorkCharacterDecision(
                    decision, pair: WorkCharacterPair(workID: workID, characterID: characterID)
                )
                store.catalog.reloadWorkDetail(tagID: workID, isTagTranslationEnabled: isTagTranslationEnabled)
                await loadCandidates()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func dismissAutomatic(_ item: AutomaticItem) {
        guard let bookID = item.book.databaseID else { return }
        Task {
            do {
                try await store.catalog.setAutomaticClaimSuppressed(
                    true, bookID: bookID,
                    pair: WorkCharacterPair(workID: workID, characterID: item.character.id)
                )
                store.catalog.reloadWorkDetail(tagID: workID, isTagTranslationEnabled: isTagTranslationEnabled)
                await loadCandidates()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func loadCandidates() async {
        isLoading = true
        defer { isLoading = false }
        do {
            candidates = try await store.catalog.workCharacterCandidates(
                tagID: workID, isTagTranslationEnabled: isTagTranslationEnabled
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
