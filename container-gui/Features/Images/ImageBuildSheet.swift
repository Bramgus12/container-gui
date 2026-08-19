import AppKit
import SwiftUI

struct ImageBuildSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImageBuildModel
    let appModel: AppModel
    @State private var operation: Task<Void, Never>?
    @State private var page: BuildSection = .source
    /// Raised when a build starts and left up after it ends, so a failed
    /// build's output stays readable until the form is reopened.
    @State private var showsLog = false

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "images.build.preview"
        ) {
            if showsLog {
                BuildLogPane(model: model)
            } else {
                SheetSectionPane(
                    title: "Build image",
                    selection: $page,
                    count: railCount(for:),
                    accessibilityID: "images.build.rail"
                ) {
                    currentPage
                }
            }
        } footer: {
            footer
        }
        .interactiveDismissDisabled(model.isBuilding)
        .onDisappear { operation?.cancel() }
    }

    private func railCount(for section: BuildSection) -> Int? {
        switch section {
        case .source: nil
        case .options: model.optionSetCount
        case .metadata: model.buildArguments.count + model.labels.count
        case .output: model.exportsOutput ? 1 : nil
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .source:
            BuildSourceSection(model: model)
            if appModel.builderModel?.status.state != .running {
                Section {
                    InlineBanner(
                        message: "The image builder is stopped",
                        detail: "It will be started when the build begins.",
                        scope: .card,
                        severity: .attention
                    )
                }
            }
        case .options:
            BuildOptionsSection(model: model)
        case .metadata:
            BuildArgumentsSection(model: model)
            BuildLabelsSection(model: model)
        case .output:
            BuildOutputSection(model: model)
        }
    }

    @ViewBuilder
    private var footer: some View {
        SheetCancelButton(
            title: model.isBuilding ? "Cancel Build" : "Cancel",
            accessibilityID: "images.build.cancel"
        ) {
            if model.isBuilding {
                operation?.cancel()
            } else {
                dismiss()
            }
        }

        Spacer()

        if showsLog {
            Button("Edit Build") { showsLog = false }
                .disabled(model.isBuilding)
                .accessibilityIdentifier("images.build.edit")
        } else {
            SheetPagingButtons(selection: $page, accessibilityIDPrefix: "images.build")
        }

        // Build stays available from any page: only the first page is
        // required, so there is no reason to walk the rest to start.
        Button("Build") { startBuild() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canBuild)
            .accessibilityIdentifier("images.build.submit")
    }

    private func startBuild() {
        showsLog = true
        operation = Task {
            let outcome = await model.build(using: appModel)
            if outcome == .succeeded { dismiss() }
        }
    }
}

/// The four form sections, in the order the rail lists them.
enum BuildSection: String, SheetSection {
    case source
    case options
    case metadata
    case output

    /// Only the tag and build context must be filled in; the rest are optional
    /// refinements, and the rail marks them as such.
    var isRequired: Bool { self == .source }

    var title: LocalizedStringResource {
        switch self {
        case .source: "Source"
        case .options: "Build Options"
        case .metadata: "Metadata"
        case .output: "Output"
        }
    }
}

/// Takes over the whole pane while a build runs, and stays up afterwards if the
/// build failed, because the streamed output is the only thing that matters at
/// that point.
private struct BuildLogPane: View {
    let model: ImageBuildModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DSMetrics.spacing8) {
                if model.isBuilding {
                    ProgressView().controlSize(.small)
                    SectionLabel(title: "Building image")
                } else {
                    SectionLabel(title: "Build output")
                }
                Spacer()
            }
            .padding(DSMetrics.spacing12)

            Divider()

            ScrollView {
                Group {
                    if model.progress.isEmpty {
                        Text("Waiting for output…")
                            .foregroundStyle(Color.dsTextSecondary)
                    } else {
                        Text(model.progress)
                            .font(DSFont.mono(size: 12.5, relativeTo: .callout))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSMetrics.spacing12)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = model.errorMessage {
                Divider()
                InlineBanner(
                    message: "The build failed",
                    detail: error,
                    scope: .bar,
                    severity: .error,
                    copyValue: error
                )
                .padding(DSMetrics.spacing12)
                .accessibilityIdentifier("images.build.error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsSurface)
    }
}

private struct BuildSourceSection: View {
    @Bindable var model: ImageBuildModel

    var body: some View {
        Section("Image and Source") {
            BuildValidatedField(
                title: "Tag",
                text: $model.tag,
                prompt: "Required, for example my-app:latest",
                error: model.tagError,
                accessibilityIdentifier: "images.build.tag"
            )
            BuildValidatedField(
                title: "Context directory",
                text: $model.contextDirectory,
                prompt: "/path/to/project",
                error: model.contextError,
                accessibilityIdentifier: "images.build.context",
                onChoose: chooseDirectory
            )
            BuildValidatedField(
                title: "Dockerfile",
                text: $model.dockerfile,
                prompt: "Optional",
                error: model.dockerfileError,
                accessibilityIdentifier: "images.build.dockerfile",
                onChoose: chooseDockerfile
            )
            Text("Leave the Dockerfile empty to use the Dockerfile or Containerfile found in the context directory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.contextDirectory = url.path
        }
    }

    private func chooseDockerfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.dockerfile = url.path
            if model.contextDirectory.isEmpty {
                model.contextDirectory = url.deletingLastPathComponent().path
            }
        }
    }
}

private struct BuildOptionsSection: View {
    @Bindable var model: ImageBuildModel

    var body: some View {
        Section("Build Options") {
            Toggle("Pull newer base images", isOn: $model.pull)
            Toggle("Disable build cache", isOn: $model.noCache)
            BuildValidatedField(
                title: "Target stage",
                text: $model.target,
                prompt: "Optional",
                error: model.targetError,
                accessibilityIdentifier: "images.build.target"
            )
            BuildValidatedField(
                title: "Platform",
                text: $model.platform,
                prompt: "Optional, for example linux/arm64",
                error: model.platformError,
                accessibilityIdentifier: "images.build.platform"
            )
            BuildValidatedField(
                title: "OS",
                text: $model.operatingSystem,
                prompt: "Used when platform is empty",
                error: model.operatingSystemError,
                accessibilityIdentifier: "images.build.os"
            )
            BuildValidatedField(
                title: "Architecture",
                text: $model.architecture,
                prompt: "Used when platform is empty",
                error: model.architectureError,
                accessibilityIdentifier: "images.build.architecture"
            )
            BuildValidatedField(
                title: "CPU limit",
                text: $model.cpuLimit,
                prompt: "Optional, for example 2",
                error: model.cpuLimitError,
                accessibilityIdentifier: "images.build.cpus"
            )
            BuildValidatedField(
                title: "Memory limit",
                text: $model.memoryLimit,
                prompt: "Optional, for example 4G",
                error: model.memoryLimitError,
                accessibilityIdentifier: "images.build.memory"
            )
            Text("Build secrets and SSH forwarding are not supported in this version of Container GUI.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BuildArgumentsSection: View {
    @Bindable var model: ImageBuildModel

    var body: some View {
        Section("Build Arguments") {
            ForEach($model.buildArguments) { $argument in
                BuildKeyValueRow(
                    draft: $argument,
                    error: model.argumentError(for: argument),
                    onRemove: { model.removeBuildArgument(id: argument.id) }
                )
            }
            Button("Add Build Argument", systemImage: "plus") { model.addBuildArgument() }
        }
    }
}

private struct BuildLabelsSection: View {
    @Bindable var model: ImageBuildModel

    var body: some View {
        Section("Labels") {
            ForEach($model.labels) { $label in
                BuildKeyValueRow(
                    draft: $label,
                    error: model.labelError(for: label),
                    onRemove: { model.removeLabel(id: label.id) }
                )
            }
            Button("Add Label", systemImage: "plus") { model.addLabel() }
        }
    }
}

private struct BuildOutputSection: View {
    @Bindable var model: ImageBuildModel

    var body: some View {
        Section("Output") {
            Toggle("Export an additional build output", isOn: $model.exportsOutput)
            if model.exportsOutput {
                Picker("Type", selection: $model.outputType) {
                    ForEach(BuildOutputType.allCases, id: \.rawValue) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                BuildValidatedField(
                    title: "Destination",
                    text: $model.outputDestination,
                    prompt: "Optional absolute path",
                    error: model.outputDestinationError,
                    accessibilityIdentifier: "images.build.output"
                )
            }
        }
    }
}

private struct BuildKeyValueRow: View {
    @Binding var draft: BuildKeyValueDraft
    let error: String?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Wide enough for reverse-DNS label keys such as
                // org.opencontainers.image.source without truncating.
                TextField(text: $draft.key, prompt: Text("Key")) { Text("Key") }
                    .labelsHidden()
                    .dsMonoField()
                    .frame(width: 260)
                TextField(text: $draft.value, prompt: Text("Value")) { Text("Value") }
                    .labelsHidden()
                    .dsMonoField()
                Button("Remove", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
            }
        }
    }
}

private struct BuildValidatedField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    let prompt: LocalizedStringResource
    let error: String?
    let accessibilityIdentifier: String
    /// Fields that name a path get a browse button on the same row.
    var onChoose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                HStack(spacing: DSMetrics.spacing8) {
                    // The hint belongs in the placeholder. Passing it as the
                    // field's title instead renders it as a second visible
                    // label inside the row, which is what used to wrap.
                    TextField(text: $text, prompt: Text(prompt)) {
                        Text(title)
                    }
                    .labelsHidden()
                    .dsMonoField()
                    .multilineTextAlignment(.leading)
                    // Claim the rest of the row. Left to size itself, the field
                    // hugs its placeholder and LabeledContent drops it onto a
                    // second line whenever the hint is long.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(accessibilityIdentifier)
                    if let onChoose {
                        Button("Choose…", action: onChoose)
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
            }
        }
    }
}
