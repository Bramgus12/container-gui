import AppKit
import SwiftUI

struct VolumesView: View {
    @Bindable var model: VolumeModel
    @State private var createModel: VolumeCreateModel?
    @State private var pendingDeletion: VolumeSummary?
    @State private var confirmsPrune = false

    var body: some View {
        Table(model.filteredVolumes, selection: $model.selectedVolumeID) {
            TableColumn("Name", value: \.name)
            TableColumn("Driver") { Text($0.driver ?? "—") }
            TableColumn("Format") { Text($0.format ?? "—") }
            TableColumn("Size") { volume in
                Text(volume.sizeInBytes.map(Self.formatBytes) ?? "—")
            }
            TableColumn("Created") { volume in
                if let date = volume.creationDate {
                    Text(
                        date,
                        format: .dateTime.year().month(.abbreviated).day().hour().minute()
                    )
                } else {
                    Text("—")
                }
            }
        }
        .navigationTitle("Volumes")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search volumes")
        .toolbar {
            ToolbarItem {
                Button {
                    createModel = VolumeCreateModel()
                } label: {
                    Label("Create Volume", systemImage: "plus")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("volumes.create")
            }
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.listState == .loading || model.isBusy)
                .accessibilityIdentifier("volumes.refresh")
            }
            ToolbarItem {
                Button {
                    confirmsPrune = true
                } label: {
                    Label("Prune Volumes", systemImage: "trash.slash")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("volumes.prune")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    pendingDeletion = model.selectedVolume
                } label: {
                    Label("Delete Volume", systemImage: "trash")
                }
                .disabled(model.selectedVolume == nil || model.isBusy)
                .accessibilityIdentifier("volumes.delete")
            }
        }
        .overlay { VolumeListOverlay(model: model) }
        .safeAreaInset(edge: .bottom) { VolumeErrorBanners(model: model) }
        .task { await model.loadIfNeeded() }
        .task(id: model.selectedVolumeID) { await model.inspectSelection() }
        .sheet(item: $createModel) { draft in
            CreateVolumeSheet(draft: draft, model: model)
        }
        .alert(
            "Delete Volume?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { volume in
            Button("Delete", role: .destructive) {
                Task { await model.delete(volumeID: volume.id) }
                pendingDeletion = nil
            }
            .accessibilityIdentifier("volumes.confirmDelete")
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { volume in
            Text("“\(volume.name)” will be permanently deleted. Volumes referenced by any container cannot be deleted.")
        }
        .alert("Prune Unused Volumes?", isPresented: $confirmsPrune) {
            Button("Prune", role: .destructive) { Task { await model.prune() } }
                .accessibilityIdentifier("volumes.confirmPrune")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All volumes without a container reference will be permanently deleted.")
        }
        .alert(
            "Volume Prune Complete",
            isPresented: Binding(
                get: { model.lastPruneResult != nil },
                set: { if !$0 { model.dismissPruneResult() } }
            )
        ) {
            Button("OK") { model.dismissPruneResult() }
        } message: {
            if let names = model.lastPruneResult, !names.isEmpty {
                Text("Deleted \(names.count) volume(s): \(names.formatted()).")
            } else {
                Text("No unused volumes were found.")
            }
        }
        .inspector(isPresented: $model.isInspectorPresented) {
            VolumeInspector(model: model)
                .id(model.selectedVolumeID)
                .inspectorColumnWidth(min: 340, ideal: 440, max: 620)
        }
        .accessibilityIdentifier("volumes.screen")
    }

    nonisolated private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct VolumeListOverlay: View {
    let model: VolumeModel

    var body: some View {
        switch model.listState {
        case .idle where model.volumes.isEmpty,
             .loading where model.volumes.isEmpty:
            ProgressView("Loading volumes…").controlSize(.large)
        case .failed(let message) where model.volumes.isEmpty:
            ContentUnavailableView {
                Label("Volumes Couldn’t Be Loaded", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
            }
        case .loaded where model.filteredVolumes.isEmpty:
            if model.volumes.isEmpty {
                ContentUnavailableView(
                    "No Volumes",
                    systemImage: "externaldrive",
                    description: Text("Create a volume for persistent container data.")
                )
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        default:
            EmptyView()
        }
    }
}

private struct VolumeErrorBanners: View {
    let model: VolumeModel

    var body: some View {
        VStack(spacing: 0) {
            if let failure = model.mutationFailure {
                HStack {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.dismissMutationFailure() }
                }
                .padding(10)
                .background(.bar)
            }
            if case .failed(let message) = model.listState, !model.volumes.isEmpty {
                HStack {
                    Label(message, systemImage: "arrow.clockwise.circle")
                    Spacer()
                    Button("Retry") { Task { await model.refresh() } }
                }
                .padding(10)
                .background(.bar)
            }
        }
    }
}

private struct VolumeInspector: View {
    let model: VolumeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.inspectionState {
                case .idle:
                    ContentUnavailableView("Select a Volume", systemImage: "externaldrive")
                case .loading:
                    ProgressView("Inspecting volume…").frame(maxWidth: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Volume Couldn’t Be Inspected", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message).textSelection(.enabled)
                    } actions: {
                        Button("Try Again") { Task { await model.inspectSelection() } }
                    }
                case .loaded(let inspection):
                    VolumeInspectorHeader(inspection: inspection)
                    VolumeOverviewSection(summary: inspection.summary)
                    InspectionSection("Labels", systemImage: "tag") {
                        InspectionKeyValueList(inspection.summary.labels, emptyText: "No labels")
                    }
                    InspectionSection("Driver Options", systemImage: "slider.horizontal.3") {
                        InspectionKeyValueList(inspection.summary.options, emptyText: "No options")
                    }
                }
            }
            .padding()
        }
    }
}

private struct VolumeInspectorHeader: View {
    let inspection: VolumeInspection

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(inspection.summary.name).font(.title2.bold()).textSelection(.enabled)
                if inspection.summary.isAnonymous {
                    Text("Anonymous").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(inspection.rawJSON, forType: .string)
            } label: {
                Label("Copy Raw JSON", systemImage: "doc.on.doc")
            }
            .help("Copies full volume inspection data. Labels and driver options may contain sensitive values.")
        }
    }
}

private struct VolumeOverviewSection: View {
    let summary: VolumeSummary

    var body: some View {
        InspectionSection("Overview", systemImage: "info.circle") {
            InspectionValueRow("Driver", value: summary.driver)
            InspectionValueRow("Format", value: summary.format)
            if let size = summary.sizeInBytes {
                InspectionValueRow("Size", value: Self.formatBytes(size))
            }
            if let date = summary.creationDate {
                LabeledContent("Created") {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                }
            }
            InspectionValueRow("Source", value: summary.source)
        }
    }

    nonisolated private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct CreateVolumeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: VolumeCreateModel
    let model: VolumeModel
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Volume") {
                    VolumeValidatedField(
                        title: "Name",
                        text: $draft.name,
                        prompt: "my-volume",
                        error: draft.nameError,
                        accessibilityIdentifier: "volumes.create.name"
                    )
                    VolumeValidatedField(
                        title: "Size",
                        text: $draft.size,
                        prompt: "Optional, for example 10G",
                        error: draft.sizeError,
                        accessibilityIdentifier: "volumes.create.size"
                    )
                }
                VolumeKeyValueSection(
                    title: "Labels",
                    rows: $draft.labels,
                    error: draft.labelError,
                    onAdd: draft.addLabel,
                    onRemove: draft.removeLabel
                )
                VolumeKeyValueSection(
                    title: "Driver Options",
                    rows: $draft.options,
                    error: draft.optionError,
                    onAdd: draft.addOption,
                    onRemove: draft.removeOption
                )
                Section("Command Preview") {
                    Text(draft.commandPreview)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                if isSubmitting { Section { ProgressView("Creating volume…") } }
                if let failure = model.mutationFailure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSubmitting)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    guard let configuration = draft.configuration else { return }
                    isSubmitting = true
                    Task {
                        if await model.create(configuration) { dismiss() }
                        isSubmitting = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.configuration == nil || isSubmitting)
                .accessibilityIdentifier("volumes.create.submit")
            }
            .padding()
        }
        .frame(minWidth: 660, minHeight: 600)
        .interactiveDismissDisabled(isSubmitting)
    }
}

private struct VolumeKeyValueSection: View {
    let title: LocalizedStringResource
    @Binding var rows: [VolumeKeyValueDraft]
    let error: (VolumeKeyValueDraft) -> String?
    let onAdd: () -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        Section(title) {
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Key", text: $row.key).frame(width: 200)
                        TextField("Value", text: $row.value)
                        Button("Remove", systemImage: "minus.circle") { onRemove(row.id) }
                            .labelStyle(.iconOnly)
                    }
                    if let message = error(row) {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Button("Add", systemImage: "plus", action: onAdd)
        }
    }
}

private struct VolumeValidatedField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    let prompt: String
    let error: String?
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                TextField(prompt, text: $text)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
