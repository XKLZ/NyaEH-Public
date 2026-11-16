// 本文件实现书籍卡片的封面、标题和状态摘要，是多个列表页面共用的展示单元。

import SwiftUI

struct BookCardView: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    var metrics: BookCardMetrics = .default
    var showsUnobstructedCover = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isBookCardHovered) private var isHovered

    private var hoverVisualState: BookCardHoverVisualState {
        BookCardHoverVisualState.resolve(isHovered: isHovered, reduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(alignment: .center, spacing: metrics.contentSpacing) {
            coverView

            BookCardScrollingTitleView(
                title: BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode),
                metrics: metrics
            )

            BookCardInfoIconRow(book: book, localizer: localizer, showsMarkedStatus: showsUnobstructedCover)
                .frame(width: metrics.cardWidth, height: metrics.infoRowHeight, alignment: .center)

            BookRatingStarsView(rating: book.rating, localizer: localizer, height: metrics.ratingHeight)
                .frame(width: metrics.cardWidth, alignment: .center)
        }
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var coverView: some View {
        BookCoverThumbnail(
            book: book,
            width: metrics.cardWidth,
            height: metrics.coverHeight,
            cornerRadius: 8,
            fitsEntireImage: showsUnobstructedCover
        )
            .scaleEffect(showsUnobstructedCover ? 1 : hoverVisualState.coverScale)
            .frame(width: metrics.cardWidth, height: metrics.coverHeight)
            .clipShape(RoundedRectangle(cornerRadius: showsUnobstructedCover ? 0 : 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if book.mark && !showsUnobstructedCover {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(5)
                        .background(.regularMaterial, in: Circle())
                        .padding(6)
                }
            }
    }
}

private struct BookCardScrollingTitleView: View {
    let title: String
    let metrics: BookCardMetrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.searchScrollActivity) private var scrollActivity
    @State private var isHovering = false
    @State private var hoverGate = SearchScrollHoverGate()
    @State private var scrollOffset: CGFloat = 0
    @State private var titleWidth: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?

    private var overflowWidth: CGFloat {
        max(titleWidth - metrics.cardWidth, 0)
    }

    private var canScroll: Bool {
        BookCardTitleScrollMetrics.canStart(
            isHovering: isHovering,
            titleWidth: titleWidth,
            cardWidth: metrics.cardWidth,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        titleContent
        .frame(width: metrics.cardWidth, height: metrics.titleHeight, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
        .help(title)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let canActivate = hoverGate.pointerBecameActive(
                    at: location,
                    isScrolling: scrollActivity.isScrolling
                )
                guard canActivate, !isHovering else { return }
                isHovering = true
                updateScrollAnimation()
            case .ended:
                hoverGate.pointerEnded()
                guard isHovering else { return }
                isHovering = false
                updateScrollAnimation()
            }
        }
        .onChange(of: titleWidth) { _, _ in
            updateScrollAnimation()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateScrollAnimation()
        }
        .onChange(of: scrollActivity.isScrolling) { _, isScrolling in
            hoverGate.scrollActivityChanged(isScrolling: isScrolling)
            guard isScrolling else { return }
            isHovering = false
            cancelScroll(resetOffset: true)
        }
        .onDisappear {
            cancelScroll(resetOffset: true)
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        ZStack(alignment: .leading) {
            if canScroll {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: scrollOffset)
            } else {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.cardWidth, alignment: .center)
            }

            if isHovering && !reduceMotion {
                titleWidthReader
            }
        }
    }

    private var titleWidthReader: some View {
        Text(title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BookCardTitleWidthPreferenceKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(BookCardTitleWidthPreferenceKey.self) { width in
                titleWidth = width
            }
    }

    private func updateScrollAnimation() {
        guard canScroll else {
            cancelScroll(resetOffset: true)
            return
        }

        scrollTask?.cancel()
        scrollOffset = 0
        let overflowWidth = overflowWidth
        let duration = BookCardTitleScrollMetrics.duration(forOverflow: overflowWidth)
        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, canScroll else {
                return
            }

            withAnimation(.linear(duration: duration)) {
                scrollOffset = -overflowWidth
            }

            try? await Task.sleep(for: .milliseconds(Int(duration * 1_000)))
            guard !Task.isCancelled, canScroll else {
                return
            }

            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.snappy(duration: 0.22)) {
                scrollOffset = 0
            }
            scrollTask = nil
        }
    }

    private func cancelScroll(resetOffset: Bool) {
        scrollTask?.cancel()
        scrollTask = nil
        guard resetOffset else {
            return
        }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            scrollOffset = 0
        }
    }
}

enum BookCardTitleScrollMetrics {
    static let minimumOverflowWidth: CGFloat = 1
    static let pointsPerSecond: CGFloat = 18
    static let minimumDuration = 2.4

    static func canStart(
        isHovering: Bool,
        titleWidth: CGFloat,
        cardWidth: CGFloat,
        reduceMotion: Bool
    ) -> Bool {
        isHovering && !reduceMotion && overflowWidth(titleWidth: titleWidth, cardWidth: cardWidth) > minimumOverflowWidth
    }

    static func overflowWidth(titleWidth: CGFloat, cardWidth: CGFloat) -> CGFloat {
        max(titleWidth - cardWidth, 0)
    }

    static func duration(forOverflow overflowWidth: CGFloat) -> Double {
        max(Double(overflowWidth / pointsPerSecond), minimumDuration)
    }
}

private struct BookCardTitleWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BookCardInfoIconRow: View {
    let book: LibraryBook
    let localizer: AppLocalizer
    let showsMarkedStatus: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(languageFlag(for: book.languageCode))
                .font(.caption2)
                .help(languageText(for: book.languageCode))

            BookCardStatusIcon(
                systemImage: "paintpalette",
                title: localizer.string(.statusColorShort),
                isActive: book.isFullColor
            )

            BookCardStatusIcon(
                systemImage: "eye",
                title: localizer.string(.statusCensorshipShort),
                isActive: book.censorship == "uncensored"
            )

            HStack(spacing: 3) {
                Image(systemName: "doc.text")
                Text(pageText)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(localizer.string(.pages))

            if showsMarkedStatus && book.mark {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .help(localizer.string(.markedStatus))
                    .accessibilityLabel(localizer.string(.markedStatus))
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }

    private var pageText: String {
        guard let pages = book.pages ?? book.fileCount else {
            return "-"
        }
        return "\(pages)p"
    }

    private func languageText(for code: String) -> String {
        code == "unknown" ? localizer.string(.unknown) : code.capitalized
    }

    private func languageFlag(for code: String) -> String {
        switch code.lowercased() {
        case "chinese":
            return "🇨🇳"
        case "japanese":
            return "🇯🇵"
        case "english":
            return "🇬🇧"
        case "korean":
            return "🇰🇷"
        case "spanish":
            return "🇪🇸"
        case "french":
            return "🇫🇷"
        case "german":
            return "🇩🇪"
        case "italian":
            return "🇮🇹"
        default:
            return "🏳️"
        }
    }
}

private struct BookCardStatusIcon: View {
    let systemImage: String
    let title: String
    let isActive: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.38))
            .frame(width: 14, height: 14)
            .help(title)
    }
}

struct BookRatingStarsView: View {
    let rating: Double?
    let localizer: AppLocalizer
    var starFont: Font = .caption
    var spacing: CGFloat = 2
    var height: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            let symbols = BookRatingStarsModel(rating: rating).symbols
            let symbolSize = max(height * 0.72, 10)
            let contentWidth = symbolSize * CGFloat(symbols.count)
                + spacing * CGFloat(max(symbols.count - 1, 0))
            var x = max((size.width - contentWidth) / 2, 0)
            for symbol in symbols {
                var image = context.resolve(Image(systemName: symbol))
                image.shading = .color(starColor)
                context.draw(
                    image,
                    in: CGRect(
                        x: x,
                        y: (size.height - symbolSize) / 2,
                        width: symbolSize,
                        height: symbolSize
                    )
                )
                x += symbolSize + spacing
            }
        }
        .frame(width: canvasWidth, height: height, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var canvasWidth: CGFloat {
        max(height * 0.8, 12) * 5 + spacing * 4
    }

    private var starColor: Color {
        rating == nil ? .secondary.opacity(0.55) : .yellow
    }

    private var accessibilityText: String {
        if let rating {
            return "\(localizer.string(.rating)) \(String(format: "%.2f", rating))"
        }
        return localizer.string(.unrate)
    }

}

struct BookRatingStarsModel: Equatable, Sendable {
    let symbols: [String]

    init(rating: Double?) {
        symbols = (1...5).map { index in
            guard let rating else {
                return "star"
            }
            let threshold = Double(index)
            if rating >= threshold {
                return "star.fill"
            }
            if rating >= threshold - 0.5 {
                return "star.leadinghalf.filled"
            }
            return "star"
        }
    }
}

struct BookCardButton: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    var metrics: BookCardMetrics = .default
    var showsUnobstructedCover = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BookCardView(
                book: book,
                titleDisplayMode: titleDisplayMode,
                localizer: localizer,
                metrics: metrics,
                showsUnobstructedCover: showsUnobstructedCover
            )
        }
        .buttonStyle(.plain)
        .bookCardHoverSurface()
    }
}

struct LibraryDisplayItemCardButton: View {
    let item: LibraryDisplayItem
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    var metrics: BookCardMetrics = .default
    let action: (LibraryDisplayItem) -> Void

    var body: some View {
        Button {
            action(item)
        } label: {
            LibraryDisplayItemCardView(
                item: item,
                titleDisplayMode: titleDisplayMode,
                localizer: localizer,
                metrics: metrics
            )
        }
        .buttonStyle(.plain)
        .bookCardHoverSurface()
    }
}

struct LibraryDisplayItemCardView: View {
    let item: LibraryDisplayItem
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    var metrics: BookCardMetrics = .default
    var showsUnobstructedCover = false

    var body: some View {
        switch item {
        case .book(let book):
            BookCardView(
                book: book,
                titleDisplayMode: titleDisplayMode,
                localizer: localizer,
                metrics: metrics,
                showsUnobstructedCover: showsUnobstructedCover
            )
        case .collection(let item):
            CollectionCardView(
                item: item,
                titleDisplayMode: titleDisplayMode,
                localizer: localizer,
                metrics: metrics,
                showsUnobstructedCover: showsUnobstructedCover
            )
        }
    }
}

private struct CollectionCardView: View {
    let item: BookCollectionDisplayItem
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let metrics: BookCardMetrics
    let showsUnobstructedCover: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isBookCardHovered) private var isHovered

    private var hoverVisualState: BookCardHoverVisualState {
        BookCardHoverVisualState.resolve(isHovered: isHovered, reduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(alignment: .center, spacing: metrics.contentSpacing) {
            ZStack {
                ForEach(Array(item.books.prefix(3).enumerated()), id: \.element.id) { offset, book in
                    collectionCover(book: book)
                        .offset(x: CGFloat(offset) * 6, y: CGFloat(offset) * -4)
                        .zIndex(showsUnobstructedCover ? -Double(offset) : 0)
                        .shadow(color: .black.opacity(0.14), radius: 5, x: 0, y: 3)
                }
            }
            .frame(width: metrics.cardWidth, height: metrics.coverHeight)
            .scaleEffect(hoverVisualState.collectionCoverScale)
            .overlay(alignment: .topLeading) {
                if !showsUnobstructedCover {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                }
            }

            BookCardScrollingTitleView(title: item.collection.name, metrics: metrics)

            HStack(spacing: 4) {
                if showsUnobstructedCover {
                    Image(systemName: "rectangle.stack.fill")
                        .accessibilityHidden(true)
                }
                Text(localizer.collectionBookCount(item.books.count))
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: metrics.cardWidth, height: metrics.infoRowHeight, alignment: .center)
        }
        .frame(width: metrics.cardWidth, height: collectionCardHeight, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var collectionCardHeight: CGFloat {
        metrics.coverHeight
            + metrics.titleHeight
            + metrics.infoRowHeight
            + metrics.contentSpacing * 2
    }

    @ViewBuilder
    private func collectionCover(book: LibraryBook) -> some View {
        BookCoverThumbnail(
            book: book,
            width: metrics.cardWidth - 10,
            height: metrics.coverHeight - 12,
            cornerRadius: 8,
            fitsEntireImage: showsUnobstructedCover
        )
    }
}

struct CardSizeSliderControl: View {
    @Binding var cardWidth: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: sliderValue, in: Double(BookCardMetrics.minimumWidth)...Double(BookCardMetrics.maximumWidth), step: Double(BookCardMetrics.step))
                .frame(width: 132)

            Image(systemName: "square.grid.3x3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sliderValue: Binding<Double> {
        Binding {
            Double(cardWidth)
        } set: { newValue in
            cardWidth = BookCardMetrics.normalizedWidth(Int(newValue.rounded()))
        }
    }
}

extension View {
    func cardControlCapsule() -> some View {
        overlay {
            Capsule()
                .stroke(.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}
