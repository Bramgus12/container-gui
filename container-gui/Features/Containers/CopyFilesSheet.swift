import AppKit
import SwiftUI

/// Which way `container copy` moves the files. The CLI copies between a
/// container and the local filesystem in one direction per invocation, so the
/// sheet asks for the direction first and labels the two path fields from it.
enum CopyDirection: Hashable, CaseIterable, Sendable {
    case fromContainer
    case intoContainer
}

@MainActor
@Observable
final class CopyFilesModel: Identifiable {
    let id = UUID()
    let containerID: String
    var direction: CopyDirection = .fromContainer
    var containerPath = ""
    var hostPath = ""
    private(set) var isCopying = false
    private(set) var errorMessage: String?

    init(containerID: String) {
        self.containerID = containerID
    }

    var containerPathError: String? {
        validationMessage(for: containerPath) {
            _ = try LocalPath(validating: $0, field: "Container path")
        }
    }

    var hostPathError: String? {
        validationMessage(for: hostPath) {
            _ = try LocalPath(validating: $0, field: "Host path")
        }
    }

    var operation: CopyOperation? {
        try? makeOperation()
    }

    var commandPreview: String {
        guard let operation else { return "container copy" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.copy(operation).arguments
        )
    }

    var canCopy: Bool {
        operation != nil && !isCopying
    }

    func copy(using appModel: AppModel) async -> Bool {
        guard let operation, !isCopying else { return false }

        isCopying = true
        errorMessage = nil
        defer { isCopying = false }

        do {
            try await appModel.copyFiles(operation)
            return true
        } catch is CancellationError {
            return false
        } catch CLIError.cancelled {
            return false
        } catch {
            errorMessage = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return false
        }
    }

    /// Copying out writes to a location the user picks; copying in reads one
    /// that already exists, so the panels differ.
    func chooseHostPath() {
        switch direction {
        case .fromContainer:
            let panel = NSSavePanel()
            panel.prompt = "Choose"
            panel.nameFieldStringValue = (containerPath as NSString).lastPathComponent
            if panel.runModal() == .OK, let url = panel.url {
                hostPath = url.path
            }
        case .intoContainer:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            if panel.runModal() == .OK, let url = panel.url {
                hostPath = url.path
            }
        }
    }

    private func makeOperation() throws -> CopyOperation {
        let container = try CopyEndpoint.container(
            id: containerID,
            path: trimmed(containerPath)
        )
        let host = try CopyEndpoint.host(path: trimmed(hostPath))
        switch direction {
        case .fromContainer:
            return try CopyOperation(source: container, destination: host)
        case .intoContainer:
            return try CopyOperation(source: host, destination: container)
        }
    }

    private func validationMessage(
        for value: String,
        _ validate: (String) throws -> Void
    ) -> String? {
        let value = trimmed(value)
        guard !value.isEmpty else { return nil }
        do {
            try validate(value)
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CopyFilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CopyFilesModel
    let appModel: AppModel

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "copy.preview",
            minHeight: 400
        ) {
            VStack(spacing: 0) {
                SheetHeader(title: "Copy Files")
                Form {
                    Section("Direction") {
                        Picker("Direction", selection: $model.direction) {
                            Text("From container").tag(CopyDirection.fromContainer)
                            Text("Into container").tag(CopyDirection.intoContainer)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("copy.direction")
                    }

                    Section(model.direction == .fromContainer ? "Source" : "Destination") {
                        LabeledContent("In “\(model.containerID)”") {
                            TextField("/etc/hosts", text: $model.containerPath)
                                .labelsHidden()
                                .dsMonoField()
                                .accessibilityIdentifier("copy.containerPath")
                        }
                        if let error = model.containerPathError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.dsStateDestructive)
                        }
                    }

                    Section(model.direction == .fromContainer ? "Destination" : "Source") {
                        LabeledContent("On this Mac") {
                            HStack(spacing: DSMetrics.spacing8) {
                                TextField("/Users/me/hosts", text: $model.hostPath)
                                    .labelsHidden()
                                    .dsMonoField()
                                    .accessibilityIdentifier("copy.hostPath")
                                Button("Choose…") { model.chooseHostPath() }
                                    .accessibilityIdentifier("copy.chooseHost")
                            }
                        }
                        if let error = model.hostPathError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.dsStateDestructive)
                        }
                        Text("Both paths must be absolute.")
                            .font(.caption)
                            .foregroundStyle(Color.dsTextSecondary)
                    }

                    if let errorMessage = model.errorMessage {
                        Section {
                            InlineBanner(
                                message: "The files could not be copied",
                                detail: errorMessage,
                                scope: .card,
                                severity: .error,
                                copyValue: errorMessage
                            )
                            .accessibilityIdentifier("copy.error")
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .disabled(model.isCopying)
        } footer: {
            SheetCancelButton(accessibilityID: "copy.cancel") { dismiss() }
            Spacer()
            if model.isCopying {
                ProgressView().controlSize(.small)
            }
            Button("Copy") {
                Task { if await model.copy(using: appModel) { dismiss() } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCopy)
            .accessibilityIdentifier("copy.submit")
        }
        .interactiveDismissDisabled(model.isCopying)
    }
}
