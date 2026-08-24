import AppKit
import SwiftUI

@MainActor
@Observable
final class ExecModel: Identifiable {
    let id = UUID()
    let containerID: String
    var command = ""
    var arguments: [CommandArgumentDraft] = []
    var environment: [EnvironmentVariableDraft] = []
    var user = ""
    var workingDirectory = ""
    private(set) var isRunning = false
    private(set) var output = ""
    private(set) var errorMessage: String?

    init(containerID: String) {
        self.containerID = containerID
    }

    var commandError: String? {
        validationMessage(for: command) { value in
            _ = try ExecConfiguration(command: [value])
        }
    }

    var userError: String? {
        validationMessage(for: user) { value in
            _ = try ProcessUser(validating: value)
        }
    }

    var workingDirectoryError: String? {
        validationMessage(for: workingDirectory) { value in
            _ = try LocalPath(validating: value, field: "Working directory")
        }
    }

    func environmentError(for draft: EnvironmentVariableDraft) -> String? {
        let key = trimmed(draft.key)
        guard !key.isEmpty else { return nil }
        do {
            _ = try EnvironmentVariable(key: key, value: draft.value)
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    var configuration: ExecConfiguration? {
        try? makeConfiguration()
    }

    var commandPreview: String {
        guard let configuration,
              let identifier = try? ContainerIdentifier(validating: containerID)
        else {
            return "container exec"
        }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.exec(id: identifier, configuration: configuration).arguments
        )
    }

    var canRun: Bool {
        configuration != nil && !isRunning
    }

    func run(using appModel: AppModel) async -> Bool {
        guard let configuration, !isRunning else { return false }

        isRunning = true
        output = ""
        errorMessage = nil
        defer { isRunning = false }

        do {
            try await appModel.execCommand(
                containerID: containerID,
                configuration: configuration
            ) { [weak self] event in
                self?.record(event)
            }
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

    func addArgument() { arguments.append(CommandArgumentDraft()) }
    func removeArgument(id: UUID) { arguments.removeAll { $0.id == id } }
    func addEnvironmentVariable() { environment.append(EnvironmentVariableDraft()) }
    func removeEnvironmentVariable(id: UUID) { environment.removeAll { $0.id == id } }

    private func makeConfiguration() throws -> ExecConfiguration {
        let executable = trimmed(command)
        let argumentValues = arguments
            .map { trimmed($0.value) }
            .filter { !$0.isEmpty }
        let variables = try environment
            .filter { !trimmed($0.key).isEmpty }
            .map { try EnvironmentVariable(key: trimmed($0.key), value: $0.value) }
        let user = trimmed(user)
        let workingDirectory = trimmed(workingDirectory)

        return try ExecConfiguration(
            command: [executable] + argumentValues,
            environment: variables,
            user: user.isEmpty ? nil : user,
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory
        )
    }

    private func record(_ event: ProcessEvent) {
        let text: String
        switch event {
        case .standardOutput(let value), .standardError(let value):
            text = value
        case .terminated(let exitCode):
            text = "Process exited with status \(exitCode).\n"
        }

        output.append(DiagnosticSanitizer.sanitize(text))
        let maximumCharacters = 32_768
        if output.count > maximumCharacters {
            output = String(output.suffix(maximumCharacters))
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

/// Runs one command in a running container and shows what it printed. The
/// process gets no terminal and no standard input, which suits the commands a
/// GUI is good for — reading a file, checking a version, listing a directory.
/// Anything that expects to be typed at belongs in a terminal, so there is a
/// button that hands the interactive form of the same command to Terminal.app.
struct ExecSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ExecModel
    let appModel: AppModel
    @State private var runRequestID: UUID?
    @State private var isCancelling = false

    private var operationIsActive: Bool {
        runRequestID != nil || model.isRunning || isCancelling
    }

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "exec.preview",
            minHeight: 520
        ) {
            VStack(spacing: 0) {
                SheetHeader(title: "Run a Command")
                Form {
                    commandSection
                    processSection
                    environmentSection
                    outputSection
                    errorSection
                }
                .formStyle(.grouped)
            }
            .disabled(operationIsActive)
        } footer: {
            SheetCancelButton(
                title: isCancelling ? "Cancelling…" : operationIsActive ? "Cancel" : "Close",
                accessibilityID: "exec.cancel"
            ) {
                if operationIsActive {
                    isCancelling = true
                    runRequestID = nil
                } else {
                    dismiss()
                }
            }
            .disabled(isCancelling)

            Spacer()

            Button("Open in Terminal") { openInTerminal() }
                .disabled(operationIsActive)
                .accessibilityIdentifier("exec.terminal")

            Button("Run") { runRequestID = UUID() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(operationIsActive || !model.canRun)
                .accessibilityIdentifier("exec.submit")
        }
        .interactiveDismissDisabled(operationIsActive)
        .task(id: runRequestID) {
            guard let requestID = runRequestID else { return }
            _ = await model.run(using: appModel)

            guard runRequestID == requestID else {
                isCancelling = false
                return
            }
            runRequestID = nil
            isCancelling = false
        }
    }

    @ViewBuilder
    private var commandSection: some View {
        Section("Command") {
            LabeledContent("Executable") {
                TextField("/bin/sh", text: $model.command)
                    .labelsHidden()
                    .dsMonoField()
                    .accessibilityIdentifier("exec.command")
            }
            if let error = model.commandError {
                Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
            }

            ForEach($model.arguments) { $argument in
                LabeledContent("Argument") {
                    HStack(spacing: DSMetrics.spacing8) {
                        TextField("-la", text: $argument.value)
                            .labelsHidden()
                            .dsMonoField()
                        Button("Remove") { model.removeArgument(id: argument.id) }
                    }
                }
            }
            Button("Add Argument") { model.addArgument() }
                .accessibilityIdentifier("exec.addArgument")
        }
    }

    @ViewBuilder
    private var processSection: some View {
        Section("Process") {
            LabeledContent("User") {
                TextField("Optional, for example root or 1000:1000", text: $model.user)
                    .labelsHidden()
                    .dsMonoField()
                    .accessibilityIdentifier("exec.user")
            }
            if let error = model.userError {
                Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
            }

            LabeledContent("Working Directory") {
                TextField("Optional, for example /app", text: $model.workingDirectory)
                    .labelsHidden()
                    .dsMonoField()
                    .accessibilityIdentifier("exec.workdir")
            }
            if let error = model.workingDirectoryError {
                Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
            }
        }
    }

    @ViewBuilder
    private var environmentSection: some View {
        Section("Environment") {
            ForEach($model.environment) { $variable in
                VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                    HStack(spacing: DSMetrics.spacing8) {
                        TextField("KEY", text: $variable.key)
                            .dsMonoField()
                        TextField("value", text: $variable.value)
                            .dsMonoField()
                        Button("Remove") { model.removeEnvironmentVariable(id: variable.id) }
                    }
                    if let error = model.environmentError(for: variable) {
                        Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
                    }
                }
            }
            Button("Add Variable") { model.addEnvironmentVariable() }
                .accessibilityIdentifier("exec.addVariable")
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        if operationIsActive || !model.output.isEmpty {
            Section("Output") {
                if operationIsActive {
                    ProgressView("Running…")
                }
                if !model.output.isEmpty {
                    ScrollView {
                        Text(model.output)
                            .font(DSFont.mono(size: 12.5, relativeTo: .callout))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .accessibilityIdentifier("exec.output")
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage = model.errorMessage {
            Section {
                InlineBanner(
                    message: "The command could not be run",
                    detail: errorMessage,
                    scope: .card,
                    severity: .error,
                    copyValue: errorMessage
                )
                .accessibilityIdentifier("exec.error")
            }
        }
    }

    /// Hands the interactive form of the command to Terminal.app. A command that
    /// wants a terminal needs one that is already wired to a keyboard, which a
    /// form in a sheet is not.
    private func openInTerminal() {
        let executable = model.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = model.arguments
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let parts = ["container", "exec", "--interactive", "--tty", model.containerID]
            + [executable.isEmpty ? "/bin/sh" : executable]
            + arguments

        let command = ProcessContainerCLI.displayInvocation(
            executable: parts[0],
            arguments: Array(parts.dropFirst())
        )
        // The command is quoted for a shell already; escaping it again for
        // AppleScript is what keeps a path with a space intact on the way
        // through.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }
}
