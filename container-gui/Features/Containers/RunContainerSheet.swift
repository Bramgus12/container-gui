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

    var body: some View {
        VStack(spacing: 0) {
            Form {
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

                Section("Networks") {
                    if let networkModel {
                        switch networkModel.listState {
                        case .idle where networkModel.networks.isEmpty,
                             .loading where networkModel.networks.isEmpty:
                            ProgressView("Loading networks…")
                        case .failed(let message) where networkModel.networks.isEmpty:
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
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

                ContainerMountsSection(model: model, volumeModel: volumeModel)

                Section("Published Ports") {
                    ForEach($model.ports) { $port in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Host address (optional)", text: $port.hostAddress)
                                TextField("Host port", text: $port.hostPort)
                                    .frame(width: 100)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                TextField("Container port", text: $port.containerPort)
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

                Section("Environment") {
                    ForEach($model.environment) { $variable in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Key", text: $variable.key)
                                    .frame(width: 180)
                                TextField("Value", text: $variable.value)
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

                Section("Command Preview") {
                    Text(model.commandPreview)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("run.preview")
                }

                if model.isRunning || !model.progress.isEmpty {
                    Section("Progress") {
                        if model.isRunning {
                            ProgressView("Pulling image and starting container…")
                        }
                        if !model.progress.isEmpty {
                            ScrollView {
                                Text(model.progress)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label {
                            Text(errorMessage)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.red)
                    }
                    .accessibilityIdentifier("run.error")
                }
            }
            .formStyle(.grouped)
            .disabled(operationIsActive)

            Divider()

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

                Button("Run") {
                    runRequestID = UUID()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(operationIsActive || !model.canRun)
                .accessibilityIdentifier("run.submit")
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 680)
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
    private func validatedTextField(
        _ title: String,
        text: Binding<String>,
        prompt: String,
        error: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                TextField(prompt, text: text)
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
                .foregroundStyle(.red)
        }
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
                    .foregroundStyle(.red)
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
                    Button("Choose…") { chooseHostFolder() }
                }

                TextField("Container path", text: $mount.target)
                    .frame(minWidth: 160)
                Toggle("Read-only", isOn: $mount.isReadOnly)
                    .toggleStyle(.checkbox)
                Button("Remove", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
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
                    .frame(minWidth: 180)
                    .accessibilityIdentifier("run.network.\(attachment.id).mac")
                TextField("MTU (optional)", text: $attachment.mtu)
                    .frame(width: 110)
                    .accessibilityIdentifier("run.network.\(attachment.id).mtu")
                Button("Remove", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
