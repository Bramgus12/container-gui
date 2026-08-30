import AppKit
import SwiftUI

/// Two states in one sheet: the form that builds the command, then the live
/// terminal it runs in. A blank command is a login shell; anything typed runs
/// once and prints its output. Both land in the same terminal, because both are
/// a process on the other side of a pseudo-terminal.
struct RunInMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: MachineRunModel
    @State private var confirmsClose = false

    var body: some View {
        SheetScaffold(
            command: draft.commandPreview,
            commandAccessibilityID: "machine.run.preview",
            minHeight: 620
        ) {
            VStack(spacing: 0) {
                header
                if draft.session == nil {
                    Form { formSections }
                        .formStyle(.grouped)
                } else {
                    terminal
                }
            }
        } footer: {
            footer
        }
        .interactiveDismissDisabled(draft.isRunningSession)
        .alert("Stop the running command?", isPresented: $confirmsClose) {
            Button("Stop and Close", role: .destructive) {
                draft.terminate()
                dismiss()
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Closing this sheet ends the session in \(draft.machineID).")
        }
    }

    private var header: some View {
        SheetHeader(title: "Run in machine") {
            HStack(spacing: DSMetrics.spacing8) {
                MonoText(value: draft.machineID, truncation: .middle)
                if draft.willBootFirst, draft.session == nil {
                    StateChip(title: "Will boot first", state: .attention)
                }
                if let exitCode = draft.exitCode {
                    StateChip(
                        title: exitCode == 0 ? "Exited 0" : "Exited \(exitCode)",
                        state: exitCode == 0 ? .idle : .destructive
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var formSections: some View {
        Section("Command") {
            TextField("login shell", text: $draft.command)
                .dsMonoField()
                .accessibilityIdentifier("machine.run.command")
            Text("Leave blank for an interactive login shell. Type a command to run it once and print the output — nproc, cat /proc/cpuinfo.")
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
        }

        Section("Run as") {
            Toggle("Run as root", isOn: $draft.runsAsRoot)
                .accessibilityIdentifier("machine.run.root")
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("User") {
                    TextField("name, uid, or uid:gid", text: $draft.user)
                        .dsMonoField()
                        .accessibilityIdentifier("machine.run.user")
                }
                if let error = draft.userError {
                    Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
                }
            }
            .disabled(draft.runsAsRoot)
        }

        Section("Working directory") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("The machine’s home directory", text: $draft.workingDirectory)
                    .dsMonoField()
                    .accessibilityIdentifier("machine.run.workdir")
                if let error = draft.workingDirectoryError {
                    Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
                }
            }
            Text("A directory inside your mounted home mirrors the one on your Mac.")
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
        }

        Section {
            ForEach($draft.environment) { $variable in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DSMetrics.spacing8) {
                        TextField("KEY", text: $variable.key)
                            .dsMonoField()
                        TextField("value", text: $variable.value)
                            .dsMonoField()
                        Button("Remove", systemImage: "minus.circle") {
                            draft.removeEnvironmentVariable(id: variable.id)
                        }
                        .labelStyle(.iconOnly)
                    }
                    if let error = draft.environmentError(for: variable) {
                        Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
                    }
                }
            }
            Button("Add variable") { draft.addEnvironmentVariable() }
                .accessibilityIdentifier("machine.run.addEnv")

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("From file") {
                    TextField(".env.local", text: $draft.environmentFile)
                        .dsMonoField()
                        .accessibilityIdentifier("machine.run.envFile")
                }
                if let error = draft.environmentFileError {
                    Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
                }
            }
        } header: {
            Text("Environment")
        } footer: {
            Text("PATH is always set for you.")
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
        }

        Section {
            Toggle("Detach and keep it running", isOn: $draft.detached)
                .accessibilityIdentifier("machine.run.detach")
            // The CLI ignores --tty for a login shell, so the control is stated
            // rather than offered: it is always on, and saying so is clearer
            // than a toggle that does nothing.
            LabeledContent("Terminal") {
                Text(draft.isLoginShell
                    ? "Always allocated for a login shell"
                    : "Allocated so the command can be interactive")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }

        if let failure = draft.startFailure {
            Section {
                InlineBanner(
                    message: "The session could not be started",
                    detail: failure,
                    scope: .card,
                    severity: .error
                )
            }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let session = draft.session {
            EmbeddedTerminalView(session: session) { exitCode in
                draft.finish(exitCode: exitCode)
            }
            .frame(minHeight: 360)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityIdentifier("machine.run.terminal")
        }
    }

    @ViewBuilder
    private var footer: some View {
        SheetCancelButton(
            title: draft.session == nil ? "Cancel" : "Close",
            accessibilityID: "machine.run.cancel"
        ) {
            if draft.isRunningSession {
                confirmsClose = true
            } else {
                draft.terminate()
                dismiss()
            }
        }

        Spacer()

        if draft.session == nil {
            Button(draft.isLoginShell ? "Open Shell" : "Run") {
                draft.start()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!draft.canStart)
            .accessibilityIdentifier("machine.run.submit")
        }
    }
}
