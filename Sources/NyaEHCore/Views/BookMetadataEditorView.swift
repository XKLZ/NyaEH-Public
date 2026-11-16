// 本文件实现元数据编辑窗口，编辑草稿最终通过 Store/Service 写回数据库。

import AppKit
import SwiftUI

@MainActor
final class BookMetadataEditorWindowPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(
        book: LibraryBook,
        store: CatalogStore,
        metadataConfiguration: GalleryMetadataFetchConfiguration,
        localizer: AppLocalizer
    ) {
        if let window {
            window.close()
            self.window = nil
        }

        let view = BookMetadataEditorWindowView(
            store: store,
            book: book,
            metadataConfiguration: metadataConfiguration,
            localizer: localizer,
            onClose: { [weak self] in self?.close() }
        )
        let hostingController = NSHostingController(rootView: view.managedFocusAppearance())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localizer.string(.editMetadata)
        window.contentViewController = hostingController
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }
        DispatchQueue.main.async { [weak self, weak closingWindow] in
            guard let self, let closingWindow, self.window === closingWindow else {
                return
            }
            closingWindow.contentViewController = nil
            closingWindow.delegate = nil
            self.window = nil
        }
    }
}

private struct BookMetadataEditorWindowView: View {
    @Bindable var store: CatalogStore
    let book: LibraryBook
    let metadataConfiguration: GalleryMetadataFetchConfiguration
    let localizer: AppLocalizer
    let onClose: () -> Void

    @State private var currentBook: LibraryBook
    @State private var draft: BookMetadataEditDraft
    @State private var errorMessage: String?
    @State private var galleryURLText: String
    @State private var isDeleteMetadataConfirmationPresented = false

    init(
        store: CatalogStore,
        book: LibraryBook,
        metadataConfiguration: GalleryMetadataFetchConfiguration,
        localizer: AppLocalizer,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.book = book
        self.metadataConfiguration = metadataConfiguration
        self.localizer = localizer
        self.onClose = onClose
        _currentBook = State(initialValue: book)
        _draft = State(initialValue: BookMetadataEditDraft(book: book))
        _galleryURLText = State(initialValue: book.url ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 16),
                            GridItem(.flexible(), spacing: 16)
                        ],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        editorCard(title: "标题信息", systemImage: "text.book.closed") {
                            titleSection
                        }
                        editorCard(title: "来源获取", systemImage: "link.badge.plus") {
                            sourceSection
                        }
                        editorCard(title: "基础属性", systemImage: "slider.horizontal.3") {
                            basicAttributeSection
                        }
                        editorCard(title: "状态", systemImage: "switch.2") {
                            statusSection
                        }
                    }
                    editorCard(title: "创作者与作品", systemImage: "person.text.rectangle") {
                        creatorWorkTagSection
                    }
                    editorCard(title: localizer.string(.tags), systemImage: "tag") {
                        otherTagSection
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 660)
        .confirmationDialog(
            "确定删除元数据？",
            isPresented: $isDeleteMetadataConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除元数据", role: .destructive) {
                deleteMetadata()
            }
            Button(localizer.string(.cancel), role: .cancel) {}
        } message: {
            Text("会清空当前书的图库元数据、标签索引和远端元数据镜像，但不会删除源文件或封面缓存。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BookCoverThumbnail(book: book, width: 54, height: 76, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(localizer.string(.editMetadata))
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(currentBook.filepath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(18)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("原版标题") {
                TextField(localizer.string(.bookTitleOriginal), text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }
            labeledField("日文标题") {
                TextField(localizer.string(.bookTitleJapanese), text: $draft.titleJpn)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("输入 E-Hentai / ExHentai 画廊网址，直接使用 URL 中的 gid/token 更新元数据。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://e-hentai.org/g/12345/token/", text: $galleryURLText)
                .textFieldStyle(.roundedBorder)
            HStack {
                if store.isFetchingMetadata {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    fetchMetadataFromURL()
                } label: {
                    Label("通过网址获取数据", systemImage: "arrow.down.doc")
                }
                .disabled(store.isFetchingMetadata || galleryURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            if let message = store.metadataFetchMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == localizer.string(.metadataFetchSucceeded) ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
        }
    }

    private var basicAttributeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("类型") {
                Picker("类型", selection: $draft.category) {
                    ForEach(BookMetadataCategoryOption.allCases) { option in
                        Text(option.rawValue).tag(option.rawValue)
                    }
                }
                .labelsHidden()
            }
            labeledField("页数") {
                TextField("空白或正整数", text: $draft.pagesText)
                    .textFieldStyle(.roundedBorder)
            }
            labeledField("语言") {
                Picker("语言", selection: $draft.languageSelection) {
                    ForEach(BookMetadataLanguageOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
            }
            if draft.languageSelection == .other {
                labeledField("其他语言") {
                    TextField("原始 language 值", text: $draft.customLanguageCode)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(localizer.string(.translated), isOn: $draft.isTranslated)
                Toggle(localizer.string(.fullColor), isOn: $draft.isFullColor)
                Toggle(localizer.string(.extraneousAds), isOn: $draft.hasExtraneousAds)
            }
            labeledField(localizer.string(.statusCensorshipShort)) {
                Picker(localizer.string(.statusCensorshipShort), selection: $draft.censorship) {
                    Text(localizer.string(.unknown)).tag("unknown")
                    Text(localizer.string(.uncensored)).tag("uncensored")
                    Text("Full Censored").tag("full censored")
                    Text("Mosaic Censorship").tag("mosaic censorship")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var creatorWorkTagSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每行一个原始标签值。可以填写 name，也可以填写 namespace:name。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach($draft.tagGroups) { $group in
                    if ["artist", "group", "parody", "character"].contains(group.namespace) {
                        tagEditor(namespace: group.namespace, text: $group.valuesText, minHeight: 78)
                    }
                }
            }
        }
    }

    private var otherTagSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保留原始标签，不应用标签翻译。每行一个标签。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach($draft.tagGroups) { $group in
                    if !["artist", "group", "parody", "character"].contains(group.namespace) {
                        tagEditor(namespace: group.namespace, text: $group.valuesText, minHeight: group.namespace == "other" ? 120 : 84)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("删除元数据", role: .destructive) {
                isDeleteMetadataConfirmationPresented = true
            }
            Spacer()
            Button(localizer.string(.cancel)) {
                onClose()
            }
            Button(localizer.string(.save)) {
                save()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private func save() {
        do {
            _ = try store.saveMetadataDraft(draft, for: currentBook, localizer: localizer)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteMetadata() {
        do {
            _ = try store.clearMetadata(for: currentBook, localizer: localizer)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchMetadataFromURL() {
        Task {
            let updatedBook = await store.fetchMetadata(
                for: currentBook,
                galleryURLString: galleryURLText,
                configuration: metadataConfiguration,
                localizer: localizer
            )
            if let updatedBook {
                currentBook = updatedBook
                draft = BookMetadataEditDraft(book: updatedBook)
                galleryURLText = updatedBook.url ?? galleryURLText
                errorMessage = nil
            } else {
                errorMessage = store.metadataFetchMessage ?? store.loadError
            }
        }
    }

    private func editorCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func labeledField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func tagEditor(
        namespace: String,
        text: Binding<String>,
        minHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(namespace.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body.monospaced())
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
