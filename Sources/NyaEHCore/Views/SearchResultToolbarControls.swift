import SwiftUI

struct SearchResultSortToolbarMenu: View {
    let store: SearchStore
    let localizer: AppLocalizer

    var body: some View {
        Menu {
            Picker(localizer.string(.viewSortStrategy), selection: Binding(
                get: { store.catalog.advancedSearchSortKey },
                set: { store.catalog.advancedSearchSortKey = $0 }
            )) {
                ForEach(SearchResultSortKey.allCases) { key in
                    Label(localizer.string(key.titleKey), systemImage: key.systemImage)
                        .tag(key)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .labelStyle(.titleAndIcon)
            .buttonStyle(.automatic)
        } label: {
            SearchResultToolbarMenuLabel(systemImage: store.catalog.advancedSearchSortKey.systemImage)
        }
        .menuStyle(.button)
        .buttonStyle(SearchToolbarButtonStyle())
        .menuIndicator(.hidden)
        .tint(.primary)
        .help(localizer.string(store.catalog.advancedSearchSortKey.titleKey))
        .accessibilityLabel(localizer.string(.viewSortStrategy))
        .accessibilityValue(localizer.string(store.catalog.advancedSearchSortKey.titleKey))
    }
}

struct SearchResultDirectionToolbarButton: View {
    let store: SearchStore
    let localizer: AppLocalizer

    var body: some View {
        Button {
            store.catalog.advancedSearchSortDirection = store.catalog.advancedSearchSortDirection == .ascending
                ? .descending : .ascending
        } label: {
            Label(
                localizer.string(store.catalog.advancedSearchSortDirection.titleKey),
                systemImage: store.catalog.advancedSearchSortDirection == .ascending ? "arrow.up" : "arrow.down"
            )
            .labelStyle(.iconOnly)
        }
        .buttonStyle(SearchToolbarButtonStyle())
        .help(localizer.string(store.catalog.advancedSearchSortDirection.titleKey))
        .accessibilityLabel(localizer.string(.sortDirection))
        .accessibilityValue(localizer.string(store.catalog.advancedSearchSortDirection.titleKey))
    }
}

struct SearchResultLayoutToolbarMenu: View {
    let store: SearchStore
    let localizer: AppLocalizer

    var body: some View {
        Menu {
            Picker(localizer.string(.advancedSearchLayout), selection: Binding(
                get: { store.catalog.advancedSearchResultLayout },
                set: { store.catalog.advancedSearchResultLayout = $0 }
            )) {
                ForEach(SearchResultLayout.allCases) { layout in
                    Label(localizer.string(layout.titleKey), systemImage: layout.systemImage)
                        .tag(layout)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .labelStyle(.titleAndIcon)
            .buttonStyle(.automatic)
        } label: {
            SearchResultToolbarMenuLabel(systemImage: store.catalog.advancedSearchResultLayout.systemImage)
        }
        .menuStyle(.button)
        .buttonStyle(SearchToolbarButtonStyle())
        .menuIndicator(.hidden)
        .tint(.primary)
        .help(localizer.string(store.catalog.advancedSearchResultLayout.titleKey))
        .accessibilityLabel(localizer.string(.advancedSearchLayout))
        .accessibilityValue(localizer.string(store.catalog.advancedSearchResultLayout.titleKey))
    }
}

private struct SearchResultToolbarMenuLabel: View {
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        // The menu's button style owns symbol sizing, just as it does for the
        // adjacent buttons. A legacy popup cell otherwise substitutes small icons.
        .accessibilityHidden(true)
    }
}

/// The ControlGroup keeps its menu representation; only its expanded chrome is customized.
struct SearchToolbarGlassControlGroupStyle: ControlGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.content
        }
        // Styles belong on the individual triggers. An inherited icon-only button
        // style also reaches menu rows and hides their titles.
        .searchToolbarGlassSurface()
    }
}

extension View {
    func searchToolbarGlassSurface() -> some View {
        fixedSize(horizontal: true, vertical: false)
            .frame(height: 30)
            .padding(3)
            .glassEffect(.regular.interactive(), in: Capsule())
            // The padding is outside the glass, so adjacent items cannot form a continuous capsule.
            .padding(.horizontal, 6)
    }
}

struct SearchToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 17))
            .symbolRenderingMode(.monochrome)
            .padding(.horizontal, 6)
            .frame(minWidth: 30, minHeight: 30)
            .foregroundStyle(.primary)
            .background(
                .primary.opacity(isSelected ? 0.12 : (configuration.isPressed ? 0.1 : 0)),
                in: Capsule()
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct SearchToolbarToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(SearchToolbarButtonStyle(isSelected: configuration.isOn))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
