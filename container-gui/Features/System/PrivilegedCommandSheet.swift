import AppKit
import Observation
import SwiftUI

/// Runs one `sudo container …` invocation in an embedded terminal.
///
/// The DNS mutations write `/etc/resolver`, which needs root. The app offers two
/// ways to get there: the macOS authorization dialog, where the system collects
/// the password and the app never sees it, and this — `sudo` behind a
/// pseudo-terminal, where the password is typed into the terminal the app is
/// rendering. This one exists because it shows the command actually running and
/// prints whatever the CLI has to say, which the authorization dialog cannot.
///
/// `sudo` refuses to prompt without a controlling terminal; the pseudo-terminal
/// is what supplies one. Keystrokes travel through the session into the pty. The
/// app does not store, echo, or log them — but it is the app's own terminal, not
/// the system's, which is the trade being made here.
@MainActor
@Observable
final class PrivilegedCommandModel: Identifiable {
    let id = UUID()
    let title: LocalizedStringResource
    let sudoCommand: String
    private let arguments: [String]
    private let service: any DNSManaging

    private(set) var session: (any InteractiveProcessSession)?
    private(set) var exitCode: Int32?
    private(set) var startFailure: String?

    init(
        title: LocalizedStringResource,
        arguments: [String],
        sudoCommand: String,
        service: any DNSManaging
    ) {
        self.title = title
        self.arguments = arguments
        self.sudoCommand = sudoCommand
        self.service = service
    }

    var isRunning: Bool { session != nil && exitCode == nil }
    var didSucceed: Bool { exitCode == 0 }

    func start(terminalSize: TerminalSize = .default) {
        guard session == nil else { return }
        startFailure = nil
        exitCode = nil
        do {
            session = try service.attachPrivileged(
                arguments: arguments,
                terminalSize: terminalSize
            )
        } catch {
            startFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    func finish(exitCode: Int32) { self.exitCode = exitCode }

    func terminate() {
        session?.terminate()
        session = nil
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sudoCommand, forType: .string)
    }
}

struct PrivilegedCommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: PrivilegedCommandModel
    /// Called once the command has exited cleanly, so the DNS list can reload
    /// from `/etc/resolver` rather than from what was asked for.
    let onSuccess: () async -> Void

    var body: some View {
        SheetScaffold(
            command: model.sudoCommand,
            commandAccessibilityID: "system.dns.sudo.command",
            minHeight: 460
        ) {
            VStack(spacing: 0) {
                SheetHeader(title: model.title) {
                    if let exitCode = model.exitCode {
                        StateChip(
                            title: exitCode == 0 ? "Finished" : "Exited \(exitCode)",
                            state: exitCode == 0 ? .running : .destructive
                        )
                    }
                }

                if model.session == nil {
                    InlineBanner(
                        message: "sudo will ask for your administrator password in the terminal below. It is typed into Container GUI’s own terminal, not the macOS password dialog — cancel and use Add Domain if you would rather macOS collected it.",
                        scope: .bar,
                        severity: .attention
                    )
                    .padding(DSMetrics.spacing12)
                }

                if let failure = model.startFailure {
                    InlineBanner(
                        message: "The command could not be started",
                        detail: failure,
                        scope: .bar,
                        severity: .error
                    )
                    .padding(DSMetrics.spacing12)
                }

                if let session = model.session {
                    EmbeddedTerminalView(session: session) { exitCode in
                        model.finish(exitCode: exitCode)
                        if exitCode == 0 {
                            Task { await onSuccess() }
                        }
                    }
                    .frame(minHeight: 260)
                    .background(Color(nsColor: .textBackgroundColor))
                    .accessibilityIdentifier("system.dns.sudo.terminal")
                } else {
                    Spacer(minLength: 0)
                }
            }
        } footer: {
            SheetCancelButton(
                title: model.session == nil ? "Cancel" : "Close",
                accessibilityID: "system.dns.sudo.close"
            ) {
                model.terminate()
                dismiss()
            }

            Spacer()

            Button("Copy Command") { model.copyCommand() }
                .accessibilityIdentifier("system.dns.sudo.copy")

            if model.session == nil {
                Button("Run with sudo") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("system.dns.sudo.run")
            }
        }
        .interactiveDismissDisabled(model.isRunning)
    }
}
