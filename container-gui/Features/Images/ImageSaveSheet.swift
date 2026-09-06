import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ImageSaveSection: String, SheetSection {
    case images
    case destination
    case platform

    var isRequired: Bool { self != .platform }

    var title: LocalizedStringResource {
        switch self {
        case .images: "Images"
        case .destination: "Destination"
        case .platform: "Platform"
        }
    }
}

struct ImageSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImageSaveModel
    let onStart: (ImageSaveConfiguration) -> Void
    @State private var page: ImageSaveSection = .images

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "images.save.preview"
        ) {
            SheetRailPane(
                title: "Save images",
                selection: $page,
                count: { section in
                    switch section {
                    case .images: model.selectedReferences.count
                    case .destination: nil
                    case .platform: nil
                    }
                },
                accessibilityID: "images.save.rail"
            ) {
                switch page {
                case .images: checklist
                case .destination: destinationForm
                case .platform: platformForm
                }
            }
        } footer: {
            SheetCancelButton(accessibilityID: "images.save.cancel") { dismiss() }

            Spacer()

            SheetPagingButtons(selection: $page, accessibilityIDPrefix: "images.save")

            Button("Save") {
                guard let configuration = model.configuration else { return }
                onStart(configuration)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSave)
            .accessibilityIdentifier("images.save.submit")
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose at least one image to write into the archive.")
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
                .padding(DSMetrics.spacing12)
            ImageChecklist(
                images: model.available,
                selection: model.selectedReferences,
                annotation: { _ in nil },
                toggle: model.toggle,
                accessibilityID: "images.save.checklist"
            )
        }
    }

    private var destinationForm: some View {
        Form {
            Section("Archive") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Path") {
                        HStack {
                            TextField(
                                text: $model.outputPath,
                                prompt: Text(verbatim: "/Users/you/images.tar")
                            ) {
                                Text("Path")
                            }
                            .labelsHidden()
                            .dsMonoField()
                            .accessibilityIdentifier("images.save.path")

                            Button("Choose…", action: chooseDestination)
                                .accessibilityIdentifier("images.save.choose")
                        }
                    }
                    FieldError(message: model.outputError)
                    Text("An OCI-compatible tar archive. An existing file at this path is replaced.")
                        .font(.caption)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var platformForm: some View {
        Form {
            ImagePlatformSection(
                platform: $model.platform,
                operatingSystem: $model.operatingSystem,
                architecture: $model.architecture,
                error: model.platformError,
                accessibilityPrefix: "images.save"
            )
        }
        .formStyle(.grouped)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = [UTType.tarArchive]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.outputPath = url.path
        }
    }

    /// Named after the single selected image where there is one, so the common
    /// case does not need retyping.
    private var defaultFileName: String {
        guard model.orderedSelection.count == 1,
              let reference = model.orderedSelection.first else {
            return "images.tar"
        }
        let sanitized = reference
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(sanitized).tar"
    }
}

struct ImageLoadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImageLoadModel
    let onStart: (ImageLoadConfiguration) -> Void

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "images.load.preview",
            minHeight: 360
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Load archive")
                Form {
                    Section("Archive") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Path") {
                                HStack {
                                    TextField(
                                        text: $model.inputPath,
                                        prompt: Text(verbatim: "/Users/you/images.tar")
                                    ) {
                                        Text("Path")
                                    }
                                    .labelsHidden()
                                    .dsMonoField()
                                    .accessibilityIdentifier("images.load.path")

                                    Button("Choose…", action: chooseArchive)
                                        .accessibilityIdentifier("images.load.choose")
                                }
                            }
                            FieldError(message: model.inputError)
                        }
                    }

                    Section("Options") {
                        Toggle("Load archives with invalid member files", isOn: $model.force)
                            .accessibilityIdentifier("images.load.force")
                        Text(
                            "This accepts an archive whose members do not all validate. It does not bypass other import failures."
                        )
                        .font(.caption)
                        .foregroundStyle(Color.dsTextSecondary)
                    }
                }
                .formStyle(.grouped)
            }
            .background(Color.dsCanvas)
        } footer: {
            SheetCancelButton(accessibilityID: "images.load.cancel") { dismiss() }

            Spacer()

            Button("Load") {
                guard let configuration = model.configuration else { return }
                onStart(configuration)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canLoad)
            .accessibilityIdentifier("images.load.submit")
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.tarArchive]
        if panel.runModal() == .OK, let url = panel.url {
            model.inputPath = url.path
        }
    }
}
