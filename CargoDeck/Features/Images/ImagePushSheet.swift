import SwiftUI

enum ImagePushSection: String, SheetSection {
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

struct ImagePushSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImagePushModel
    /// `nil` when the app has no registry list to check against — the notice is
    /// then omitted rather than guessed at.
    let registryModel: RegistryModel?
    let onStart: (ImagePushConfiguration) -> Void
    @State private var page: ImagePushSection = .image

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "images.push.preview"
        ) {
            SheetSectionPane(
                title: "Push image",
                selection: $page,
                count: { $0 == .options ? model.optionCount : nil },
                accessibilityID: "images.push.rail"
            ) {
                switch page {
                case .image: imageSection
                case .options: optionsSection
                }
            }
        } footer: {
            SheetCancelButton(accessibilityID: "images.push.cancel") { dismiss() }

            Spacer()

            SheetPagingButtons(selection: $page, accessibilityIDPrefix: "images.push")

            Button("Push") {
                guard let configuration = model.configuration else { return }
                onStart(configuration)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPush)
            .accessibilityIdentifier("images.push.submit")
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        Section("Image") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Reference") {
                    TextField(
                        text: $model.reference,
                        prompt: Text(verbatim: "ghcr.io/example/app:1.0")
                    ) {
                        Text("Reference")
                    }
                    .labelsHidden()
                    .dsMonoField()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("images.push.reference")
                }
                FieldError(message: model.referenceError)
                Text("A push normally needs a registry-qualified tag, such as ghcr.io/owner/name:tag.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }

            // Informational only. Anonymous pushes to a public registry are a
            // legitimate case, so this never blocks the action.
            if let notice {
                InlineBanner(
                    message: notice.title,
                    detail: notice.detail,
                    scope: .card,
                    severity: .info
                )
                .accessibilityIdentifier("images.push.registryNotice")
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        ImageSchemeSection(
            scheme: $model.scheme,
            accessibilityID: "images.push.scheme"
        )

        ImagePlatformSection(
            platform: $model.platform,
            operatingSystem: $model.operatingSystem,
            architecture: $model.architecture,
            error: model.platformError,
            accessibilityPrefix: "images.push"
        )
    }

    private var notice: (title: LocalizedStringResource, detail: String)? {
        guard let registryModel, model.referenceError == nil else { return nil }
        guard let host = model.registryHost else {
            return (
                "No registry in this reference",
                String(localized: "Without a registry host the CLI uses its configured default registry.")
            )
        }
        // Matched on the host parsed from the trimmed reference, not on the raw
        // field, so surrounding whitespace cannot make a known registry look
        // unknown.
        guard !registryModel.isLoggedIn(host: host) else { return nil }
        return (
            "Not logged in to this registry",
            String(localized: "There is no stored login for \(host). An anonymous push works only if the registry allows it.")
        )
    }
}
