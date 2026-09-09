import AppKit
import SwiftUI

/// Two log files, one pane. The same tail-and-follow controls the CLI has, and
/// the boot log is the fastest place to confirm whether a machine actually came
/// up.
struct MachineLogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MachineLogsModel
    @State private var jumpRequest = 0
    @State private var isAtLatest = true

    private static let tailChoices = [100, 200, 500, 1_000]

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "machine.logs.command",
            minHeight: 600
        ) {
            VStack(spacing: 0) {
                SheetHeader(title: "Logs") {
                    MonoText(value: model.machineID, truncation: .middle)
                }
                controls
                Divider()
                content
            }
        } footer: {
            footer
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var controls: some View {
        HStack(spacing: DSMetrics.spacing12) {
            Picker("Log", selection: $model.source) {
                ForEach(MachineLogSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .accessibilityIdentifier("machine.logs.source")

            Toggle("Follow", isOn: $model.follows)
                .toggleStyle(.switch)
                .accessibilityIdentifier("machine.logs.follow")

            Picker("Show last", selection: $model.tail) {
                ForEach(Self.tailChoices, id: \.self) { count in
                    Text("Last \(count) lines").tag(count)
                }
            }
            .frame(maxWidth: 170)
            .accessibilityIdentifier("machine.logs.tail")

            Spacer()

            Picker("Filter", selection: $model.filter) {
                Text("All \(model.counts.all)").tag(LogFilter.all)
                Text("Warn \(model.counts.warnings)").tag(LogFilter.warning)
                Text("Err \(model.counts.errors)").tag(LogFilter.error)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            .accessibilityIdentifier("machine.logs.filter")
        }
        .padding(DSMetrics.spacing12)
        .background(Color.dsSurface)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure, model.snapshot.text.isEmpty {
            EmptyState(
                "Logs Couldn’t Be Read",
                systemImage: "exclamationmark.triangle",
                message: failure
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.snapshot.text.isEmpty {
            if model.isLoading {
                ProgressView("Reading logs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(
                    "No Log Output",
                    systemImage: "text.alignleft",
                    description: model.source == .boot
                        ? "This machine has no boot log yet."
                        : "This machine has not written any output yet."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            LogViewer(
                snapshot: model.snapshot,
                jumpToLatestRequest: jumpRequest,
                onTailingChange: { isAtLatest = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("machine.logs.viewer")
        }
    }

    @ViewBuilder
    private var footer: some View {
        SheetCancelButton(title: "Close", accessibilityID: "machine.logs.close") {
            dismiss()
        }

        if model.follows, !model.snapshot.text.isEmpty {
            Text("following — new lines appear here")
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
        }

        Spacer()

        LogJumpToLatestButton(isAtLatest: isAtLatest) { jumpRequest += 1 }
            .accessibilityIdentifier("machine.logs.jumpToLatest")

        LogCopyButton(hasLogs: !model.snapshot.text.isEmpty) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.plainText, forType: .string)
        }
        .accessibilityIdentifier("machine.logs.copy")

        Button("Save…") { save() }
            .disabled(model.snapshot.text.isEmpty)
            .accessibilityIdentifier("machine.logs.save")
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.machineID)-\(model.source.rawValue).log"
        panel.message = String(localized: "Save the log output to a file.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.plainText.write(to: url, atomically: true, encoding: .utf8)
    }
}
