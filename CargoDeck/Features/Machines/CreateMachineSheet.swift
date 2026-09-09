import AppKit
import SwiftUI

enum MachineCreateSection: String, SheetSection {
    case machine
    case resources
    case advanced

    /// Only the image must be supplied; every other field opens pre-filled with
    /// what the CLI would have computed.
    var isRequired: Bool { self == .machine }

    var title: LocalizedStringResource {
        switch self {
        case .machine: "Machine"
        case .resources: "Resources"
        case .advanced: "Advanced"
        }
    }
}

/// Every flag on `machine create` is here, but the defaults are pre-filled from
/// what the CLI would compute, so the sheet is submittable as soon as an image
/// is named. The command preview lists only what was actually changed.
struct CreateMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: MachineCreateModel
    let model: MachineModel
    @State private var isSubmitting = false
    @State private var page: MachineCreateSection = .machine

    var body: some View {
        SheetScaffold(
            command: draft.commandPreview,
            commandAccessibilityID: "machines.create.preview"
        ) {
            SheetSectionPane(
                title: "Create machine",
                selection: $page,
                accessibilityID: "machines.create.rail"
            ) {
                currentPage
                progressSection
                errorSection
            }
            .disabled(isSubmitting)
        } footer: {
            footer
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .machine:
            Section("Image") {
                MachineValidatedField(
                    title: "Image",
                    text: $draft.image,
                    prompt: "alpine:3.22",
                    error: draft.imageError,
                    accessibilityIdentifier: "machines.create.image"
                )
                Text("Any OCI reference. It is pulled if you don’t have it.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Section("Name") {
                MachineValidatedField(
                    title: "Name",
                    text: $draft.name,
                    prompt: "Derived from the image when blank",
                    error: draft.nameError,
                    accessibilityIdentifier: "machines.create.name"
                )
                Text("A second machine from the same image needs its own name.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Section("Platform") {
                Picker("Operating system", selection: $draft.operatingSystem) {
                    Text("linux").tag("linux")
                }
                .accessibilityIdentifier("machines.create.os")
                Picker("Architecture", selection: $draft.architecture) {
                    Text("arm64").tag("arm64")
                    Text("amd64").tag("amd64")
                }
                .accessibilityIdentifier("machines.create.arch")
                Text("Only used if the image is multi-platform. Defaults to this Mac.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }

        case .resources:
            Section("Resources") {
                Stepper(value: $draft.cpus, in: 1...256) {
                    LabeledContent("CPUs") {
                        MonoText(value: String(draft.cpus), tabular: true)
                    }
                }
                .accessibilityIdentifier("machines.create.cpus")
                Text("Half your cores, minimum 4 — this Mac defaults to \(draft.defaults.cpus).")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)

                MachineValidatedField(
                    title: "Memory",
                    text: $draft.memory,
                    prompt: draft.defaults.memory,
                    error: draft.memoryError,
                    accessibilityIdentifier: "machines.create.memory"
                )
                Text("Half your RAM. Must be greater than 1G.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Section("Home folder") {
                Picker("Mount your home folder", selection: $draft.homeMount) {
                    Text("Read & write").tag(MachineHomeMount.readWrite)
                    Text("Read only").tag(MachineHomeMount.readOnly)
                    Text("Don’t mount").tag(MachineHomeMount.none)
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("machines.create.homeMount")
                Text("Your home folder appears inside the machine, so shells open in the directory you were in.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }

        case .advanced:
            Section("Nested virtualization") {
                Toggle("Enable nested virtualization", isOn: $draft.nestedVirtualization)
                    .accessibilityIdentifier("machines.create.virtualization")
                Text("Lets you run VMs inside the machine. Needs Apple Silicon M3 or newer on macOS 15+, and a kernel built with CONFIG_KVM=y.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
                Text(draft.nestedVirtualizationNote)
                    .font(.caption)
                    .foregroundStyle(
                        draft.defaults.supportsNestedVirtualization
                            ? Color.dsStateRunning
                            : Color.dsStateAttention
                    )
            }
            Section("Custom kernel") {
                MachineValidatedField(
                    title: "Kernel",
                    text: $draft.kernelPath,
                    prompt: "system default",
                    error: draft.kernelError,
                    accessibilityIdentifier: "machines.create.kernel"
                )
                Button("Choose…") { chooseKernel() }
                    .accessibilityIdentifier("machines.create.chooseKernel")
                Text("Checked before boot: must be a readable, non-empty file.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Section {
                Toggle("Boot after creating", isOn: $draft.bootsAfterCreating)
                    .accessibilityIdentifier("machines.create.boot")
                Toggle("Make this the default machine", isOn: $draft.setsDefault)
                    .accessibilityIdentifier("machines.create.setDefault")
                Text("Commands that omit a machine ID use the default machine.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if isSubmitting {
            Section {
                // Three steps, and the image fetch is the slow one — creating
                // says so rather than showing an unexplained spinner.
                ProgressView("Fetching the image, creating the machine\(draft.bootsAfterCreating ? ", then booting it" : "")…")
                    .accessibilityIdentifier("machines.create.progress")
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let failure = model.mutationFailure {
            Section {
                InlineBanner(
                    message: "Machine could not be created",
                    detail: failure,
                    scope: .card,
                    severity: .error
                )
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        SheetCancelButton(
            title: isSubmitting ? "Creating…" : "Cancel",
            accessibilityID: "machines.create.cancel"
        ) {
            dismiss()
        }
        .disabled(isSubmitting)

        Spacer()

        SheetPagingButtons(
            selection: $page,
            isDisabled: isSubmitting,
            accessibilityIDPrefix: "machines.create"
        )

        Button("Create") { Task { await submit() } }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!draft.canCreate || isSubmitting || model.isBusy)
            .accessibilityIdentifier("machines.create.submit")
    }

    private func submit() async {
        guard let configuration = draft.configuration else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if await model.create(configuration) {
            dismiss()
        }
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

private struct MachineValidatedField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    let prompt: String
    let error: String?
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                TextField(prompt, text: $text)
                    .dsMonoField()
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
            }
        }
    }
}
