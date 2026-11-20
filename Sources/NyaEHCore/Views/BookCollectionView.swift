// 本文件实现可复用的书籍集合展示，把分页、卡片宽度和打开详情动作交给调用方配置。

import AppKit
import SwiftUI

struct BookCollectionView: View {
    @Bindable var store: CatalogStore
    let filter: LibraryFilter
    let metadataBatchConfiguration: MetadataBatchConfiguration
    let titleDisplayMode: BookTitleDisplayMode
    @Binding var pageSize: Int
    let localizer: AppLocalizer
    let onSelect: (LibraryDisplayItem) -> Void

    @State private var page = 1

    private var pageItems: [LibraryDisplayItem] {
        Pagination.pageItems(store.filteredDisplayItems, page: page, pageSize: pageSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if filter == .unscanned {
                    MetadataBatchControlRow(
                        store: store,
                        books: store.filteredBooks,
                        configuration: metadataBatchConfiguration,
                        titleDisplayMode: titleDisplayMode,
                        localizer: localizer
                    )
                }

                if let loadError = store.loadError {
                    ContentUnavailableView(
                        localizer.string(.unknown),
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if store.filteredDisplayItems.isEmpty {
                    ContentUnavailableView(
                        localizer.string(.noBooks),
                        systemImage: "books.vertical",
                        description: Text(localizer.string(.importedBooksDescription))
                    )
                } else {
                    ForEach(pageItems) { item in
                        Button {
                            if let book = item.representativeBook {
                                store.selectedBookID = book.id
                            }
                            onSelect(item)
                        } label: {
                            LibraryDisplayItemRowView(item: item, titleDisplayMode: titleDisplayMode, localizer: localizer)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            PaginationControls(
                page: $page,
                pageSize: $pageSize,
                itemCount: store.filteredDisplayItems.count,
                localizer: localizer
            )
            .padding(12)
        }
        .navigationTitle(localizer.string(filter.titleKey))
        .onAppear {
            store.filter = filter
        }
        .onChange(of: filter) { _, newValue in
            store.filter = newValue
            page = 1
        }
        .onChange(of: store.searchText) { _, _ in
            page = 1
        }
        .onChange(of: pageSize) { _, _ in
            page = 1
        }
        .onChange(of: store.filteredDisplayItems.count) { _, _ in
            page = Pagination.clampedPage(page, itemCount: store.filteredDisplayItems.count, pageSize: pageSize)
        }
    }
}

struct LibraryDisplayItemRowView: View {
    let item: LibraryDisplayItem
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer

    var body: some View {
        switch item {
        case .book(let book):
            BookRowView(book: book, titleDisplayMode: titleDisplayMode, localizer: localizer)
        case .collection(let item):
            HStack(spacing: 12) {
                CollectionRowThumbnail(books: item.books)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.collection.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(localizer.collectionBookCount(item.books.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct CollectionRowThumbnail: View {
    let books: [LibraryBook]

    var body: some View {
        ZStack {
            ForEach(Array(books.prefix(2).enumerated()), id: \.element.id) { offset, book in
                BookCoverThumbnail(book: book, width: 40, height: 56, cornerRadius: 5)
                    .offset(x: CGFloat(offset) * 6)
            }
        }
        .frame(width: 48, height: 60)
    }
}

struct MetadataBatchControlRow: View {
    @Bindable var store: CatalogStore
    let books: [LibraryBook]
    let configuration: MetadataBatchConfiguration
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.startMetadataBatch(
                        books: books,
                        configuration: configuration,
                        titleDisplayMode: titleDisplayMode,
                        localizer: localizer
                    )
                } label: {
                    Label(localizer.string(.metadataBatchFetch), systemImage: "arrow.down.doc")
                }
                .disabled(store.metadataBatchProgress.state == .running)

                if store.metadataBatchProgress.state == .running {
                    Button {
                        store.pauseMetadataBatch()
                    } label: {
                        Label(localizer.string(.metadataBatchPause), systemImage: "pause")
                    }
                } else if store.metadataBatchProgress.state == .paused {
                    Button {
                        store.resumeMetadataBatch(localizer: localizer)
                    } label: {
                        Label(localizer.string(.metadataBatchResume), systemImage: "play")
                    }
                }

                if store.metadataBatchProgress.isActive {
                    Button(role: .cancel) {
                        store.cancelMetadataBatch()
                    } label: {
                        Label(localizer.string(.metadataBatchCancel), systemImage: "xmark")
                    }
                }
            }

            Text(progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let lastError = store.metadataBatchProgress.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private var progressText: String {
        let progress = store.metadataBatchProgress
        var parts = [
            "\(localizer.string(.metadataBatchProgress)): \(progress.processed)/\(progress.total)",
            "OK \(progress.succeeded)",
            "Fail \(progress.failed)",
            "Skip \(progress.skipped)"
        ]

        if let currentTitle = progress.currentTitle {
            parts.append(currentTitle)
        }
        if let nextRequestAt = progress.nextRequestAt {
            let seconds = max(0, Int(nextRequestAt.timeIntervalSinceNow.rounded(.up)))
            parts.append("Next \(seconds)s")
        }

        return parts.joined(separator: " · ")
    }
}

private struct BookRowView: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer

    var body: some View {
        HStack(spacing: 12) {
            BookCoverThumbnail(book: book, width: 44, height: 60, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                    .font(.headline)
                    .lineLimit(1)

                Text(book.filepath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if book.mark {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                }

                BookStatusBadge(status: book.status, exist: book.exist, localizer: localizer)
            }
        }
        .padding(.vertical, 4)
    }
}

struct BookCoverThumbnailLoadRequest: Hashable {
    let coverPath: String?
    let pixelBucket: Int
}

enum BookCoverThumbnailImagePolicy {
    static func canDisplay(loadedPath: String?, for request: BookCoverThumbnailLoadRequest) -> Bool {
        guard let coverPath = request.coverPath else {
            return false
        }
        return loadedPath == coverPath
    }

    static func satisfies(
        loadedPath: String?,
        loadedPixelBucket: Int?,
        request: BookCoverThumbnailLoadRequest
    ) -> Bool {
        guard canDisplay(loadedPath: loadedPath, for: request),
              let loadedPixelBucket else {
            return false
        }
        return loadedPixelBucket >= request.pixelBucket
    }

    static func shouldAcceptResponse(
        path: String,
        pixelBucket: Int,
        currentPath: String?,
        currentPixelBucket: Int?
    ) -> Bool {
        guard currentPath == path, let currentPixelBucket else {
            return true
        }
        return pixelBucket >= currentPixelBucket
    }
}

struct BookCoverThumbnail: View {
    let book: LibraryBook
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let fitsEntireImage: Bool
    let showsFitBackground: Bool
    let perspectivePreview: Bool

    @Environment(\.coverPrivacyRule) private var privacy
    @State private var loadedCover: LoadedCoverState?

    init(book: LibraryBook, width: CGFloat, height: CGFloat, cornerRadius: CGFloat, fitsEntireImage: Bool = false,
         showsFitBackground: Bool = true, perspectivePreview: Bool = false) {
        self.book = book
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.fitsEntireImage = fitsEntireImage
        self.showsFitBackground = showsFitBackground
        self.perspectivePreview = perspectivePreview

        let pixelBucket = Self.targetPixelBucket(width: width, height: height)
        if let coverPath = book.coverPath,
           let cached = CoverImageCache.shared.cachedImage(
            for: coverPath,
            minimumPixelBucket: pixelBucket
           ) {
            _loadedCover = State(initialValue: LoadedCoverState(
                image: cached.image,
                path: coverPath,
                pixelBucket: cached.pixelBucket
            ))
        } else {
            _loadedCover = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if fitsEntireImage {
                thumbnail
            } else {
                thumbnail.clipShape(.rect(cornerRadius: cornerRadius))
            }
        }
        .task(id: loadRequest) {
            await loadImage(for: loadRequest)
        }
    }

    private var thumbnail: some View {
        let bounds = CGSize(width: width, height: height)
        let image = currentImage
        let mode = BookCoverThumbnailDisplayMode.resolve(imageSize: image?.size ?? .zero, fitsEntireImage: fitsEntireImage)
        let size = mode.imagePlane(imageSize: image?.size ?? .zero, bounds: bounds)
        let radius = mode == .fit && !fitsEntireImage ? 0 : cornerRadius
        return Group {
            if let image {
                let artwork = Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: mode == .fill ? .fill : .fit)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                if privacy.mode != .off || perspectivePreview {
                    CoverPrivacySurface(context: .init(bookID: book.id, path: book.coverPath, rule: privacy),
                                        width: size.width, height: size.height, cornerRadius: radius,
                                        perspectivePreview: perspectivePreview) { artwork }
                } else {
                    artwork.clipShape(.rect(cornerRadius: radius))
                }
            } else if privacy.mode == .conceal {
                CoverPrivacySurface(context: .init(bookID: book.id, path: book.coverPath, rule: privacy),
                                    width: width, height: height, cornerRadius: cornerRadius) {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height, alignment: showsFitBackground ? .center : .leading)
        .background {
            if showsFitBackground && (image == nil || mode == .fit) {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary)
            }
        }
    }

    private var currentImage: NSImage? {
        if BookCoverThumbnailImagePolicy.canDisplay(
            loadedPath: loadedCover?.path,
            for: loadRequest
        ), let loadedCover {
            return loadedCover.image
        }
        return nil
    }

    private var targetPixelBucket: Int {
        Self.targetPixelBucket(width: width, height: height)
    }

    private var loadRequest: BookCoverThumbnailLoadRequest {
        BookCoverThumbnailLoadRequest(
            coverPath: book.coverPath,
            pixelBucket: targetPixelBucket
        )
    }

    private func loadImage(for request: BookCoverThumbnailLoadRequest) async {
        guard let coverPath = request.coverPath else {
            if loadedCover != nil {
                loadedCover = nil
            }
            return
        }

        if loadedCover != nil,
           BookCoverThumbnailImagePolicy.satisfies(
               loadedPath: loadedCover?.path,
               loadedPixelBucket: loadedCover?.pixelBucket,
               request: request
           ) {
            return
        }

        guard let response = await CoverImageLoader.shared.loadedImage(
            for: coverPath,
            targetPixelSize: CGFloat(request.pixelBucket)
        ), coverPath == book.coverPath else {
            return
        }
        acceptLoadedCover(response)
    }

    private func acceptLoadedCover(_ response: LoadedCoverState) {
        guard response.path == book.coverPath,
              BookCoverThumbnailImagePolicy.shouldAcceptResponse(
                  path: response.path,
                  pixelBucket: response.pixelBucket,
                  currentPath: loadedCover?.path,
                  currentPixelBucket: loadedCover?.pixelBucket
              ) else {
            return
        }
        loadedCover = response
    }

    private static func targetPixelBucket(width: CGFloat, height: CGFloat) -> Int {
        let scale = CGFloat(NSScreen.main?.backingScaleFactor ?? 2)
        return CoverImageLoader.pixelBucket(for: max(width, height) * scale)
    }
}

enum BookCoverThumbnailDisplayMode {
    case fill
    case fit

    func imagePlane(imageSize: CGSize, bounds: CGSize) -> CGSize {
        guard self == .fit, imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func resolve(imageSize: CGSize, fitsEntireImage: Bool = false) -> BookCoverThumbnailDisplayMode {
        if fitsEntireImage { return .fit }
        guard imageSize.width > 0, imageSize.height > 0 else {
            return .fill
        }
        return imageSize.width > imageSize.height ? .fit : .fill
    }
}
