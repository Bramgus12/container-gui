import AppKit
import SwiftUI

/// The list is `container machine list` column for column, so the screen and the
/// CLI cannot disagree about what a machine is.
struct MachinesView: View {
    private static let columns: [DSTableColumn<MachineSummary>] = [
        DSTableColumn("name", "Name") {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        },
        DSTableColumn("created", "Created", width: 150) {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        },
        DSTableColumn("ip", "IP", width: 130),
        DSTableColumn("cpus", "CPUs", width: 70, alignment: .trailing) {
            ($0.cpus ?? 0) > ($1.cpus ?? 0)
        },
        DSTableColumn("memory", "Memory", width: 90, alignment: .trailing) {
            ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0)
        },
        DSTableColumn("disk", "Disk", width: 90, alignment: .trailing) {
            ($0.diskBytes ?? 0) > ($1.diskBytes ?? 0)
        },
        DSTableColumn("state", "State", width: 110),
        DSTableColumn("default", "Default", width: 70, alignment: .center),
    ]

    @Bindable var model: MachineModel
    @State private var pendingDeletion: MachineSummary?
    @State private var createModel: MachineCreateModel?
    @State private var bootDraft: MachineBootConfigurationModel?
    @State private var runDraft: MachineRunModel?
    @State private var logsDraft: MachineLogsModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            DSTable(
                rows: model.filteredMachines,
                columns: Self.columns,
                selection: $model.selectedMachineID
            ) { machine in
                HStack(spacing: DSMetrics.spacing8) {
                    MonoText(value: machine.id, truncation: .middle, selectable: false)
                    if model.pendingSettings(for: machine.id) != nil {
                        TagChip(title: "Restart pending")
                    }
                }
                .dsColumn(Self.columns[0])

                MonoText(
                    value: machine.createdAt.map(Self.formatDate) ?? "—",
                    dimmed: true,
                    tabular: true,
                    selectable: false
                )
                .dsColumn(Self.columns[1])

                MonoText(
                    value: machine.address ?? "—",
                    dimmed: true,
                    tabular: true,
                    selectable: false
                )
                .dsColumn(Self.columns[2])

                MonoText(
                    value: machine.cpus.map(String.init) ?? "—",
                    dimmed: true,
                    tabular: true,
                    selectable: false
                )
                .dsColumn(Self.columns[3])

                MonoText(
                    value: machine.memoryBytes.map(Self.formatBytes) ?? "—",
                    dimmed: true,
                    tabular: true,
                    selectable: false
                )
                .dsColumn(Self.columns[4])

                MonoText(
                    value: machine.diskBytes.map(Self.formatBytes) ?? "—",
                    dimmed: true,
                    tabular: true,
                    selectable: false
                )
                .dsColumn(Self.columns[5])

                StateDot(
                    machine.state.designState,
                    label: machine.state.localizedTitle,
                    accessibilityLabel: machine.state.localizedTitle
                )
                .dsColumn(Self.columns[6])

                Group {
                    if machine.isDefault {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Color.dsStateAttention)
                            .accessibilityLabel("Default machine")
                    } else {
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
                .dsColumn(Self.columns[7])
            }
            MachineFooter(model: model)
        }
        .background(Color.dsCanvas)
        .navigationTitle("Machines")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search machines")
        .toolbar {
            ToolbarItem {
                Button {
                    createModel = MachineCreateModel()
                } label: {
                    Label("Create Machine", systemImage: "plus")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("machines.create")
            }
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.listState == .loading || model.isBusy)
                .accessibilityIdentifier("machines.refresh")
            }
            ToolbarItem {
                Button {
                    Task { await setDefault() }
                } label: {
                    Label("Set as Default", systemImage: "star")
                }
                .disabled(!canSetDefault)
                .accessibilityIdentifier("machines.setDefault")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    pendingDeletion = model.selectedMachine
                } label: {
                    Label("Delete Machine", systemImage: "trash")
                }
                .disabled(model.selectedMachine == nil || model.isBusy)
                .accessibilityIdentifier("machines.delete")
            }
        }
        .overlay { MachineListOverlay(model: model) }
        .safeAreaInset(edge: .bottom) { MachineErrorBanner(model: model) }
        .task { await model.loadIfNeeded() }
        .task(id: model.selectedMachineID) { await model.inspectSelection() }
        .alert(
            "Delete Machine?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { machine in
            Button("Delete", role: .destructive) {
                Task { await model.delete(machineID: machine.id) }
                pendingDeletion = nil
            }
            .accessibilityIdentifier("machines.confirmDelete")
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { machine in
            Text("“\(machine.id)” and its disk will be permanently deleted.")
        }
        .sheet(item: $createModel) { draft in
            CreateMachineSheet(draft: draft, model: model)
        }
        .sheet(item: $bootDraft) { draft in
            MachineBootConfigurationSheet(draft: draft, model: model)
        }
        .sheet(item: $runDraft) { draft in
            RunInMachineSheet(draft: draft)
        }
        .sheet(item: $logsDraft) { draft in
            MachineLogsSheet(model: draft)
        }
        .inspector(isPresented: $model.isInspectorPresented) {
            MachineInspector(
                model: model,
                editBootConfiguration: { inspection in
                    bootDraft = MachineBootConfigurationModel(
                        inspection: inspection,
                        pending: model.pendingSettings(for: inspection.summary.id)
                    )
                },
                openShell: { machineID in
                    runDraft = model.makeRunModel(for: machineID)
                },
                openLogs: { machineID in
                    logsDraft = model.makeLogsModel(for: machineID)
                }
            )
            .id(model.selectedMachineID)
            .inspectorColumnWidth(min: 360, ideal: 460, max: 640)
        }
        .accessibilityIdentifier("machines.screen")
    }

    private var header: some View {
        HStack(spacing: DSMetrics.spacing8) {
            Text("Machines").font(.dsScreenTitle)
            Text("\(model.machines.count)").foregroundStyle(Color.dsTextSecondary)
            Spacer()
            Text("\(model.runningCount) running · \(model.stoppedCount) stopped")
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
        }
        .padding(DSMetrics.spacing16)
        .background(Color.dsSurface)
    }

    /// Setting the default is only meaningful for a machine that is not already
    /// it — the CLI would accept the call, but nothing would move.
    private var canSetDefault: Bool {
        guard let selected = model.selectedMachine else { return false }
        return !selected.isDefault && !model.isBusy
    }

    private func setDefault() async {
        guard let selected = model.selectedMachine else { return }
        await model.setDefault(machineID: selected.id)
    }

    nonisolated private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    nonisolated private static func formatDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

/// Machines never appear in Containers — the service filters them out of every
/// container list — so the footer says so rather than leaving the absence to be
/// discovered.
private struct MachineFooter: View {
    let model: MachineModel

    var body: some View {
        HStack {
            Text("\(model.machines.count) machines · they never appear in Containers, the service filters them out of every container list")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Color.dsTextSecondary)
        .padding(.horizontal, DSMetrics.spacing12)
        .frame(minHeight: 38)
        .background(Color.dsSurfaceRaised)
        .overlay(alignment: .top) { Rectangle().fill(Color.dsHairline).frame(height: 1) }
    }
}

private struct MachineListOverlay: View {
    let model: MachineModel

    var body: some View {
        switch model.listState {
        case .idle where model.machines.isEmpty,
             .loading where model.machines.isEmpty:
            ProgressView("Loading machines…").controlSize(.large)
        case .failed(let message) where model.machines.isEmpty:
            EmptyState(
                "Machines Couldn’t Be Loaded",
                systemImage: "exclamationmark.triangle",
                message: message
            ) {
                Button("Try Again") { Task { await model.refresh() } }
            }
        case .loaded where model.filteredMachines.isEmpty:
            if model.machines.isEmpty {
                EmptyState(
                    "No Machines",
                    systemImage: "desktopcomputer",
                    description: "A machine is a long-lived Linux VM you keep and shell into."
                )
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        default:
            EmptyView()
        }
    }
}

private struct MachineErrorBanner: View {
    let model: MachineModel

    var body: some View {
        if let failure = model.mutationFailure {
            InlineBanner(
                message: "Machine command failed",
                detail: failure,
                severity: .error,
                onDismiss: { model.dismissMutationFailure() }
            )
            .padding(DSMetrics.spacing8)
        }
    }
}

private struct MachineInspector: View {
    let model: MachineModel
    let editBootConfiguration: (MachineInspection) -> Void
    let openShell: (String) -> Void
    let openLogs: (String) -> Void

    var body: some View {
        InspectionPane {
            switch model.inspectionState {
            case .idle:
                EmptyState("Select a Machine", systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                ProgressView("Inspecting machine…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                EmptyState(
                    "Machine Couldn’t Be Inspected",
                    systemImage: "exclamationmark.triangle",
                    message: message
                ) {
                    Button("Try Again") { Task { await model.inspectSelection() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let inspection):
                MachineInspectorHeader(
                    inspection: inspection,
                    model: model,
                    openShell: { openShell(inspection.summary.id) },
                    openLogs: { openLogs(inspection.summary.id) }
                )
                MachineImageSection(inspection: inspection)
                MachineRuntimeSection(inspection: inspection)
                MachineBootSection(
                    inspection: inspection,
                    model: model,
                    edit: { editBootConfiguration(inspection) }
                )
                MachineNetworkSection(inspection: inspection)
                CommandStrip(
                    command: "container machine inspect \(inspection.summary.id)",
                    accessibilityID: "machine.inspect.command"
                )
            }
        }
    }
}

private struct MachineInspectorHeader: View {
    let inspection: MachineInspection
    let model: MachineModel
    let openShell: () -> Void
    let openLogs: () -> Void

    private var isDefault: Bool {
        model.machines.first { $0.id == inspection.summary.id }?.isDefault ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                    HStack(spacing: DSMetrics.spacing8) {
                        Text(inspection.summary.id)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                        if isDefault { TagChip(title: "Default") }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(inspection.rawJSON, forType: .string)
                } label: {
                    Label("Copy Raw JSON", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .help("Copies the full machine inspection payload.")
            }

            HStack(spacing: DSMetrics.spacing8) {
                Button("Open Shell…", action: openShell)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .help(inspection.summary.state == .running
                        ? "Opens a login shell in this machine."
                        : "Boots the machine, then opens a login shell in it.")
                    .accessibilityIdentifier("machine.openShell")

                Button("Logs", action: openLogs)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("machine.logs")

                Button("Stop") {
                    Task { await model.stop(machineID: inspection.summary.id) }
                }
                .disabled(inspection.summary.state != .running || model.isBusy)
                .accessibilityIdentifier("machine.stop")

                Button("Set as Default") {
                    Task { await model.setDefault(machineID: inspection.summary.id) }
                }
                .disabled(isDefault || model.isBusy)
                .help(isDefault
                    ? "Already the default — select another machine to move it."
                    : "Commands that omit a machine ID will use this machine.")
                .accessibilityIdentifier("machine.setDefault")
            }
        }
    }

    private var subtitle: String {
        let formatter = RelativeUptimeFormatter()
        let image = inspection.imageReference.map { " · booted from \($0)" } ?? ""
        switch inspection.summary.state {
        case .running:
            guard let started = inspection.startedAt ?? inspection.summary.createdAt else {
                return "Running\(image)"
            }
            return "Running for \(formatter.compactDuration(from: started, to: Date()))\(image)"
        case .stopped:
            return "Stopped\(image)"
        case .unknown(let value):
            return "\(value.capitalized)\(image)"
        }
    }
}

private struct MachineImageSection: View {
    let inspection: MachineInspection

    var body: some View {
        InspectionSection("Image", systemImage: "shippingbox") {
            InspectionValueRow("Reference", value: inspection.imageReference)
            InspectionValueRow("Platform", value: inspection.platformDescription)
            InspectionValueRow("Digest", value: inspection.imageDigest)
        }
    }
}

private struct MachineRuntimeSection: View {
    let inspection: MachineInspection

    var body: some View {
        InspectionSection("Runtime", systemImage: "bolt") {
            InspectionValueRow(
                "Status",
                value: inspection.summary.state.localizedTitleString
            )
            if let started = inspection.startedAt {
                LabeledContent("Started") {
                    Text(started, format: .dateTime.year().month().day().hour().minute().second())
                }
            }
            if let created = inspection.summary.createdAt {
                LabeledContent("Created") {
                    Text(created, format: .dateTime.year().month().day().hour().minute().second())
                }
            }
        }
    }
}

private struct MachineBootSection: View {
    let inspection: MachineInspection
    let model: MachineModel
    let edit: () -> Void

    var body: some View {
        InspectionSection("Boot configuration", systemImage: "slider.horizontal.3") {
            HStack {
                Spacer()
                Button("Edit…", action: edit)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("machine.boot.edit")
            }
            InspectionValueRow("CPUs", value: inspection.summary.cpus.map(String.init))
            InspectionValueRow(
                "Memory",
                value: inspection.summary.memoryBytes.map(Self.formatBytes)
            )
            InspectionValueRow(
                "Disk",
                value: inspection.summary.diskBytes.map(Self.formatBytes)
            )
            InspectionValueRow("Home mount", value: inspection.homeMount?.rawValue)

            if let virtualization = inspection.virtualization {
                InspectionValueRow("Nested virtualization", value: String(virtualization))
            }
            if let kernel = inspection.kernelPath {
                InspectionValueRow("Kernel", value: kernel)
            }
            if inspection.virtualization == nil || inspection.kernelPath == nil {
                // Both are stored by the service, but `machine inspect` does not
                // report them, so the app cannot show a value it has not been
                // given rather than guessing one.
                Text("Nested virtualization and the custom kernel are stored but not reported by `container machine inspect`.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.pendingSettings(for: inspection.summary.id) != nil {
                Text("Changes have been written but take effect only after this machine is stopped and started.")
                    .font(.caption)
                    .foregroundStyle(Color.dsStateAttention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private struct MachineNetworkSection: View {
    let inspection: MachineInspection

    var body: some View {
        InspectionSection("Network & user", systemImage: "network") {
            InspectionValueRow("IP address", value: inspection.summary.address)
            InspectionValueRow("User", value: inspection.userDescription)
        }
    }
}
