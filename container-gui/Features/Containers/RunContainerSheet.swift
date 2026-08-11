import SwiftUI

struct RunContainerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: RunContainerModel
    let appModel: AppModel
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
