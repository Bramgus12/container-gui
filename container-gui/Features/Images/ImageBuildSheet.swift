import AppKit
import SwiftUI

struct ImageBuildSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImageBuildModel
    let appModel: AppModel
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                BuildSourceSection(model: model)
                BuildOptionsSection(model: model)
                BuildArgumentsSection(model: model)
                BuildLabelsSection(model: model)
                BuildOutputSection(model: model)
                Section("Command Preview") {
                    Text(model.commandPreview)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("images.build.preview")
                }
                BuildProgressSection(model: model)
            }
            .formStyle(.grouped)
            .disabled(model.isBuilding)

            Divider()

            HStack {
                if model.isBuilding {
                    Button("Cancel Build", role: .cancel) { operation?.cancel() }
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("Build") {
                    operation = Task {
                        let outcome = await model.build(using: appModel)
                        if outcome == .succeeded { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canBuild)
                .accessibilityIdentifier("images.build.submit")
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 720)
        .interactiveDismissDisabled(model.isBuilding)
        .onDisappear { operation?.cancel() }
        .accessibilityIdentifier("images.build.sheet")
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
            HStack {
                BuildValidatedField(
                    title: "Context directory",
                    text: $model.contextDirectory,
                    prompt: "/path/to/project",
                    error: model.contextError,
                    accessibilityIdentifier: "images.build.context"
                )
                Button("Choose…") { chooseDirectory() }
            }
            HStack {
                BuildValidatedField(
                    title: "Dockerfile",
                    text: $model.dockerfile,
                    prompt: "Optional; defaults to Dockerfile or Containerfile",
                    error: model.dockerfileError,
                    accessibilityIdentifier: "images.build.dockerfile"
                )
                Button("Choose…") { chooseDockerfile() }
            }
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
            HStack {
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
            }
            HStack {
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
            }
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

private struct BuildProgressSection: View {
    let model: ImageBuildModel

    var body: some View {
        if model.isBuilding || !model.progress.isEmpty || model.errorMessage != nil {
            Section("Progress") {
                if model.isBuilding { ProgressView("Building image…") }
                if !model.progress.isEmpty {
                    ScrollView {
                        Text(model.progress)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 140, maxHeight: 260)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
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
                TextField("Key", text: $draft.key).frame(width: 200)
                TextField("Value", text: $draft.value)
                Button("Remove", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct BuildValidatedField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    let prompt: String
    let error: String?
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                TextField(prompt, text: $text)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
