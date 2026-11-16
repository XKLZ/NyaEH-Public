// 本文件集中展示长任务状态和可用控制，避免任务反馈散落在各功能页。

import SwiftUI

struct TaskCenterView: View {
    @Bindable var store: TaskCenterStore
    let localizer: AppLocalizer

    private var snapshots: [LibraryTaskSnapshot] {
        store.catalog.taskCenterSnapshots(localizer: localizer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(localizer.string(.taskCenter), systemImage: "progress.indicator")
                .font(.headline)

            if snapshots.isEmpty {
                ContentUnavailableView(
                    localizer.string(.taskCenterEmpty),
                    systemImage: "checkmark.circle",
                    description: Text(localizer.string(.taskCenterEmptyDescription))
                )
                .frame(minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(snapshots) { snapshot in
                            taskRow(snapshot)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 390, height: 360)
    }

    private func taskRow(_ snapshot: LibraryTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: stateImage(snapshot.state))
                    .foregroundStyle(stateColor(snapshot.state))
                Text(snapshot.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                taskControls(snapshot)
            }

            if let fraction = snapshot.fractionCompleted {
                ProgressView(value: fraction)
            } else if snapshot.state == .running {
                ProgressView()
                    .controlSize(.small)
            }

            if let detail = snapshot.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(snapshot.state == .failed ? .red : .secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func taskControls(_ snapshot: LibraryTaskSnapshot) -> some View {
        HStack(spacing: 5) {
            if snapshot.canPause {
                Button { pause(snapshot.kind) } label: {
                    Label(localizer.string(.metadataBatchPause), systemImage: "pause").labelStyle(.iconOnly)
                }
            }
            if snapshot.canResume {
                Button {
                    if snapshot.state == .failed {
                        store.catalog.retryLastFailedTask(localizer: localizer)
                    } else {
                        store.catalog.resumeMetadataBatch(localizer: localizer)
                    }
                } label: {
                    Label(localizer.string(.metadataBatchResume), systemImage: "play").labelStyle(.iconOnly)
                }
            }
            if snapshot.canCancel {
                Button(role: .cancel) { cancel(snapshot.kind) } label: {
                    Label(localizer.string(.cancel), systemImage: "xmark").labelStyle(.iconOnly)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func cancel(_ kind: LibraryTaskKind) {
        switch kind {
        case .scan: store.catalog.cancelLibraryScan()
        case .metadata: store.catalog.cancelMetadataBatch()
        case .importPipeline: store.catalog.pauseImportPipeline()
        case .externalImport: store.catalog.cancelImport()
        case .workCharacterIndex: store.catalog.cancelWorkCharacterIndexTask()
        case .collectionRecommendations, .versionRecommendations: store.catalog.cancelRecommendationTasks()
        case .coverVectors: store.catalog.cancelCoverVectorTask()
        case .semanticTitleVectors: store.catalog.cancelSemanticTitleVectorTask()
        case .tagTranslations, .lastFailure: break
        }
    }

    private func pause(_ kind: LibraryTaskKind) {
        switch kind {
        case .importPipeline: store.catalog.pauseImportPipeline()
        case .metadata: store.catalog.pauseMetadataBatch()
        default: break
        }
    }

    private func stateImage(_ state: LibraryTaskRunState) -> String {
        switch state {
        case .running: "clock.arrow.circlepath"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func stateColor(_ state: LibraryTaskRunState) -> Color {
        switch state {
        case .running: .accentColor
        case .paused: .orange
        case .completed: .green
        case .failed: .red
        }
    }
}
