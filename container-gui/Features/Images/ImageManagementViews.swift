import Foundation
import SwiftUI

struct ImageListView: View {
    @Bindable var model: AppModel
    @State private var pendingDeletion: ImageDeletionPlan?
    @State private var pullModel: ImagePullModel?
    @State private var activePullModel: ImagePullModel?
    @State private var activePullTask: Task<Void, Never>?
    @State private var buildModel: ImageBuildModel?
    @State private var runContainerModel: RunContainerModel?

    var body: some View {
        VStack(spacing: 0) {
            ImageScreenHeader(count: model.images.count, totalSize: model.images.compactMap(\.size).reduce(0, &+))
            if let activePullModel {
                ImagePullProgressRow(model: activePullModel) {
                    activePullTask?.cancel()
                } dismiss: {
                    self.activePullModel = nil
                    activePullTask = nil
                }
            }
            table
            ImageListFooter(
                unused: model.unusedImages,
                showsUnusedOnly: $model.showsUnusedImagesOnly
            )
        }
            .background(Color.dsCanvas)
            .navigationTitle("Images")
            .searchable(
                text: $model.imageSearchText,
                placement: .toolbar,
                prompt: "Search images"
            )
            .toolbar {
                ToolbarItem {
                    Button {
                        buildModel = ImageBuildModel()
                    } label: {
                        Label("Build Image", systemImage: "hammer")
                    }
                    .accessibilityIdentifier("images.build")
                }

                ToolbarItem {
                    Button {
                        pullModel = ImagePullModel()
                    } label: {
                        Label("Pull Image", systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("images.pull")
                }

                ToolbarItem {
                    Button {
                        guard let selectedImage = model.selectedImage else { return }
                        runContainerModel = RunContainerModel(
                            image: selectedImage.reference,
                            networkModel: model.networkModel,
                            volumeModel: model.volumeModel
                        )
                    } label: {
                        Label("Run Image", systemImage: "play.fill")
                    }
                    .disabled(model.selectedImage == nil)
                    .accessibilityIdentifier("images.run")
                }

                ToolbarItem {
                    Button {
                        Task { await model.refreshImages() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.imageListState == .loading)
                    .accessibilityIdentifier("images.refresh")
                }

                ToolbarItem {
                    Button(role: .destructive) {
                        if let reference = model.selectedImage?.reference {
                            requestDeletion(reference)
                        }
                    } label: {
                        Label("Delete Image", systemImage: "trash")
                    }
                    .disabled(
                        model.selectedImage == nil
                            || model.preparingImageDeletionReference != nil
                            || model.deletingImageReference != nil
                    )
                    .accessibilityIdentifier("images.delete")
                }
            }
            .overlay { listOverlay }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    deletionErrorBanner
                    refreshErrorBanner
                }
            }
            .task {
                if model.imageListState == .idle {
                    await model.refreshImages()
                }
            }
            .task(id: model.selectedImageID) {
                await model.inspectSelectedImage()
            }
            .sheet(item: $pendingDeletion) { plan in
                ImageDeletionSheet(plan: plan, model: model)
            }
            .sheet(item: $pullModel) { pullModel in
                ImagePullSheet(model: pullModel) {
                    activePullModel = pullModel
                    activePullTask = Task { await pullModel.pull(using: model) }
                    self.pullModel = nil
                }
            }
            .sheet(item: $buildModel) { buildModel in
                ImageBuildSheet(model: buildModel, appModel: model)
            }
            .sheet(item: $runContainerModel) { runModel in
                RunContainerSheet(
                    model: runModel,
                    appModel: model,
                    networkModel: model.networkModel,
                    volumeModel: model.volumeModel
                )
            }
            .inspector(isPresented: $model.isImageInspectorPresented) {
                ImageInspectionView(model: model)
                    .id(model.selectedImageID)
                    .inspectorColumnWidth(min: 360, ideal: 460, max: 680)
            }
    }

    private static let columns: [DSTableColumn<ImageSummary>] = [
        DSTableColumn("reference", "Reference") {
            $0.reference.localizedStandardCompare($1.reference) == .orderedAscending
        },
        DSTableColumn("digest", "Digest"),
        DSTableColumn("platform", "Platform", width: 120),
        DSTableColumn("usedBy", "Used by", width: 120),
        DSTableColumn("size", "Size", width: 150, alignment: .trailing) {
            // Largest first: the reason to sort by size is to find what to prune.
            ($0.size ?? 0) > ($1.size ?? 0)
        },
    ]

    private var table: some View {
        DSTable(
            rows: model.filteredImages,
            columns: Self.columns,
            selection: $model.selectedImageID
        ) { image in
            MonoText(value: image.reference, truncation: .middle, selectable: false)
                .dsColumn(Self.columns[0])

            MonoText(value: image.digest ?? "—", dimmed: true, truncation: .middle, selectable: false)
                .dsColumn(Self.columns[1])

            MonoText(value: Self.platformDescription(image), dimmed: true, selectable: false)
                .dsColumn(Self.columns[2])

            Group {
                let count = model.inventoryIndex.containers(using: image).count
                if count == 0 {
                    TagChip(title: "Unused")
                } else {
                    Text("\(count) container(s)")
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .dsColumn(Self.columns[3])

            HStack(spacing: DSMetrics.spacing8) {
                UsageBar(value: Self.sizeFraction(image, images: model.images)).frame(width: 52)
                MonoText(value: image.size.map(Self.formatBytes) ?? "—", dimmed: true, tabular: true, selectable: false)
            }
            .dsColumn(Self.columns[4])
            .contextMenu {
                Button("Run Image…") {
                    runContainerModel = RunContainerModel(
                        image: image.reference,
                        networkModel: model.networkModel,
                        volumeModel: model.volumeModel
                    )
                }
                Button("Delete…", role: .destructive) {
                    requestDeletion(image.reference)
                }
                .disabled(
                    model.preparingImageDeletionReference != nil
                        || model.deletingImageReference != nil
                )
            }
        }
        .accessibilityIdentifier("images.table")
    }

    private func requestDeletion(_ reference: String) {
        Task {
            pendingDeletion = await model.prepareImageDeletion(reference: reference)
        }
    }

    @ViewBuilder
    private var listOverlay: some View {
        switch model.imageListState {
        case .idle where model.images.isEmpty,
             .loading where model.images.isEmpty:
            ProgressView("Loading images…")
                .controlSize(.large)

        case .failed(let message) where model.images.isEmpty:
            EmptyState(
                "Images Couldn’t Be Loaded",
                systemImage: "exclamationmark.triangle",
                message: message
            ) {
                Button("Try Again") {
                    Task { await model.refreshImages() }
                }
                .keyboardShortcut(.defaultAction)
            }

        case .loaded where model.filteredImages.isEmpty:
            if model.images.isEmpty {
                EmptyState(
                    "No Images",
                    systemImage: "square.stack.3d.up",
                    description: "Pull an image to run your first container."
                ) {
                    Button("Pull Image…") {
                        pullModel = ImagePullModel()
                    }
                }
            } else {
                ContentUnavailableView.search(text: model.imageSearchText)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var refreshErrorBanner: some View {
        if case .failed(let message) = model.imageListState, !model.images.isEmpty {
            InlineBanner(
                message: "Refresh failed",
                detail: message,
                scope: .bar,
                severity: .error,
                actionTitle: "Try Again",
                action: { Task { await model.refreshImages() } }
            )
        }
    }

    @ViewBuilder
    private var deletionErrorBanner: some View {
        if let failure = model.imageDeletionFailure {
            InlineBanner(
                message: "Delete failed for \(failure.reference)",
                detail: failure.message,
                scope: .bar,
                severity: .error,
                copyValue: failure.message,
                onDismiss: model.dismissImageDeletionFailure
            )
            .accessibilityIdentifier("images.deletionError")
        }
    }

    nonisolated private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    nonisolated private static func platformDescription(_ image: ImageSummary) -> String {
        let values = [image.operatingSystem, image.architecture].compactMap { $0 }
        return values.isEmpty ? "—" : values.joined(separator: " / ")
    }

    nonisolated private static func sizeFraction(_ image: ImageSummary, images: [ImageSummary]) -> Double {
        guard let size = image.size, let maximum = images.compactMap(\.size).max(), maximum > 0 else { return 0 }
        return Double(size) / Double(maximum)
    }
}

private struct ImageScreenHeader: View {
    let count: Int
    let totalSize: UInt64

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Images").font(.dsScreenTitle)
            Text("\(count) · \(Self.formatBytes(totalSize))")
                .foregroundStyle(Color.dsTextSecondary)
            Spacer()
        }
        .padding(DSMetrics.spacing16)
        .background(Color.dsSurface)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct ImagePullProgressRow: View {
    let model: ImagePullModel
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DSMetrics.spacing12) {
            ProgressView(value: model.progressFraction)
                .frame(width: 100)
            VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                MonoText(value: model.reference, truncation: .middle)
                Text(model.errorMessage ?? (model.didFinish ? "Image pulled" : model.progressLabel))
                    .foregroundStyle(model.errorMessage == nil ? Color.dsTextSecondary : Color.dsStateDestructive)
                    .lineLimit(1)
            }
            Spacer()
            if model.isPulling {
                Button("Cancel", role: .cancel, action: cancel)
            } else {
                Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, DSMetrics.spacing12)
        .frame(minHeight: 48)
        .background(Color.dsBlue100.opacity(0.35))
    }
}

private struct ImageListFooter: View {
    let unused: [ImageSummary]
    @Binding var showsUnusedOnly: Bool

    var body: some View {
        HStack {
            Text("\(unused.count) unused images · \(Self.formatBytes(unused.compactMap(\.size).reduce(0, &+)))")
            Spacer()
            Toggle("Show unused only", isOn: $showsUnusedOnly)
                .toggleStyle(.button)
                .disabled(unused.isEmpty && !showsUnusedOnly)
                .accessibilityIdentifier("images.showUnusedOnly")
        }
        .font(.caption)
        .foregroundStyle(Color.dsTextSecondary)
        .padding(.horizontal, DSMetrics.spacing12)
        .frame(minHeight: 34)
        .background(Color.dsSurfaceRaised)
        .overlay(alignment: .top) { Rectangle().fill(Color.dsHairline).frame(height: 1) }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct ImageDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: ImageDeletionPlan
    @Bindable var model: AppModel
    @State private var deletionStarted = false

    private var isDeleting: Bool {
        deletionStarted || model.deletingImageReference == plan.image.reference
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(
                plan.dependentContainers.isEmpty
                    ? "Delete Image"
                    : "Delete Containers and Image",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.title2.bold())
            .foregroundStyle(Color.dsStateDestructive)

            Text(message)

            if !plan.dependentContainers.isEmpty {
                List(plan.dependentContainers) { container in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(container.id)
                                .fontWeight(.medium)
                            Text(container.state.localizedTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(deletionMethod(for: container))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 140, maxHeight: 280)
            }

            if !plan.blockedContainers.isEmpty {
                Label(
                    "Automatic cleanup is unavailable when a container has an unsupported state or no stable image digest.",
                    systemImage: "hand.raised.fill"
                )
                .foregroundStyle(Color.dsStateAttention)
            }

            if !plan.unresolvedContainers.isEmpty {
                Label(
                    "Some containers do not report image digests, so their dependency cannot be verified. Review them manually before deleting this image.",
                    systemImage: "hand.raised.fill"
                )
                .foregroundStyle(Color.dsStateAttention)
            }

            if !plan.hasStableIdentity {
                Label(
                    "Automatic deletion requires a stable image digest. Refresh the image list or delete the image from Terminal.",
                    systemImage: "hand.raised.fill"
                )
                .foregroundStyle(Color.dsStateAttention)
            }

            Spacer()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isDeleting)

                if !plan.dependentContainers.isEmpty || !plan.unresolvedContainers.isEmpty {
                    Button("View Containers") {
                        model.destination = .containers
                        model.selectedContainerID = plan.dependentContainers.first?.id
                            ?? plan.unresolvedContainers.first?.id
                        dismiss()
                    }
                    .disabled(isDeleting)
                }

                Spacer()

                Button(role: .destructive) {
                    deletionStarted = true
                    Task {
                        await model.deleteImage(using: plan)
                        dismiss()
                    }
                } label: {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(
                            plan.dependentContainers.isEmpty
                                ? "Delete Image"
                                : "Delete Containers and Image"
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isDeleting
                        || !plan.blockedContainers.isEmpty
                        || !plan.unresolvedContainers.isEmpty
                        || !plan.hasStableIdentity
                )
                .accessibilityIdentifier("images.deletion.confirm")
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: plan.dependentContainers.isEmpty ? 260 : 420)
        .interactiveDismissDisabled(isDeleting)
    }

    private var message: String {
        if plan.dependentContainers.isEmpty {
            return "This permanently deletes “\(plan.image.reference)”. This action cannot be undone."
        }
        return "This permanently deletes “\(plan.image.reference)” and every container listed below. Running containers will be force deleted. Completed deletions cannot be undone if a later deletion fails."
    }

    private func deletionMethod(for container: ContainerSummary) -> String {
        if plan.image.digest != nil && container.imageDigest == nil {
            return "Manual cleanup required"
        }
        switch container.state {
        case .running, .paused:
            return "Force delete"
        case .created, .stopped:
            return "Delete"
        case .unknown:
            return "Manual cleanup required"
        }
    }
}

private struct ImagePullSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImagePullModel
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Image") {
                    TextField("Reference, for example alpine:3.21", text: $model.reference)
                        .dsMonoField()
                    if let error = model.referenceError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.dsStateDestructive)
                    }
                }

            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pull", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPull)
                    .accessibilityIdentifier("images.pull.submit")
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 220)
        .accessibilityIdentifier("images.pull.sheet")
    }
}
