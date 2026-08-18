import AppKit
import SwiftUI

struct VolumesView: View {
    private static let columns: [DSTableColumn] = [
        DSTableColumn("name", "Name"),
        DSTableColumn("attached", "Attached to"),
        DSTableColumn("format", "Format", width: 100),
        DSTableColumn("size", "Size", width: 150, alignment: .trailing),
    ]

    @Bindable var model: VolumeModel
    let inventoryIndex: InventoryIndex
    @State private var createModel: VolumeCreateModel?
    @State private var pendingDeletion: VolumeSummary?
    @State private var confirmsPrune = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Volumes").font(.dsScreenTitle)
                Text("\(model.volumes.count)").foregroundStyle(Color.dsTextSecondary)
                Spacer()
            }
            .padding(DSMetrics.spacing16)
            .background(Color.dsSurface)
            DSTable(
                rows: model.filteredVolumes,
                columns: Self.columns,
                selection: $model.selectedVolumeID
            ) { volume in
                HStack(spacing: DSMetrics.spacing8) {
                    MonoText(value: volume.name, truncation: .middle, selectable: false)
                    if volume.isAnonymous { TagChip(title: "Anonymous") }
                }
                .dsColumn(Self.columns[0])

                Group {
                    let containers = inventoryIndex.containers(attachedTo: volume)
                    if let first = containers.first {
                        MonoText(
                            value: containers.count == 1 ? first.id : "\(first.id) +\(containers.count - 1)",
                            dimmed: true,
                            selectable: false
                        )
                    } else {
                        TagChip(title: "Unused")
                    }
                }
                .dsColumn(Self.columns[1])

                MonoText(value: volume.format ?? "—", dimmed: true, selectable: false)
                    .dsColumn(Self.columns[2])

                HStack(spacing: DSMetrics.spacing8) {
                    UsageBar(value: Self.sizeFraction(volume, volumes: model.volumes)).frame(width: 52)
                    MonoText(value: volume.sizeInBytes.map(Self.formatBytes) ?? "—", dimmed: true, tabular: true, selectable: false)
                }
                .dsColumn(Self.columns[3])
            }
            VolumeHousekeepingFooter(
                volumes: model.volumes,
                inventoryIndex: inventoryIndex,
                prune: { confirmsPrune = true }
            )
        }
        .background(Color.dsCanvas)
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

    nonisolated private static func sizeFraction(_ volume: VolumeSummary, volumes: [VolumeSummary]) -> Double {
        guard let size = volume.sizeInBytes,
              let maximum = volumes.compactMap(\.sizeInBytes).max(), maximum > 0 else { return 0 }
        return Double(size) / Double(maximum)
    }
}

private struct VolumeHousekeepingFooter: View {
    let volumes: [VolumeSummary]
    let inventoryIndex: InventoryIndex
    let prune: () -> Void

    var body: some View {
        let unused = volumes.filter { inventoryIndex.containers(attachedTo: $0).isEmpty }
        HStack {
            Text("\(unused.count) volumes are attached to nothing — \(Self.formatBytes(unused.compactMap(\.sizeInBytes).reduce(0, &+))) can be reclaimed")
            Spacer()
            Button("Prune unused…", action: prune).disabled(unused.isEmpty)
        }
        .font(.caption)
        .foregroundStyle(Color.dsTextSecondary)
        .padding(.horizontal, DSMetrics.spacing12)
        .frame(minHeight: 38)
        .background(Color.dsSurfaceRaised)
        .overlay(alignment: .top) { Rectangle().fill(Color.dsHairline).frame(height: 1) }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
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
            EmptyState(
                "Volumes Couldn’t Be Loaded",
                systemImage: "exclamationmark.triangle",
                message: message
            ) {
                Button("Try Again") { Task { await model.refresh() } }
            }
        case .loaded where model.filteredVolumes.isEmpty:
            if model.volumes.isEmpty {
                EmptyState(
                    "No Volumes",
                    systemImage: "externaldrive",
                    description: "Create a volume for persistent container data."
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
                InlineBanner(
                    message: "Volume action failed",
                    detail: failure,
                    scope: .bar,
                    severity: .error,
                    copyValue: failure,
                    onDismiss: model.dismissMutationFailure
                )
            }
            if case .failed(let message) = model.listState, !model.volumes.isEmpty {
                InlineBanner(
                    message: "Refresh failed",
                    detail: message,
                    scope: .bar,
                    severity: .error,
                    actionTitle: "Retry",
                    action: { Task { await model.refresh() } }
                )
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
                    EmptyState("Select a Volume", systemImage: "externaldrive")
                case .loading:
                    ProgressView("Inspecting volume…").frame(maxWidth: .infinity)
                case .failed(let message):
                    EmptyState(
                        "Volume Couldn’t Be Inspected",
                        systemImage: "exclamationmark.triangle",
                        message: message
                    ) {
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
                if isSubmitting { Section { ProgressView("Creating volume…") } }
                if let failure = model.mutationFailure {
                    Section {
                        InlineBanner(
                            message: "Create failed",
                            detail: failure,
                            scope: .card,
                            severity: .error,
                            copyValue: failure
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSubmitting)
            CommandStrip(command: draft.commandPreview, accessibilityID: "volumes.create.preview")
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
                            .dsMonoField()
                        TextField("Value", text: $row.value)
                            .dsMonoField()
                        Button("Remove", systemImage: "minus.circle") { onRemove(row.id) }
                            .labelStyle(.iconOnly)
                    }
                    if let message = error(row) {
                        Text(message).font(.caption).foregroundStyle(Color.dsStateDestructive)
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
                    .dsMonoField()
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive) }
        }
    }
}
