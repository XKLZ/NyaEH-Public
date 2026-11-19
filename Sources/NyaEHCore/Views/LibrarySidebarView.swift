// 本文件定义主窗口侧边栏结构，是用户进入首页、搜索、标签、管理和导入页面的入口。

import SwiftUI

struct LibrarySidebarView: View {
    @Binding var selection: LibraryDestination?
    let localizer: AppLocalizer
    let showsDevelopmentTools: Bool
    let navigationRequest: Int
    @State private var isCategoryExpanded = false
    @State private var isManagementExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                destinationRow(.search, title: .search, systemImage: "magnifyingglass")
                destinationRow(.home, title: .home, systemImage: "house")

                disclosureRow(.categorySection, systemImage: "square.grid.2x2", isExpanded: $isCategoryExpanded)
                if isCategoryExpanded {
                    destinationRow(.tagCategory(.work), title: .worksAndCharacters, systemImage: TagCategory.work.systemImage, isChild: true)
                    destinationRow(.tagCategory(.creator), title: .authorsAndGroups, systemImage: TagCategory.creator.systemImage, isChild: true)
                    destinationRow(.tagCategory(.tags), title: .contentTags, systemImage: TagCategory.tags.systemImage, isChild: true)
                }

                disclosureRow(.libraryManagement, systemImage: "slider.horizontal.3", isExpanded: $isManagementExpanded)
                if isManagementExpanded {
                    destinationRow(.favoriteManagement, title: .favorites, systemImage: "heart.square", isChild: true)
                    destinationRow(.collectionManagement, title: .series, systemImage: "rectangle.stack.badge.plus", isChild: true)
                    destinationRow(.versionManagement, title: .versions, systemImage: "square.2.layers.3d", isChild: true)
                }

                if showsDevelopmentTools {
                    Section {
                        destinationRow(.developmentTools, title: .developmentTools, systemImage: "hammer")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            Button {
                selection = .importLibrary
            } label: {
                Label(localizer.string(.importLibrary), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(importButtonBackground)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .navigationTitle("NyaEH")
        .onChange(of: selection, initial: true) {
            revealSelectedChild()
        }
        .onChange(of: navigationRequest) {
            revealSelectedChild()
        }
    }

    private func revealSelectedChild() {
        switch selection {
        case .tagCategory:
            isCategoryExpanded = true
        case .favoriteManagement, .collectionManagement, .versionManagement:
            isManagementExpanded = true
        default:
            break
        }
    }

    private func disclosureRow(_ title: L10nKey, systemImage: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation { isExpanded.wrappedValue.toggle() }
        } label: {
            rowLabel(title, systemImage: systemImage, isExpanded: isExpanded.wrappedValue)
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .accessibilityHint(localizer.string(isExpanded.wrappedValue ? .collapseSection : .expandSection))
    }

    private func destinationRow(
        _ destination: LibraryDestination, title: L10nKey, systemImage: String, isChild: Bool = false
    ) -> some View {
        rowLabel(title, systemImage: systemImage, isChild: isChild)
            .tag(destination)
    }

    private func rowLabel(
        _ title: L10nKey, systemImage: String, isExpanded: Bool? = nil, isChild: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(width: 12, height: 1)
                .overlay {
                    if let isExpanded {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHidden(true)

            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .padding(.leading, isChild ? 18 : 0)
                .accessibilityHidden(true)

            Text(localizer.string(title))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var importButtonBackground: some View {
        if selection == .importLibrary {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.18))
        }
    }
}
