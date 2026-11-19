import AppKit
import SwiftUI

enum CardGroupDestination: Equatable {
    case series(BookCollection.ID)
    case manageSeries(BookCollection.ID)
    case manageVersions(BookVersionGroup.ID)
}

struct CardGroupNavigation: Sendable {
    let open: @MainActor (CardGroupDestination) -> Void
}

@MainActor protocol BookCardFileRevealing {
    func revealFile(_ book: LibraryBook)
}

extension EnvironmentValues {
    @Entry var navigateCardGroup: CardGroupNavigation?
}

enum CardMenuCommand: Hashable {
    case details, read, resume, favorite, unfavorite, markRead, markUnread
    case series, owningSeries, manageSeries, manageVersions, copyTitle, source, finder, select, deselect

    var label: L10nKey {
        switch self {
        case .details: .cardViewDetails
        case .read: .readerStart
        case .resume: .readerContinue
        case .favorite: .batchMark
        case .unfavorite: .batchUnmark
        case .markRead: .cardMarkRead
        case .markUnread: .cardMarkUnread
        case .owningSeries: .cardOwningSeries
        case .series: .cardViewSeries
        case .manageSeries: .cardManageSeries
        case .manageVersions: .cardManageVersions
        case .copyTitle: .copyTitle
        case .source: .cardOpenSource
        case .finder: .managementShowInFinder
        case .select: .batchSelect
        case .deselect: .cardDeselect
        }
    }

    static func sections(book: LibraryBook, reading: BookReadingState?, canNavigate: Bool,
                         canReveal: Bool, selected: Bool?) -> [[Self]] {
        let read: Self = BookDetailReadingActionPolicy.titleKey(for: reading) == .readerContinue ? .resume : .read
        var groups: [Self] = []
        if canNavigate {
            if book.collectionID != nil { groups += [.owningSeries, .manageSeries] }
            if book.versionGroupID != nil { groups.append(.manageVersions) }
        }
        var files: [Self] = [.copyTitle]
        if BookCardMetadata(book: book).url != nil { files.append(.source) }
        if canReveal { files.append(.finder) }
        return [[.details, read], [book.mark ? .unfavorite : .favorite,
                                   reading?.isCompleted == true ? .markUnread : .markRead],
                groups, files, selection(selected)].filter { !$0.isEmpty }
    }

    func destination(for book: LibraryBook) -> CardGroupDestination? {
        switch self {
        case .owningSeries: book.collectionID.map { .series(String($0)) }
        case .manageSeries: book.collectionID.map { .manageSeries(String($0)) }
        case .manageVersions: book.versionGroupID.map { .manageVersions(String($0)) }
        default: nil
        }
    }

    static func seriesSections(selected: Bool?) -> [[Self]] {
        [[.series, .manageSeries], selection(selected)].filter { !$0.isEmpty }
    }

    private static func selection(_ selected: Bool?) -> [Self] {
        selected.map { [$0 ? .deselect : .select] } ?? []
    }
}

struct CardMenuItems: View {
    let sections: [[CardMenuCommand]]
    let localizer: AppLocalizer
    let perform: (CardMenuCommand) -> Void

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self) { command in
                Button(localizer.string(command.label)) { perform(command) }
            }
        }
    }
}

struct BookCardMenu: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let selection: BookCardSelection?
    let beforeNavigation: (() -> Void)?
    let showDetail: (LibraryBook) -> Void

    @Environment(\.bookCardCatalog) private var catalog
    @Environment(\.bookCardActions) private var actions
    @Environment(\.navigateCardGroup) private var navigate
    private var fileActions: (any BookCardFileRevealing)? { actions as? any BookCardFileRevealing }
    @Environment(\.openURL) private var openURL

    var body: some View {
        CardMenuItems(sections: CardMenuCommand.sections(book: book, reading: catalog?.readingState(for: book),
                      canNavigate: navigate != nil, canReveal: fileActions != nil, selected: selection?.isSelected),
                      localizer: localizer, perform: perform)
    }

    private func perform(_ command: CardMenuCommand) {
        guard let target = catalog?.book(id: book.id) else { return }
        switch command {
        case .details: showDetail(target)
        case .read, .resume: actions?.read(target)
        case .favorite, .unfavorite: catalog?.setCardMarked(command == .favorite, book: target)
        case .markRead, .markUnread: catalog?.setCardCompleted(command == .markRead, book: target)
        case .owningSeries, .manageSeries, .manageVersions:
            guard let destination = command.destination(for: target) else { return }
            beforeNavigation?()
            navigate?.open(destination)
        case .series: break // Only used on collection summary cards.
        case .copyTitle:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(BookTitleFormatter.displayTitle(for: target, mode: titleDisplayMode), forType: .string)
        case .source:
            if let url = BookCardMetadata(book: target).url { openURL(url) }
        case .finder: fileActions?.revealFile(target)
        case .select, .deselect: selection?.toggle()
        }
    }
}
