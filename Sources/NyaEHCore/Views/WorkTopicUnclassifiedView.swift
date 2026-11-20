import SwiftUI

struct WorkTopicUnclassifiedView: View {
    let books: [LibraryBook]
    let characters: [TagDisplaySummary]
    let workID: Tag.DatabaseID
    let store: TagDiscoveryStore
    var titleDisplayMode: BookTitleDisplayMode = .originalTitle
    let isTagTranslationEnabled: Bool
    let localizer: AppLocalizer
    let onSelectBook: (LibraryBook) -> Void

    @State private var editingBook: LibraryBook?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            Text(localizer.string(.workTopicUnclassified))
                .font(.title2.bold())
            ForEach(books) { book in
                HStack(spacing: 12) {
                    Button { onSelectBook(book) } label: {
                        HStack(spacing: 12) {
                            BookCoverThumbnail(book: book, width: 42, height: 56, cornerRadius: 5)
                            Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        BookCardMenu(book: book, titleDisplayMode: titleDisplayMode, localizer: localizer,
                                     selection: nil, beforeNavigation: nil, showDetail: onSelectBook)
                    }

                    Button(localizer.string(.workTopicAddCharacterTag)) { editingBook = book }
                }
                Divider()
            }
        }
        .padding(20)
        .sheet(item: $editingBook) { book in
            WorkCharacterTagPicker(book: book, titleDisplayMode: titleDisplayMode, workID: workID, characters: characters,
                                   store: store, isTagTranslationEnabled: isTagTranslationEnabled, localizer: localizer)
        }
    }
}

private struct WorkCharacterTagPicker: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let workID: Tag.DatabaseID
    let characters: [TagDisplaySummary]
    let store: TagDiscoveryStore
    let isTagTranslationEnabled: Bool
    let localizer: AppLocalizer

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [TagDisplaySummary] = []
    @State private var completedQuery: String?
    @State private var searchError: String?
    @State private var saveError: String?
    @State private var pendingTag: TagDisplaySummary?

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var workMatches: [TagDisplaySummary] {
        guard !searchText.isEmpty else { return characters }
        return characters.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchText) || $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.string(.workTopicAddCharacterTag)).font(.title2.bold())
            Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField(localizer.string(.workTopicSearchCharacters), text: $query)
                .textFieldStyle(.roundedBorder)
            let localMatches = workMatches
            let localIDs = Set(localMatches.map(\.id))
            let otherMatches = completedQuery == searchText ? results.filter { !localIDs.contains($0.id) } : []
            List {
                if !localMatches.isEmpty {
                    Section(localizer.string(.workTopicThisWorkCharacters)) {
                        ForEach(localMatches) { choice($0) }
                    }
                }
                if !otherMatches.isEmpty {
                    Section(localizer.string(.workTopicLibraryCharacters)) {
                        ForEach(otherMatches) { choice($0) }
                    }
                }
            }
            .overlay {
                if localMatches.isEmpty && otherMatches.isEmpty {
                    if !searchText.isEmpty, completedQuery != searchText {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(localizer.string(searchText.isEmpty ? .workTopicSearchCharacters : .tagSearchNoResults))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = saveError ?? searchError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                if pendingTag != nil { ProgressView().controlSize(.small) }
                Button(localizer.string(.cancel)) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .disabled(pendingTag != nil)
        .interactiveDismissDisabled(pendingTag != nil)
        .padding(20)
        .frame(width: 420, height: 390)
        .task(id: searchText) {
            let requestedQuery = searchText
            searchError = nil
            completedQuery = nil
            guard !requestedQuery.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
                let matches = try await store.catalog.searchCharacterTags(requestedQuery, isTagTranslationEnabled: isTagTranslationEnabled)
                try Task.checkCancellation()
                results = matches
                completedQuery = requestedQuery
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchError = error.localizedDescription
                completedQuery = requestedQuery
            }
        }
        .task(id: pendingTag?.id) {
            guard let chosen = pendingTag, let bookID = book.databaseID else { return }
            do {
                try await store.catalog.addCharacterTag(to: bookID, pair: .init(workID: workID, characterID: chosen.id),
                                                        isTagTranslationEnabled: isTagTranslationEnabled)
                guard !Task.isCancelled else { return }
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                saveError = error.localizedDescription
                pendingTag = nil
            }
        }
    }

    private func choice(_ character: TagDisplaySummary) -> some View {
        Button {
            saveError = nil
            pendingTag = character
        } label: {
            HStack {
                Text(character.displayText)
                if character.displayText != character.name {
                    Text(character.name).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func workTopicAssignmentFeedback(store: TagDiscoveryStore, workID: Tag.DatabaseID,
                                     localizer: AppLocalizer, onManage: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if store.catalog.unconfirmedCharacterAssignmentWorkID == workID {
                HStack {
                    Text(localizer.string(.workTopicTagNeedsConfirmation))
                    Spacer()
                    Button(localizer.string(.workCharacterManage)) {
                        store.catalog.unconfirmedCharacterAssignmentWorkID = nil
                        onManage()
                    }
                    Button(localizer.string(.workCharacterDone)) {
                        store.catalog.unconfirmedCharacterAssignmentWorkID = nil
                    }
                }
                .padding(12)
                .background(.regularMaterial)
            }
        }
    }
}
