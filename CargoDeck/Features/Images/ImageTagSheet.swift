import SwiftUI

struct ImageTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImageTagModel
    let appModel: AppModel

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "images.tag.preview",
            minHeight: 340
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Tag image")
                Form {
                    Section("Source") {
                        LabeledContent("Existing reference") {
                            MonoText(value: model.source, truncation: .middle)
                        }
                        Text("The existing reference stays. Tagging adds a second name for the same image.")
                            .font(.caption)
                            .foregroundStyle(Color.dsTextSecondary)
                    }

                    Section("New tag") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Target reference") {
                                TextField(
                                    text: $model.target,
                                    prompt: Text(verbatim: "ghcr.io/example/app:1.0")
                                ) {
                                    Text("Target reference")
                                }
                                .labelsHidden()
                                .dsMonoField()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("images.tag.target")
                            }
                            FieldError(message: model.targetError)
                            Text("To push to a registry, tag the image with that registry's host first.")
                                .font(.caption)
                                .foregroundStyle(Color.dsTextSecondary)
                        }

                        if let error = model.errorMessage {
                            InlineBanner(
                                message: "Tag failed",
                                detail: error,
                                scope: .card,
                                severity: .error,
                                copyValue: error
                            )
                            .accessibilityIdentifier("images.tag.error")
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .background(Color.dsCanvas)
        } footer: {
            SheetCancelButton(accessibilityID: "images.tag.cancel") { dismiss() }
                .disabled(model.isTagging)

            Spacer()

            Button {
                Task {
                    if await model.tag(using: appModel) { dismiss() }
                }
            } label: {
                if model.isTagging {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Tag")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canTag)
            .accessibilityIdentifier("images.tag.submit")
        }
        .interactiveDismissDisabled(model.isTagging)
    }
}
