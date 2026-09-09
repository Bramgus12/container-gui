import AppKit
import Foundation
import SwiftUI

struct ImageListView: View {
    @Bindable var model: AppModel
    @State private var pendingDeletion: ImageDeletionPlan?
    @State private var pullModel: ImagePullModel?
    @State private var tagModel: ImageTagModel?
    @State private var pushModel: ImagePushModel?
    @State private var saveModel: ImageSaveModel?
    @State private var loadModel: ImageLoadModel?
    @State private var bulkDeleteModel: ImageBulkDeleteModel?
    @State private var pruneModel: ImagePruneModel?
    @State private var buildModel: ImageBuildModel?
    @State private var runContainerModel: RunContainerModel?
    /// Set when a save finishes, so Reveal in Finder points at the archive the
    /// operation actually wrote rather than at whatever the form holds now.
    @State private var savedArchiveURL: URL?

    var body: some View {
        content
            .background(Color.dsCanvas)
            .navigationTitle("Images")
            .searchable(
                text: $model.imageSearchText,
                placement: .toolbar,
                prompt: "Search images"
            )
            .toolbar { toolbar }
            .overlay { listOverlay }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    savedArchiveBanner
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
            .modifier(ImageSheets(
                model: model,
                pendingDeletion: $pendingDeletion,
                pullModel: $pullModel,
                tagModel: $tagModel,
                pushModel: $pushModel,
                saveModel: $saveModel,
                loadModel: $loadModel,
                bulkDeleteModel: $bulkDeleteModel,
                pruneModel: $pruneModel,
                buildModel: $buildModel,
                runContainerModel: $runContainerModel,
                savedArchiveURL: $savedArchiveURL
            ))
            .inspector(isPresented: $model.isImageInspectorPresented) {
                ImageInspectionView(model: model)
                    .id(model.selectedImageID)
                    .inspectorColumnWidth(min: 360, ideal: 460, max: 680)
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ImageScreenHeader(
                count: model.images.count,
                totalSize: model.images.compactMap(\.size).reduce(0, &+)
            )
            if let activity = model.imageOperations.activity {
                ImageOperationProgressRow(
                    activity: activity,
                    cancel: model.imageOperations.cancel,
                    dismiss: model.imageOperations.dismiss
                )
            }
            table
            ImageListFooter(
                unused: model.unusedImages,
                showsUnusedOnly: $model.showsUnusedImagesOnly
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
                pullModel = ImagePullModel(capabilities: model.imageCapabilities)
            } label: {
                Label("Pull Image", systemImage: "arrow.down.circle")
            }
            .disabled(model.imageOperations.isBusy)
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

        // The rest of the image surface would be a wall of toolbar icons, so it
        // goes behind one labelled menu instead. Row-scoped entries mirror it in
        // the context menu.
        ToolbarItem {
            Menu {
                Button("Tag Selected Image…") { tagModel = makeTagModel() }
                    .disabled(model.selectedImage == nil)
                Button("Push Selected Image…") { pushModel = makePushModel() }
                    .disabled(model.selectedImage == nil || model.imageOperations.isBusy)
                Divider()
                Button("Save Images…") { saveModel = makeSaveModel() }
                    .disabled(model.images.isEmpty || model.imageOperations.isBusy)
                Button("Load Archive…") { loadModel = ImageLoadModel() }
                    .disabled(model.imageOperations.isBusy)
                Divider()
                Button("Delete Images…", role: .destructive) {
                    bulkDeleteModel = ImageBulkDeleteModel(
                        preselected: model.selectedImage?.reference
                    )
                }
                .disabled(model.images.isEmpty || model.imageOperations.isBusy)
                Button("Prune Images…", role: .destructive) {
                    pruneModel = ImagePruneModel()
                }
                .disabled(model.imageOperations.isBusy)
            } label: {
                Label("More Image Actions", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("images.moreActions")
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
            .contextMenu { rowMenu(for: image) }
        }
        .accessibilityIdentifier("images.table")
    }

    @ViewBuilder
    private func rowMenu(for image: ImageSummary) -> some View {
        Button("Run Image…") {
            runContainerModel = RunContainerModel(
                image: image.reference,
                networkModel: model.networkModel,
                volumeModel: model.volumeModel
            )
        }
        Button("Tag…") { tagModel = ImageTagModel(source: image.reference) }
        Button("Push…") { pushModel = ImagePushModel(reference: image.reference) }
            .disabled(model.imageOperations.isBusy)
        Button("Save…") {
            saveModel = ImageSaveModel(available: model.images, preselected: image.reference)
        }
        .disabled(model.imageOperations.isBusy)
        Divider()
        Button("Delete…", role: .destructive) {
            requestDeletion(image.reference)
        }
        .disabled(
            model.preparingImageDeletionReference != nil
                || model.deletingImageReference != nil
        )
    }

    private func makeTagModel() -> ImageTagModel? {
        model.selectedImage.map { ImageTagModel(source: $0.reference) }
    }

    private func makePushModel() -> ImagePushModel? {
        model.selectedImage.map { ImagePushModel(reference: $0.reference) }
    }

    private func makeSaveModel() -> ImageSaveModel {
        ImageSaveModel(available: model.images, preselected: model.selectedImage?.reference)
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
                        pullModel = ImagePullModel(capabilities: model.imageCapabilities)
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
    private var savedArchiveBanner: some View {
        if let url = savedArchiveURL {
            InlineBanner(
                message: "Archive saved",
                detail: url.path,
                scope: .bar,
                severity: .info,
                actionTitle: "Reveal in Finder",
                action: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                onDismiss: { savedArchiveURL = nil }
            )
            .accessibilityIdentifier("images.save.saved")
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

/// Every sheet the Images screen presents, lifted out of `body` so the screen's
/// own layout stays type-checkable.
private struct ImageSheets: ViewModifier {
    @Bindable var model: AppModel
    @Binding var pendingDeletion: ImageDeletionPlan?
    @Binding var pullModel: ImagePullModel?
    @Binding var tagModel: ImageTagModel?
    @Binding var pushModel: ImagePushModel?
    @Binding var saveModel: ImageSaveModel?
    @Binding var loadModel: ImageLoadModel?
    @Binding var bulkDeleteModel: ImageBulkDeleteModel?
    @Binding var pruneModel: ImagePruneModel?
    @Binding var buildModel: ImageBuildModel?
    @Binding var runContainerModel: RunContainerModel?
    @Binding var savedArchiveURL: URL?

    func body(content: Content) -> some View {
        content
            .sheet(item: $pendingDeletion) { plan in
                ImageDeletionSheet(plan: plan, model: model)
            }
            .sheet(item: $pullModel) { draft in
                ImagePullSheet(model: draft) { configuration in
                    model.startImageOperation(.pull(configuration))
                }
            }
            .sheet(item: $tagModel) { draft in
                ImageTagSheet(model: draft, appModel: model)
            }
            .sheet(item: $pushModel) { draft in
                ImagePushSheet(model: draft, registryModel: model.registryModel) { configuration in
                    model.startImageOperation(.push(configuration))
                }
            }
            .sheet(item: $saveModel) { draft in
                ImageSaveSheet(model: draft) { configuration in
                    let url = draft.outputURL
                    savedArchiveURL = nil
                    model.imageOperations.start(.save(configuration)) { state in
                        // Offered only for an archive that was actually written.
                        if state == .succeeded { savedArchiveURL = url }
                    }
                }
            }
            .sheet(item: $loadModel) { draft in
                ImageLoadSheet(model: draft) { configuration in
                    model.startImageOperation(.load(configuration))
                }
            }
            .sheet(item: $bulkDeleteModel) { draft in
                ImageBulkDeleteSheet(model: draft, appModel: model) { configuration in
                    model.startImageOperation(.delete(configuration))
                }
            }
            .sheet(item: $pruneModel) { draft in
                ImagePruneSheet(
                    model: draft,
                    images: model.images,
                    inventoryIndex: model.inventoryIndex
                ) { all in
                    model.startImageOperation(.prune(all: all))
                }
            }
            .sheet(item: $buildModel) { draft in
                ImageBuildSheet(model: draft, appModel: model)
            }
            .sheet(item: $runContainerModel) { runModel in
                RunContainerSheet(
                    model: runModel,
                    appModel: model,
                    networkModel: model.networkModel,
                    volumeModel: model.volumeModel
                )
            }
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
        // A confirmation carries no command and only as much height as its
        // warnings need, but keeps the shared header and footer.
        SheetScaffold(
            minWidth: 560,
            minHeight: plan.dependentContainers.isEmpty ? 300 : 460
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(
                    title: title,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .dsStateDestructive
                )
                details
            }
            .background(Color.dsCanvas)
        } footer: {
            footer
        }
        .interactiveDismissDisabled(isDeleting)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing16) {
            Text(message)
                .textSelection(.enabled)

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
        }
        .padding(DSMetrics.spacing16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var footer: some View {
        SheetCancelButton(accessibilityID: "images.deletion.cancel") { dismiss() }
            .disabled(isDeleting)

        if !plan.dependentContainers.isEmpty || !plan.unresolvedContainers.isEmpty {
            Button("View Containers") {
                model.destination = .containers
                model.selectedContainerID = plan.dependentContainers.first?.id
                    ?? plan.unresolvedContainers.first?.id
                dismiss()
            }
            .disabled(isDeleting)
            .accessibilityIdentifier("images.deletion.viewContainers")
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
                Text(title)
            }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(
            isDeleting
                || !plan.blockedContainers.isEmpty
                || !plan.unresolvedContainers.isEmpty
                || !plan.hasStableIdentity
        )
        .accessibilityIdentifier("images.deletion.confirm")
    }

    private var title: LocalizedStringResource {
        plan.dependentContainers.isEmpty
            ? "Delete Image"
            : "Delete Containers and Image"
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
