import AppKit
import SwiftUI

@MainActor
@Observable
final class ExportContainerModel: Identifiable {
    let id = UUID()
    let containerID: String
    /// Whether the container was running when the export was asked for. The CLI
    /// allows it, but the archive is a snapshot taken while the filesystem is
    /// still being written to, so the sheet says so.
    let containerWasRunning: Bool
    let destination: String
    private(set) var isExporting = false
    private(set) var progress = ""
    private(set) var errorMessage: String?
    private(set) var didFinish = false

    init(containerID: String, destination: String, containerWasRunning: Bool) {
        self.containerID = containerID
        self.destination = destination
        self.containerWasRunning = containerWasRunning
    }

    var commandPreview: String {
        guard let identifier = try? ContainerIdentifier(validating: containerID),
              let path = try? LocalPath(validating: destination, field: "Export path")
        else {
            return "container export"
        }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.exportContainer(id: identifier, output: path).arguments
        )
    }

    func export(using appModel: AppModel) async -> Bool {
        guard !isExporting else { return false }

        isExporting = true
        progress = ""
        errorMessage = nil
        didFinish = false
        defer { isExporting = false }

        do {
            try await appModel.exportContainer(
                id: containerID,
                to: destination
            ) { [weak self] event in
                self?.record(event)
            }
            didFinish = true
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

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: destination)])
    }

    private func record(_ event: ProcessEvent) {
        let text: String
        switch event {
        case .standardOutput(let output), .standardError(let output):
            text = output
        case .terminated(let exitCode):
            text = "Process exited with status \(exitCode).\n"
        }

        progress.append(DiagnosticSanitizer.sanitize(text))
        let maximumCharacters = 32_768
        if progress.count > maximumCharacters {
            progress = String(progress.suffix(maximumCharacters))
        }
    }
}

/// Runs the export and shows what the CLI reports. The destination is chosen in
/// a save panel before this opens, so there is nothing to fill in here — the
/// sheet exists to give a long archive write somewhere to report progress and a
/// way to stop it.
struct ExportContainerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ExportContainerModel
    let appModel: AppModel
    @State private var exportRequestID: UUID?
    @State private var isCancelling = false

    private var operationIsActive: Bool {
        exportRequestID != nil || model.isExporting || isCancelling
    }

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "export.preview",
            minHeight: 400
        ) {
            VStack(spacing: 0) {
                SheetHeader(title: "Export Container")
                Form {
                    Section("Archive") {
                        LabeledContent("Container") {
                            MonoText(value: model.containerID)
                        }
                        LabeledContent("Destination") {
                            MonoText(value: model.destination, truncation: .head)
                        }
                        if model.containerWasRunning {
                            InlineBanner(
                                message: """
                                “\(model.containerID)” is running, so the archive is a \
                                snapshot of a filesystem that is still being written to. \
                                Stop the container first for a consistent copy.
                                """,
                                scope: .card,
                                severity: .attention
                            )
                            .accessibilityIdentifier("export.runningWarning")
                        }
                    }

                    if operationIsActive || !model.progress.isEmpty {
                        Section("Progress") {
                            if operationIsActive {
                                ProgressView("Writing the archive…")
                            }
                            if !model.progress.isEmpty {
                                ScrollView {
                                    Text(model.progress)
                                        .font(DSFont.mono(size: 12.5, relativeTo: .callout))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 140)
                                .accessibilityIdentifier("export.progress")
                            }
                        }
                    }

                    if let errorMessage = model.errorMessage {
                        Section {
                            InlineBanner(
                                message: "The container could not be exported",
                                detail: errorMessage,
                                scope: .card,
                                severity: .error,
                                copyValue: errorMessage
                            )
                            .accessibilityIdentifier("export.error")
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } footer: {
            SheetCancelButton(
                title: isCancelling ? "Cancelling…" : operationIsActive ? "Cancel Export" : "Close",
                accessibilityID: "export.cancel"
            ) {
                if operationIsActive {
                    isCancelling = true
                    exportRequestID = nil
                } else {
                    dismiss()
                }
            }
            .disabled(isCancelling)

            Spacer()

            if model.didFinish {
                Button("Reveal in Finder") { model.revealInFinder() }
                    .accessibilityIdentifier("export.reveal")
            }

            Button("Export") {
                exportRequestID = UUID()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(operationIsActive || model.didFinish)
            .accessibilityIdentifier("export.submit")
        }
        .interactiveDismissDisabled(operationIsActive)
        .task(id: exportRequestID) {
            guard let requestID = exportRequestID else { return }
            _ = await model.export(using: appModel)

            guard exportRequestID == requestID else {
                isCancelling = false
                return
            }
            exportRequestID = nil
            isCancelling = false
        }
    }
}
