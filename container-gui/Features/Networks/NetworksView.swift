import AppKit
import SwiftUI

struct NetworksView: View {
    private static let columns: [DSTableColumn<NetworkSummary>] = [
        DSTableColumn("name", "Name") {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        },
        DSTableColumn("mode", "Mode", width: 90) {
            ($0.mode ?? "").localizedStandardCompare($1.mode ?? "") == .orderedAscending
        },
        DSTableColumn("subnet", "IPv4 subnet", width: 150),
        DSTableColumn("attached", "Attached", width: 120),
        DSTableColumn("plugin", "Plugin", width: 110),
    ]

    @Bindable var model: NetworkModel
    let inventoryIndex: InventoryIndex
    @State private var createModel: NetworkCreateModel?
    @State private var pendingDeletion: NetworkSummary?
    @State private var isConfirmingPrune = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Networks").font(.dsScreenTitle)
                Text("\(model.networks.count)").foregroundStyle(Color.dsTextSecondary)
                Spacer()
            }
            .padding(DSMetrics.spacing16)
            .background(Color.dsSurface)
            DSTable(
                rows: model.filteredNetworks,
                columns: Self.columns,
                selection: $model.selectedNetworkID
            ) { network in
                HStack(spacing: DSMetrics.spacing8) {
                    MonoText(value: network.name, truncation: .middle, selectable: false)
                    if network.isBuiltIn { TagChip(title: "Built-in") }
                }
                .dsColumn(Self.columns[0])

                MonoText(value: network.mode ?? "—", dimmed: true, selectable: false)
                    .dsColumn(Self.columns[1])

                MonoText(value: network.ipv4Subnet ?? "—", dimmed: true, selectable: false)
                    .dsColumn(Self.columns[2])

                Group {
                    let count = inventoryIndex.attachedContainerCount(for: network)
                    if count == 0 {
                        TagChip(title: "Unused")
                    } else {
                        Text("\(count) container(s)")
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }
                .dsColumn(Self.columns[3])

                MonoText(value: network.plugin ?? "—", dimmed: true, truncation: .middle, selectable: false)
                    .dsColumn(Self.columns[4])
                    .contextMenu {
                        Button("Inspect") { model.selectedNetworkID = network.id }
                        Button("Delete…", role: .destructive) { pendingDeletion = network }
                            .disabled(network.isBuiltIn || model.isBusy)
                    }
            }
            HStack {
                let unused = model.networks.filter {
                    !$0.isBuiltIn && inventoryIndex.attachedContainerCount(for: $0) == 0
                }
                Text("\(unused.count) unused user networks")
                Spacer()
                Button("Prune unused…") { isConfirmingPrune = true }.disabled(unused.isEmpty)
            }
            .font(.caption)
            .foregroundStyle(Color.dsTextSecondary)
            .padding(.horizontal, DSMetrics.spacing12)
            .frame(minHeight: 38)
            .background(Color.dsSurfaceRaised)
            .overlay(alignment: .top) { Rectangle().fill(Color.dsHairline).frame(height: 1) }
        }
        .background(Color.dsCanvas)
        .accessibilityIdentifier("networks.table")
        .navigationTitle("Networks")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search networks")
        .toolbar {
            ToolbarItem {
                Button {
                    createModel = NetworkCreateModel(capabilities: model.capabilities)
                } label: {
                    Label("Create Network…", systemImage: "plus")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("networks.create")
            }
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.listState == .loading || model.isBusy)
                .accessibilityIdentifier("networks.refresh")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    pendingDeletion = model.selectedNetwork
                } label: {
                    Label("Delete Network…", systemImage: "trash")
                }
                .disabled(model.selectedNetwork?.isBuiltIn != false || model.isBusy)
                .accessibilityIdentifier("networks.delete")
            }
            ToolbarItem {
                Menu {
                    Button("Prune Unused Networks…", role: .destructive) {
                        isConfirmingPrune = true
                    }
                    .disabled(model.isBusy)
                } label: {
                    Label("Destructive Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("networks.destructiveActions")
            }
        }
        .overlay { NetworkListOverlay(model: model) }
        .safeAreaInset(edge: .bottom) {
            NetworkErrorBanners(model: model)
        }
        .task { await model.loadIfNeeded() }
        .task(id: model.selectedNetworkID) { await model.inspectSelection() }
        .sheet(item: $createModel) { createModel in
            CreateNetworkSheet(draft: createModel, model: model)
        }
        .alert(
            "Delete Network?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { network in
            Button("Delete", role: .destructive) {
                Task { await model.delete(networkID: network.id) }
                pendingDeletion = nil
            }
            .accessibilityIdentifier("networks.confirmDelete")
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { network in
            Text(
                "“\(network.name)” will be permanently deleted. If a container is attached, the CLI may reject the deletion."
            )
        }
        .alert("Prune Unused Networks?", isPresented: $isConfirmingPrune) {
            Button("Prune", role: .destructive) {
                Task { await model.prune() }
            }
            .accessibilityIdentifier("networks.confirmPrune")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "All currently unused user-created networks may be permanently deleted. Built-in and default networks are preserved."
            )
        }
        .alert(
            "Network Prune Complete",
            isPresented: Binding(
                get: { model.lastPruneResult != nil },
                set: { if !$0 { model.dismissPruneResult() } }
            )
        ) {
            Button("OK") { model.dismissPruneResult() }
        } message: {
            if let names = model.lastPruneResult, !names.isEmpty {
                Text("Deleted \(names.count) network(s): \(names.formatted()).")
            } else {
                Text("No unused networks were found.")
            }
        }
        .inspector(isPresented: $model.isInspectorPresented) {
            NetworkInspector(model: model)
                .id(model.selectedNetworkID)
                .inspectorColumnWidth(min: 340, ideal: 440, max: 620)
        }
        .accessibilityIdentifier("networks.screen")
    }
}

private struct NetworkListOverlay: View {
    let model: NetworkModel

    var body: some View {
        switch model.listState {
        case .idle where model.networks.isEmpty,
             .loading where model.networks.isEmpty:
            ProgressView("Loading networks…").controlSize(.large)
        case .failed(let message) where model.networks.isEmpty:
            EmptyState(
                "Networks Couldn’t Be Loaded",
                systemImage: "exclamationmark.triangle",
                message: message
            ) {
                Button("Try Again") { Task { await model.refresh() } }
            }
        case .loaded where model.filteredNetworks.isEmpty:
            if model.networks.isEmpty {
                EmptyState(
                    "No Networks",
                    systemImage: "network",
                    description: "Create a network to attach containers to it."
                )
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        default:
            EmptyView()
        }
    }
}

private struct NetworkErrorBanners: View {
    let model: NetworkModel

    var body: some View {
        VStack(spacing: 0) {
            if let mutationFailure = model.mutationFailure {
                InlineBanner(
                    message: "Network action failed",
                    detail: mutationFailure,
                    scope: .bar,
                    severity: .error,
                    copyValue: mutationFailure,
                    onDismiss: model.dismissMutationFailure
                )
                .accessibilityIdentifier("networks.mutationError")
            }
            if case .failed(let message) = model.listState, !model.networks.isEmpty {
                InlineBanner(
                    message: "Refresh failed",
                    detail: message,
                    scope: .bar,
                    severity: .error,
                    actionTitle: "Retry",
                    action: { Task { await model.refresh() } }
                )
                .accessibilityIdentifier("networks.refreshError")
            }
        }
    }
}

private struct NetworkInspector: View {
    let model: NetworkModel

    var body: some View {
        InspectionPane {
            switch model.inspectionState {
                case .idle:
                    EmptyState("Select a Network", systemImage: "network")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loading:
                    ProgressView("Inspecting network…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    EmptyState(
                        "Network Couldn’t Be Inspected",
                        systemImage: "exclamationmark.triangle",
                        message: message
                    ) {
                        Button("Try Again") { Task { await model.inspectSelection() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let inspection):
                    if inspection.summary.id == model.selectedNetworkID
                        || inspection.summary.name == model.selectedNetwork?.name {
                        NetworkInspectorHeader(inspection: inspection)
                        NetworkOverviewSection(inspection: inspection)
                        NetworkAddressingSection(inspection: inspection)
                        InspectionSection("Labels", systemImage: "tag") {
                            InspectionKeyValueList(
                                inspection.summary.labels,
                                emptyText: "No labels"
                            )
                        }
                        InspectionSection("Plugin Options", systemImage: "slider.horizontal.3") {
                            InspectionKeyValueList(
                                inspection.summary.pluginOptions,
                                emptyText: "No plugin options"
                            )
                        }
                    } else {
                        EmptyState(
                            "Selection Changed",
                            systemImage: "arrow.clockwise",
                            description: "Waiting for the selected network’s inspection."
                        )
                    }
            }
        }
    }
}

private struct NetworkInspectorHeader: View {
    let inspection: NetworkInspection

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(inspection.summary.name).font(.title2.bold()).textSelection(.enabled)
                HStack {
                    Text(inspection.summary.state.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                    if inspection.summary.isBuiltIn {
                        Text("Built-in")
                            .font(.caption.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(inspection.rawJSON, forType: .string)
            } label: {
                Label("Copy Raw JSON", systemImage: "doc.on.doc")
            }
            .help("Copies full network inspection data. Labels and plugin options may contain sensitive values.")
        }
    }
}

private struct NetworkOverviewSection: View {
    let inspection: NetworkInspection

    var body: some View {
        InspectionSection("Overview", systemImage: "info.circle") {
            InspectionValueRow("Mode", value: inspection.summary.mode)
            if let creationDate = inspection.summary.creationDate {
                LabeledContent("Created") {
                    Text(
                        creationDate,
                        format: .dateTime.year().month().day().hour().minute().second()
                    )
                }
            }
            InspectionValueRow("Plugin", value: inspection.summary.plugin)
            if let variant = inspection.legacyPluginVariant {
                InspectionValueRow("Plugin Variant", value: variant)
            }
        }
    }
}

private struct NetworkAddressingSection: View {
    let inspection: NetworkInspection

    var body: some View {
        InspectionSection("Addressing", systemImage: "point.3.connected.trianglepath.dotted") {
            InspectionValueRow("Configured IPv4 Subnet", value: inspection.configuredIPv4Subnet)
            InspectionValueRow("Effective IPv4 Subnet", value: inspection.summary.ipv4Subnet)
            InspectionValueRow("IPv4 Gateway", value: inspection.summary.gateway)
            InspectionValueRow("Configured IPv6 Subnet", value: inspection.configuredIPv6Subnet)
            InspectionValueRow("Effective IPv6 Subnet", value: inspection.summary.ipv6Subnet)
        }
    }
}

/// The four form pages, in the order the rail lists them.
enum NetworkCreateSection: String, SheetSection {
    case network
    case addressing
    case labels
    case plugin

    /// Only the name must be filled in; the rest are optional refinements, and
    /// the rail marks them as such.
    var isRequired: Bool { self == .network }

    var title: LocalizedStringResource {
        switch self {
        case .network: "Network"
        case .addressing: "Addressing"
        case .labels: "Labels"
        case .plugin: "Plugin"
        }
    }
}

private struct CreateNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: NetworkCreateModel
    let model: NetworkModel
    @State private var isSubmitting = false
    @State private var page: NetworkCreateSection = .network

    var body: some View {
        SheetScaffold(
            command: draft.commandPreview,
            commandAccessibilityID: "networks.create.preview"
        ) {
            SheetSectionPane(
                title: "Create network",
                selection: $page,
                count: railCount(for:),
                accessibilityID: "networks.create.rail"
            ) {
                currentPage
                progressSection
                errorSection
            }
            .disabled(isSubmitting)
        } footer: {
            footer
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func railCount(for section: NetworkCreateSection) -> Int? {
        switch section {
        case .network, .addressing: nil
        case .labels: draft.labels.count
        case .plugin: draft.pluginOptions.count
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .network:
            Section("Network") {
                ValidatedNetworkField(
                    title: "Name",
                    text: $draft.name,
                    prompt: "my-network",
                    error: draft.nameError,
                    accessibilityIdentifier: "networks.create.name"
                )
                Picker("Network access", selection: $draft.mode) {
                    Text("NAT").tag(NetworkMode.nat)
                    Text("Internal / host-only").tag(NetworkMode.internal)
                }
            }
        case .addressing:
            Section("Addressing") {
                ValidatedNetworkField(
                    title: "IPv4 subnet",
                    text: $draft.ipv4Subnet,
                    prompt: "Optional, for example 192.168.64.0/24",
                    error: draft.ipv4Error,
                    accessibilityIdentifier: "networks.create.ipv4"
                )
                ValidatedNetworkField(
                    title: "IPv6 subnet",
                    text: $draft.ipv6Subnet,
                    prompt: "Optional, for example fd00::/64",
                    error: draft.ipv6Error,
                    accessibilityIdentifier: "networks.create.ipv6"
                )
            }
        case .labels:
            NetworkKeyValueDraftSection(
                title: "Labels",
                rows: $draft.labels,
                error: draft.labelError,
                onAdd: draft.addLabel,
                onRemove: draft.removeLabel
            )
        case .plugin:
            Section("Plugin") {
                ValidatedNetworkField(
                    title: "Plugin",
                    text: $draft.plugin,
                    prompt: NetworkCreateConfiguration.defaultPlugin,
                    error: draft.pluginError,
                    accessibilityIdentifier: "networks.create.plugin"
                )
                if draft.capabilities.pluginCustomization == .legacyVariant {
                    ValidatedNetworkField(
                        title: "Plugin Variant",
                        text: $draft.pluginVariant,
                        prompt: "Optional",
                        error: draft.pluginVariantError,
                        accessibilityIdentifier: "networks.create.pluginVariant"
                    )
                }
            }
            if draft.capabilities.pluginCustomization == .options {
                NetworkKeyValueDraftSection(
                    title: "Plugin Options",
                    rows: $draft.pluginOptions,
                    error: draft.optionError,
                    onAdd: draft.addPluginOption,
                    onRemove: draft.removePluginOption
                )
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if isSubmitting {
            Section { ProgressView("Creating network…") }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let mutationFailure = model.mutationFailure {
            Section {
                InlineBanner(
                    message: "Create failed",
                    detail: mutationFailure,
                    scope: .card,
                    severity: .error,
                    copyValue: mutationFailure
                )
            }
            .accessibilityIdentifier("networks.create.error")
        }
    }

    @ViewBuilder
    private var footer: some View {
        SheetCancelButton(accessibilityID: "networks.create.cancel") { dismiss() }
            .disabled(isSubmitting)

        Spacer()

        SheetPagingButtons(
            selection: $page,
            isDisabled: isSubmitting,
            accessibilityIDPrefix: "networks.create"
        )

        // Create stays available from any page: only the first page is
        // required, so there is no reason to walk the rest to submit.
        Button("Create") { submit() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(draft.configuration == nil || isSubmitting)
            .accessibilityIdentifier("networks.create.submit")
    }

    private func submit() {
        guard let configuration = draft.configuration else { return }
        isSubmitting = true
        Task {
            let succeeded = await model.create(configuration)
            isSubmitting = false
            if succeeded { dismiss() }
        }
    }
}

private struct ValidatedNetworkField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let prompt: String
    let error: String?
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                TextField(prompt, text: $text)
                    .dsMonoField()
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
            }
        }
    }
}

private struct NetworkKeyValueDraftSection: View {
    let title: LocalizedStringKey
    @Binding var rows: [NetworkKeyValueDraft]
    let error: (NetworkKeyValueDraft) -> String?
    let onAdd: () -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        Section(title) {
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Key", text: $row.key).frame(width: 220)
                            .dsMonoField()
                        TextField("Value", text: $row.value)
                            .dsMonoField()
                        Button("Remove", systemImage: "minus.circle") {
                            onRemove(row.id)
                        }
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
