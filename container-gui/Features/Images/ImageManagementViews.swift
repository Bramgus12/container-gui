import Foundation
import SwiftUI

struct ImageListView: View {
    @Bindable var model: AppModel
    @State private var pendingDeletion: String?
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
                        pendingDeletion = model.selectedImage?.reference
                    } label: {
                        Label("Delete Image", systemImage: "trash")
                    }
                    .disabled(
                        model.selectedImage == nil
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
            .alert(
                "Delete Image?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { reference in
                Button("Delete", role: .destructive) {
                    Task { await model.deleteImage(reference: reference) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { reference in
                Text(
                    "This permanently deletes “\(reference)”. "
                        + "Containers that use the image can cause this operation to fail."
                )
            }
            .sheet(item: $pullModel) { pullModel in
                ImagePullSheet(model: pullModel, appModel: model)
            }
            .sheet(item: $runContainerModel) { runModel in
                RunContainerSheet(model: runModel, appModel: model)
            }
            .inspector(
                isPresented: Binding(
                    get: { model.selectedImageID != nil },
                    set: { if !$0 { model.selectedImageID = nil } }
                )
            ) {
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
                    pendingDeletion = image.reference
                }
                .disabled(model.deletingImageReference != nil)
            }
        }
        .accessibilityIdentifier("images.table")
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

private struct ImageInspectionView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = model.selectedImage {
                Text(image.reference)
                    .font(.title3.bold())
                    .textSelection(.enabled)
            }

            switch model.imageInspectionState {
            case .idle, .loading:
                Spacer()
                ProgressView("Inspecting image…")
                    .frame(maxWidth: .infinity)
                Spacer()
            case .loaded(let json):
                ScrollView {
                    Text(json)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Inspection Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                        .textSelection(.enabled)
                } actions: {
                    Button("Try Again") {
                        Task { await model.inspectSelectedImage() }
                    }
                }
            }
        }
        .padding()
        .accessibilityIdentifier("images.inspection")
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
