import AppKit
import SwiftUI

/// A running / after-restart pair rather than a plain form. It is the only
/// layout that tells the truth about `machine set`, and it turns the CLI's
/// stderr note into something you can act on.
struct MachineBootConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: MachineBootConfigurationModel
    let model: MachineModel
    @State private var isSubmitting = false

    var body: some View {
        SheetScaffold(
            command: draft.commandPreview,
            commandAccessibilityID: "machine.boot.preview"
        ) {
            VStack(spacing: 0) {
                SheetHeader(title: "Boot configuration") {
                    HStack(spacing: DSMetrics.spacing8) {
                        MonoText(value: draft.machineID, truncation: .middle)
                        if draft.changeCount > 0 {
                            StateChip(
                                title: "\(draft.changeCount) changes pending",
                                state: .attention
                            )
                        }
                    }
                }

                if draft.isRunning {
                    InlineBanner(
                        message: "The machine is running on the left column. Nothing you change here touches it until it restarts.",
                        scope: .bar,
                        severity: .info
                    )
                    .padding(DSMetrics.spacing12)
                }

                Form {
                    settingsSection
                    if let failure = model.mutationFailure {
                        Section {
                            InlineBanner(
                                message: "Configuration could not be applied",
                                detail: failure,
                                scope: .card,
                                severity: .error
                            )
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .disabled(isSubmitting)
        } footer: {
            footer
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var settingsSection: some View {
        Section {
            BootSettingRow(label: "CPUs", current: draft.currentCPUs.map(String.init)) {
                Stepper(value: $draft.cpus, in: 1...256) {
                    MonoText(value: String(draft.cpus), tabular: true)
                }
                .accessibilityIdentifier("machine.boot.cpus")
            }

            BootSettingRow(label: "Memory", current: draft.currentMemory) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("8G", text: $draft.memory)
                        .dsMonoField()
                        .accessibilityIdentifier("machine.boot.memory")
                    if let error = draft.memoryError {
                        Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
                    }
                }
            }

            BootSettingRow(label: "Home mount", current: draft.currentHomeMount?.rawValue) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $draft.homeMount) {
                        Text("rw").tag(MachineHomeMount.readWrite)
                        Text("ro").tag(MachineHomeMount.readOnly)
                        Text("none").tag(MachineHomeMount.none)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("machine.boot.homeMount")
                    if draft.homeMount == MachineHomeMount.none {
                        Text("“none” also changes where shells open.")
                            .font(.caption)
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }
            }

            BootSettingRow(
                label: "Nested virtualization",
                current: draft.currentVirtualization.map(String.init)
            ) {
                Toggle("", isOn: $draft.virtualization)
                    .labelsHidden()
                    .accessibilityIdentifier("machine.boot.virtualization")
            }

            BootSettingRow(label: "Kernel", current: draft.currentKernel ?? "system default") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DSMetrics.spacing8) {
                        TextField("system default", text: $draft.kernelPath)
                            .dsMonoField()
                            .accessibilityIdentifier("machine.boot.kernel")
                        Button("Choose…") { chooseKernel() }
                            .accessibilityIdentifier("machine.boot.chooseKernel")
                    }
                    if let error = draft.kernelError {
                        Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
                    }
                }
            }
        } header: {
            HStack {
                Text("Setting").frame(width: 170, alignment: .leading)
                Text("Running now").frame(width: 130, alignment: .leading)
                Text("After restart")
                Spacer()
            }
            .font(.dsSectionLabel)
            .textCase(.uppercase)
            .foregroundStyle(Color.dsTextSecondary)
        } footer: {
            if draft.isRunning {
                Text("Applying writes the configuration immediately, but \(draft.machineID) keeps running on its old values until you stop and start it.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            } else {
                Text("\(draft.machineID) is stopped, so these values are used the next time it boots.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        SheetCancelButton(
            title: isSubmitting ? "Applying…" : "Cancel",
            accessibilityID: "machine.boot.cancel"
        ) {
            dismiss()
        }
        .disabled(isSubmitting)

        Button("Revert all") { draft.revert() }
            .disabled(draft.changeCount == 0 || isSubmitting)
            .accessibilityIdentifier("machine.boot.revert")

        Spacer()

        Button("Apply only") { Task { await apply(restart: false) } }
            .disabled(!draft.canApply || isSubmitting || model.isBusy)
            .accessibilityIdentifier("machine.boot.apply")

        if draft.isRunning {
            Button("Apply & Restart") { Task { await apply(restart: true) } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canApply || isSubmitting || model.isBusy)
                .accessibilityIdentifier("machine.boot.applyRestart")
        }
    }

    private func apply(restart: Bool) async {
        isSubmitting = true
        defer { isSubmitting = false }
        let applied = await model.applyBootConfiguration(
            machineID: draft.machineID,
            boot: draft.changes
        )
        guard applied else { return }
        if restart {
            // Only the stop half is ours: the machine boots again on the next
            // `machine run`, which is what the CLI itself does.
            await model.stop(machineID: draft.machineID)
        }
        dismiss()
    }

    private func chooseKernel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a kernel binary, for example vmlinux.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.kernelPath = url.path
    }
}

/// One row of the current-versus-next table: what the machine runs on now, and
/// the control that sets what it will run on next.
private struct BootSettingRow<Editor: View>: View {
    let label: LocalizedStringResource
    let current: String?
    @ViewBuilder let editor: () -> Editor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSMetrics.spacing12) {
            Text(label)
                .frame(width: 170, alignment: .leading)
            Group {
                if let current {
                    MonoText(value: current, dimmed: true, tabular: true)
                } else {
                    Text("not reported")
                        .font(.caption)
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
            .frame(width: 130, alignment: .leading)
            editor()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
