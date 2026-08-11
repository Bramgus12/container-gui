import AppKit
import SwiftUI

struct NetworksView: View {
    @Bindable var model: NetworkModel
    @State private var createModel: NetworkCreateModel?
    @State private var pendingDeletion: NetworkSummary?
    @State private var isConfirmingPrune = false

    var body: some View {
        Table(model.filteredNetworks, selection: $model.selectedNetworkID) {
            TableColumn("Name", value: \.name)
            TableColumn("Mode") { Text($0.mode ?? "—") }
            TableColumn("IPv4 Subnet") { Text($0.ipv4Subnet ?? "—") }
            TableColumn("IPv6 Subnet") { Text($0.ipv6Subnet ?? "—") }
            TableColumn("Plugin") { Text($0.plugin ?? "—") }
            TableColumn("Created") { network in
                if let creationDate = network.creationDate {
                    Text(
                        creationDate,
                        format: .dateTime.year().month(.abbreviated).day().hour().minute()
                    )
                } else {
                    Text("—")
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let network = model.networks.first(where: { selection.contains($0.id) }) {
                Button("Inspect") { model.selectedNetworkID = network.id }
                Button("Delete…", role: .destructive) { pendingDeletion = network }
                    .disabled(network.isBuiltIn || model.isBusy)
            }
        }
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
            ContentUnavailableView {
                Label("Networks Couldn’t Be Loaded", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
            }
        case .loaded where model.filteredNetworks.isEmpty:
            if model.networks.isEmpty {
                ContentUnavailableView(
                    "No Networks",
                    systemImage: "network",
                    description: Text("Create a network to attach containers to it.")
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
                HStack {
                    Label(mutationFailure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.dismissMutationFailure() }
                }
                .padding(10)
                .background(.regularMaterial)
                .accessibilityIdentifier("networks.mutationError")
            }
            if case .failed(let message) = model.listState, !model.networks.isEmpty {
                HStack {
                    Label(message, systemImage: "arrow.clockwise.circle")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Retry") { Task { await model.refresh() } }
                }
                .padding(10)
                .background(.regularMaterial)
                .accessibilityIdentifier("networks.refreshError")
            }
        }
    }
}

private struct NetworkInspector: View {
    let model: NetworkModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.inspectionState {
                case .idle:
                    ContentUnavailableView("Select a Network", systemImage: "network")
                case .loading:
                    ProgressView("Inspecting network…")
                        .frame(maxWidth: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Network Couldn’t Be Inspected", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message).textSelection(.enabled)
                    } actions: {
                        Button("Try Again") { Task { await model.inspectSelection() } }
                    }
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
                        ContentUnavailableView(
                            "Selection Changed",
                            systemImage: "arrow.clockwise",
                            description: Text("Waiting for the selected network’s inspection.")
                        )
                    }
                }
            }
            .padding()
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

private struct CreateNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: NetworkCreateModel
    let model: NetworkModel
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
                NetworkKeyValueDraftSection(
                    title: "Labels",
                    rows: $draft.labels,
                    error: draft.labelError,
                    onAdd: draft.addLabel,
                    onRemove: draft.removeLabel
                )
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
                Section("Command Preview") {
                    Text(draft.commandPreview)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("networks.create.preview")
                }
                if isSubmitting {
                    Section { ProgressView("Creating network…") }
                }
                if let mutationFailure = model.mutationFailure {
                    Section {
                        Label(mutationFailure, systemImage: "exclamationmark.triangle")
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
                        let succeeded = await model.create(configuration)
                        isSubmitting = false
                        if succeeded { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.configuration == nil || isSubmitting)
                .accessibilityIdentifier("networks.create.submit")
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 680)
        .interactiveDismissDisabled(isSubmitting)
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
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
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
                        TextField("Value", text: $row.value)
                        Button("Remove", systemImage: "minus.circle") {
                            onRemove(row.id)
                        }
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
