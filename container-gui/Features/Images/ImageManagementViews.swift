import Foundation
import SwiftUI

struct ImageListView: View {
    @Bindable var model: AppModel
    @State private var pendingDeletion: ImageDeletionPlan?
    @State private var pullModel: ImagePullModel?
    @State private var runContainerModel: RunContainerModel?

    var body: some View {
        table
            .navigationTitle("Images")
            .searchable(
                text: $model.imageSearchText,
                placement: .toolbar,
                prompt: "Search images"
            )
            .toolbar {
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
                        runContainerModel = RunContainerModel(image: selectedImage.reference)
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
                ImagePullSheet(model: pullModel, appModel: model)
            }
            .sheet(item: $runContainerModel) { runModel in
                RunContainerSheet(model: runModel, appModel: model)
            }
            .inspector(isPresented: $model.isImageInspectorPresented) {
                ImageInspectionView(model: model)
                    .id(model.selectedImageID)
                    .inspectorColumnWidth(min: 360, ideal: 460, max: 680)
            }
    }

    private var table: some View {
        Table(model.filteredImages, selection: $model.selectedImageID) {
            TableColumn("Reference", value: \.reference)
            TableColumn("Digest") { image in
                Text(image.digest ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TableColumn("Size") { image in
                Text(image.size.map(Self.formatBytes) ?? "—")
            }
            TableColumn("Platform") { image in
                Text(Self.platformDescription(image))
            }
            TableColumn("Created") { image in
                if let createdAt = image.createdAt {
                    Text(
                        createdAt,
                        format: .dateTime
                            .year()
                            .month(.abbreviated)
                            .day()
                            .hour()
                            .minute()
                    )
                } else {
                    Text("—")
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let image = model.images.first(where: { selection.contains($0.id) }) {
                Button("Run Image…") {
                    runContainerModel = RunContainerModel(image: image.reference)
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
            ContentUnavailableView {
                Label("Images Couldn’t Be Loaded", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    .textSelection(.enabled)
            } actions: {
                Button("Try Again") {
                    Task { await model.refreshImages() }
                }
                .keyboardShortcut(.defaultAction)
            }

        case .loaded where model.filteredImages.isEmpty:
            if model.images.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Pull an image to run your first container.")
                } actions: {
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
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .lineLimit(2)
                Spacer()
                Button("Try Again") {
                    Task { await model.refreshImages() }
                }
            }
            .padding(10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var deletionErrorBanner: some View {
        if let failure = model.imageDeletionFailure {
            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete failed for \(failure.reference)")
                            .fontWeight(.semibold)
                        Text(failure.message)
                            .textSelection(.enabled)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                Spacer()
                Button("Dismiss") {
                    model.dismissImageDeletionFailure()
                }
            }
            .padding(10)
            .background(.bar)
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
            .foregroundStyle(.red)

            Text(message)

            if !plan.dependentContainers.isEmpty {
                List(plan.dependentContainers) { container in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(container.id)
                                .fontWeight(.medium)
                            Text(container.state.displayName)
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
                .foregroundStyle(.orange)
            }

            if !plan.unresolvedContainers.isEmpty {
                Label(
                    "Some containers do not report image digests, so their dependency cannot be verified. Review them manually before deleting this image.",
                    systemImage: "hand.raised.fill"
                )
                .foregroundStyle(.orange)
            }

            if !plan.hasStableIdentity {
                Label(
                    "Automatic deletion requires a stable image digest. Refresh the image list or delete the image from Terminal.",
                    systemImage: "hand.raised.fill"
                )
                .foregroundStyle(.orange)
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
    let appModel: AppModel
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Image") {
                    TextField("Reference, for example alpine:3.21", text: $model.reference)
                    if let error = model.referenceError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if model.isPulling || model.didFinish || !model.progress.isEmpty {
                    Section("Progress") {
                        if model.isPulling {
                            ProgressView("Pulling image…")
                        } else if model.didFinish {
                            Label("Image pulled successfully", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if !model.progress.isEmpty {
                            ScrollView {
                                Text(model.progress)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 180, maxHeight: 320)
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if model.isPulling {
                    Button("Cancel Pull", role: .cancel) {
                        operation?.cancel()
                    }
                } else {
                    Button(model.didFinish ? "Done" : "Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if !model.didFinish {
                    Button("Pull") {
                        operation = Task {
                            await model.pull(using: appModel)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPull)
                    .accessibilityIdentifier("images.pull.submit")
                }
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 460)
        .interactiveDismissDisabled(model.isPulling)
        .onDisappear {
            operation?.cancel()
        }
        .accessibilityIdentifier("images.pull.sheet")
    }
}
