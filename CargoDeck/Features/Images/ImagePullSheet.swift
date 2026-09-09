import SwiftUI

enum ImagePullSection: String, SheetSection {
    case image
    case options

    var isRequired: Bool { self == .image }

    var title: LocalizedStringResource {
        switch self {
        case .image: "Image"
        case .options: "Options"
        }
    }
}

struct ImagePullSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImagePullModel
    /// The sheet dismisses as the pull starts; the progress lives on the Images
    /// screen so it survives navigating away.
    let onStart: (ImagePullConfiguration) -> Void
    @State private var page: ImagePullSection = .image

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "images.pull.preview"
        ) {
            SheetSectionPane(
                title: "Pull image",
                selection: $page,
                count: { $0 == .options ? model.optionCount : nil },
                accessibilityID: "images.pull.rail"
            ) {
                switch page {
                case .image: imageSection
                case .options: optionsSection
                }
            }
        } footer: {
            SheetCancelButton(accessibilityID: "images.pull.cancel") { dismiss() }

            Spacer()

            SheetPagingButtons(selection: $page, accessibilityIDPrefix: "images.pull")

            Button("Pull") {
                guard let configuration = model.configuration else { return }
                onStart(configuration)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPull)
            .accessibilityIdentifier("images.pull.submit")
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        Section("Image") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Reference") {
                    TextField(text: $model.reference, prompt: Text(verbatim: "alpine:3.21")) {
                        Text("Reference")
                    }
                    .labelsHidden()
                    .dsMonoField()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("images.pull.reference")
                }
                FieldError(message: model.referenceError)
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        ImageSchemeSection(
            scheme: $model.scheme,
            accessibilityID: "images.pull.scheme"
        )

        ImagePlatformSection(
            platform: $model.platform,
            operatingSystem: $model.operatingSystem,
            architecture: $model.architecture,
            error: model.platformError,
            accessibilityPrefix: "images.pull"
        )

        // Absent below 1.0.0 rather than disabled: the flag does not exist
        // there, so offering it would only invite a failure.
        if model.capabilities.supportsConcurrentDownloadLimit {
            Section("Downloads") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Maximum concurrent downloads") {
                        TextField(
                            text: $model.maximumConcurrentDownloads,
                            prompt: Text(verbatim: "3")
                        ) {
                            Text("Maximum concurrent downloads")
                        }
                        .labelsHidden()
                        .dsMonoField()
                        .frame(maxWidth: 90)
                        .accessibilityIdentifier("images.pull.concurrency")
                    }
                    FieldError(message: model.concurrencyError)
                    Text("Leave empty to use the CLI's own default.")
                        .font(.caption)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
        }
    }
}
