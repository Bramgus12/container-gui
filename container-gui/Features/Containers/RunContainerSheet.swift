import AppKit
import SwiftUI

struct RunContainerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: RunContainerModel
    let appModel: AppModel
    let networkModel: NetworkModel?
    let volumeModel: VolumeModel?
    @State private var runRequestID: UUID?
    @State private var isCancelling = false

    private var operationIsActive: Bool {
        runRequestID != nil || model.isRunning || isCancelling
    }

    @State private var page: RunSection = .container

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                RunSectionRail(model: model, selection: $page)
                Rectangle().fill(Color.dsHairline).frame(width: 1)
                Form {
                    currentPage
                    progressSection
                    errorSection
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)
                .disabled(operationIsActive)
            }

            CommandStrip(command: model.commandPreview, accessibilityID: "run.preview")

            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .interactiveDismissDisabled(operationIsActive)
        .task {
            await networkModel?.loadIfNeeded()
            await volumeModel?.loadIfNeeded()
        }
        .task(id: runRequestID) {
            guard let requestID = runRequestID else { return }
            let outcome = await model.run(using: appModel)

            guard runRequestID == requestID else {
                isCancelling = false
                return
            }

            runRequestID = nil
            isCancelling = false
            if outcome == .succeeded {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .container: containerSection
        case .resources: resourcesSection
        case .networks: networksSection
        case .storage: ContainerMountsSection(model: model, volumeModel: volumeModel)
        case .ports: portsSection
        case .environment: environmentSection
        case .command: commandSection
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button(role: .cancel) {
                if operationIsActive {
                    isCancelling = true
                    runRequestID = nil
                } else {
                    dismiss()
                }
            } label: {
                Text(isCancelling ? "Cancelling…" : operationIsActive ? "Cancel Run" : "Cancel")
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isCancelling)
            .accessibilityIdentifier("run.cancel")

            Spacer()

            Button("Back") { page = page.previous ?? page }
                .disabled(page.previous == nil || operationIsActive)
                .accessibilityIdentifier("run.back")

            Button("Next") { page = page.next ?? page }
                .disabled(page.next == nil || operationIsActive)
                .accessibilityIdentifier("run.next")

            // Run stays available from any page: only the first page is
            // required, so there is no reason to walk the rest to start.
            Button("Run") {
                runRequestID = UUID()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(operationIsActive || !model.canRun)
            .accessibilityIdentifier("run.submit")
        }
        .padding()
    }

    @ViewBuilder
    private var containerSection: some View {
                Section("Container") {
                    validatedTextField(
                        "Image",
                        text: $model.image,
                        prompt: "alpine:3.21",
                        error: model.imageError
                    )
                    validatedTextField(
                        "Name",
                        text: $model.name,
                        prompt: "Optional",
                        error: model.nameError
                    )

                    Toggle("Run detached", isOn: $model.detached)
                    Toggle("Remove when stopped", isOn: $model.removeWhenStopped)
                }

    }

    @ViewBuilder
    private var resourcesSection: some View {
                Section("Resources") {
                    validatedTextField(
                        "CPU limit",
                        text: $model.cpuLimit,
                        prompt: "Optional, for example 1.5",
                        error: model.cpuLimitError
                    )
                    validatedTextField(
                        "Memory limit",
                        text: $model.memoryLimit,
                        prompt: "Optional, for example 512M",
                        error: model.memoryLimitError
                    )
                }

    }

    @ViewBuilder
    private var networksSection: some View {
                Section("Networks") {
                    if let networkModel {
                        switch networkModel.listState {
                        case .idle where networkModel.networks.isEmpty,
                             .loading where networkModel.networks.isEmpty:
                            ProgressView("Loading networks…")
                        case .failed(let message) where networkModel.networks.isEmpty:
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Color.dsStateDestructive)
                                .textSelection(.enabled)
                            Button("Try Again") {
                                Task { await networkModel.refresh() }
                            }
                        default:
                            if networkModel.networks.isEmpty {
                                Text("No networks are available. Without an explicit attachment, the CLI uses its default network.")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach($model.networks) { $attachment in
                            NetworkAttachmentDraftRow(
                                attachment: $attachment,
                                choices: networkModel.networks,
                                error: model.networkError(for: attachment),
                                onRemove: {
                                    model.removeNetworkAttachment(id: attachment.id)
                                }
                            )
                        }

                        Button("Add Network", systemImage: "plus") {
                            model.addNetworkAttachment()
                        }
                        .disabled(
                            networkModel.networks.isEmpty
                                || model.networks.count >= networkModel.networks.count
                        )
                    } else {
                        Text("The network inventory is unavailable. The CLI will use its default network.")
                            .foregroundStyle(.secondary)
                    }
                }

    }

    @ViewBuilder
    private var portsSection: some View {
                Section("Published Ports") {
                    ForEach($model.ports) { $port in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Host address (optional)", text: $port.hostAddress)
                                    .dsMonoField()
                                TextField("Host port", text: $port.hostPort)
                                    .dsMonoField()
                                    .frame(width: 100)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                TextField("Container port", text: $port.containerPort)
                                    .dsMonoField()
                                    .frame(width: 120)
                                Picker("Protocol", selection: $port.portProtocol) {
                                    Text("TCP").tag(PortProtocol.tcp)
                                    Text("UDP").tag(PortProtocol.udp)
                                }
                                .labelsHidden()
                                .frame(width: 90)
                                Button("Remove", systemImage: "minus.circle") {
                                    model.removePort(id: port.id)
                                }
                                .labelStyle(.iconOnly)
                            }
                            validationText(model.portError(for: port))
                        }
                    }
                    Button("Add Port", systemImage: "plus") {
                        model.addPort()
                    }
                }

    }

    @ViewBuilder
    private var environmentSection: some View {
                Section("Environment") {
                    ForEach($model.environment) { $variable in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Key", text: $variable.key)
                                    .dsMonoField()
                                    .frame(width: 180)
                                TextField("Value", text: $variable.value)
                                    .dsMonoField()
                                Button("Remove", systemImage: "minus.circle") {
                                    model.removeEnvironmentVariable(id: variable.id)
                                }
                                .labelStyle(.iconOnly)
                            }
                            validationText(model.environmentError(for: variable))
                        }
                    }
                    Button("Add Variable", systemImage: "plus") {
                        model.addEnvironmentVariable()
                    }
                }

    }

    @ViewBuilder
    private var commandSection: some View {
                Section("Command") {
                    validatedTextField(
                        "Executable",
                        text: $model.command,
                        prompt: "Optional, for example /bin/sh",
                        error: model.commandError
                    )
                    ForEach($model.arguments) { $argument in
                        HStack {
                            TextField("Argument", text: $argument.value)
                                .dsMonoField()
                            Button("Remove", systemImage: "minus.circle") {
                                model.removeArgument(id: argument.id)
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    Button("Add Argument", systemImage: "plus") {
                        model.addArgument()
                    }
                }

    }

    @ViewBuilder
    private var progressSection: some View {
                if model.isRunning || !model.progress.isEmpty {
                    Section("Progress") {
                        if model.isRunning {
                            ProgressView("Pulling image and starting container…")
                        }
                        if !model.progress.isEmpty {
                            ScrollView {
                                Text(model.progress)
                                    .font(DSFont.mono(size: 12.5, relativeTo: .callout))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                    }
                }

    }

    @ViewBuilder
    private var errorSection: some View {
                if let errorMessage = model.errorMessage {
                    Section {
                        Label {
                            Text(errorMessage)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(Color.dsStateDestructive)
                    }
                    .accessibilityIdentifier("run.error")
                }
    }

    @ViewBuilder
    private func validatedTextField(
        _ title: String,
        text: Binding<String>,
        prompt: String,
        error: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                TextField(prompt, text: text)
                    .dsMonoField()
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier(
                        "run." + title
                            .lowercased()
                            .replacingOccurrences(of: " ", with: "-")
                    )
            }
            validationText(error)
        }
    }

    @ViewBuilder
    private func validationText(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.dsStateDestructive)
        }
    }
}

/// The seven form sections, in the order the rail lists them.
enum RunSection: String, CaseIterable, Identifiable, Hashable {
    case container
    case resources
    case networks
    case storage
    case ports
    case environment
    case command

    var id: Self { self }

    var next: RunSection? {
        let all = RunSection.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    var previous: RunSection? {
        let all = RunSection.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    /// Only the first page must be filled in for a container to run; the rest
    /// are optional refinements, and the rail marks them as such.
    var isRequired: Bool { self == .container }

    var title: LocalizedStringResource {
        switch self {
        case .container: "Container"
        case .resources: "Resources"
        case .networks: "Networks"
        case .storage: "Storage"
        case .ports: "Ports"
        case .environment: "Environment"
        case .command: "Command"
        }
    }
}

private struct RunSectionRail: View {
    let model: RunContainerModel
    @Binding var selection: RunSection

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
            SectionLabel(title: "Run container")
                .padding(.bottom, DSMetrics.spacing8)
            ForEach(RunSection.allCases) { section in
                RailRow(
                    title: section.title,
                    count: count(for: section),
                    isRequired: section.isRequired,
                    isSelected: selection == section
                ) {
                    selection = section
                }
            }
            Spacer()
        }
        .padding(DSMetrics.spacing12)
        .frame(width: 150)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dsSurfaceRaised)
        .accessibilityIdentifier("run.rail")
    }

    private func count(for section: RunSection) -> Int? {
        switch section {
        case .container, .resources: nil
        case .networks: model.networks.count
        case .storage: model.mounts.count
        case .ports: model.ports.count
        case .environment: model.environment.count
        case .command: model.arguments.count + (model.command.isEmpty ? 0 : 1)
        }
    }
}

private struct RailRow: View {
    let title: LocalizedStringResource
    let count: Int?
    let isRequired: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: DSMetrics.spacing4) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                if isRequired {
                    Text(verbatim: "*")
                        .foregroundStyle(Color.dsStateAttention)
                        .accessibilityLabel("Required")
                }
                Spacer()
                if let count, count > 0 {
                    Text(count, format: .number)
                        .font(.cliMonoTabular)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .padding(.vertical, DSMetrics.spacing8)
            .padding(.horizontal, DSMetrics.spacing8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.dsBlue100 : .clear,
            in: RoundedRectangle(cornerRadius: DSMetrics.controlRadius)
        )
    }
}

private struct ContainerMountsSection: View {
    @Bindable var model: RunContainerModel
    let volumeModel: VolumeModel?

    var body: some View {
        Section("Storage") {
            if let volumeModel,
               case .failed(let message) = volumeModel.listState,
               volumeModel.volumes.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.dsStateDestructive)
                    .textSelection(.enabled)
            }

            ForEach($model.mounts) { $mount in
                ContainerMountDraftRow(
                    mount: $mount,
                    volumeChoices: volumeModel?.volumes ?? [],
                    error: model.mountError(for: mount),
                    onRemove: { model.removeMount(id: mount.id) }
                )
            }

            HStack {
                Button("Add Volume", systemImage: "externaldrive.badge.plus") {
                    model.addMount(kind: .volume)
                }
                .disabled(volumeModel == nil || volumeModel?.volumes.isEmpty == true)

                Button("Add Host Folder", systemImage: "folder.badge.plus") {
                    model.addMount(kind: .hostPath)
                }
            }

            Text("Named volumes persist container data. Host folders expose a selected local directory to the container.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ContainerMountDraftRow: View {
    @Binding var mount: ContainerMountDraft
    let volumeChoices: [VolumeSummary]
    let error: String?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Source type", selection: $mount.kind) {
                    ForEach(ContainerMountKind.allCases, id: \.rawValue) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                if mount.kind == .volume {
                    Picker("Volume", selection: $mount.source) {
                        Text("Select a volume").tag("")
                        ForEach(volumeChoices) { volume in
                            Text(volume.name).tag(volume.name)
                        }
                    }
                    .frame(minWidth: 180)
                } else {
                    TextField("Host folder", text: $mount.source)
                        .dsMonoField()
                    Button("Choose…") { chooseHostFolder() }
                }

                TextField("Container path", text: $mount.target)
                    .dsMonoField()
                    .frame(minWidth: 160)
                Toggle("Read-only", isOn: $mount.isReadOnly)
                    .toggleStyle(.checkbox)
                Button("Remove", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.dsStateDestructive)
            }
        }
    }

    private func chooseHostFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            mount.source = url.path
        }
    }
}

private struct NetworkAttachmentDraftRow: View {
    @Binding var attachment: NetworkAttachmentDraft
    let choices: [NetworkSummary]
    let error: String?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Network", selection: $attachment.networkName) {
                    Text("Select a network").tag("")
                    ForEach(choices) { network in
                        Text(network.name).tag(network.name)
                    }
                }
                .frame(minWidth: 180)
                .accessibilityIdentifier("run.network.\(attachment.id).selection")

                TextField("MAC address (optional)", text: $attachment.macAddress)
                    .dsMonoField()
                    .frame(minWidth: 180)
                    .accessibilityIdentifier("run.network.\(attachment.id).mac")
                TextField("MTU (optional)", text: $attachment.mtu)
                    .dsMonoField()
                    .frame(width: 110)
                    .accessibilityIdentifier("run.network.\(attachment.id).mtu")
                Button("Remove", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.dsStateDestructive)
            }
        }
    }
}
