import SwiftUI

struct OrganizationSaveStatusView: View {
    let store: CatalogStore
    let localizer: AppLocalizer

    var body: some View {
        if store.isSavingOrganization || store.organizationSaveError != nil {
            VStack(alignment: .leading, spacing: 8) {
                if store.isSavingOrganization {
                    Label {
                        Text(localizer.string(.saving))
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                }
                if let error = store.organizationSaveError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .lineLimit(3)
                        Button {
                            if store.loadError == error { store.loadError = nil }
                            store.organizationSaveError = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localizer.string(.cancel))
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: 360, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
