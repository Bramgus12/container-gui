import SwiftUI

struct ImagePruneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImagePruneModel
    let images: [ImageSummary]
    let inventoryIndex: InventoryIndex
    let onStart: (Bool) -> Void

    var body: some View {
        SheetScaffold(
            command: model.commandPreview,
            commandAccessibilityID: "images.prune.preview",
            minHeight: 380
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(
                    title: "Prune images",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .dsStateDestructive
                )

                VStack(alignment: .leading, spacing: DSMetrics.spacing16) {
                    Picker("Scope", selection: $model.scope) {
                        Text("Dangling images only").tag(ImagePruneModel.Scope.dangling)
                        Text("All images no container uses").tag(ImagePruneModel.Scope.all)
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("images.prune.scope")

                    Text(explanation)
                        .foregroundStyle(Color.dsTextSecondary)

                    let estimate = model.estimate(images: images, index: inventoryIndex)
                    InlineBanner(
                        message: "Estimated effect",
                        detail: estimateDetail(estimate),
                        scope: .card,
                        severity: .attention
                    )
                    .accessibilityIdentifier("images.prune.estimate")

                    Spacer(minLength: 0)
                }
                .padding(DSMetrics.spacing16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color.dsCanvas)
        } footer: {
            SheetCancelButton(accessibilityID: "images.prune.cancel") { dismiss() }

            Spacer()

            Button(role: .destructive) {
                onStart(model.configurationIsAll)
                dismiss()
            } label: {
                Text("Prune")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("images.prune.confirm")
        }
    }

    private var explanation: LocalizedStringResource {
        switch model.scope {
        case .dangling:
            "Removes images that no longer have a usable name — typically layers left behind by a rebuild. Tagged images are kept."
        case .all:
            "Removes every image that no container references, including tagged ones you may want to keep. Pulling them again needs network access."
        }
    }

    /// Labelled an estimate on purpose: the CLI decides reachability, and this
    /// count is only what the GUI can see from the image and container lists.
    private func estimateDetail(_ estimate: ImagePruneEstimate) -> String {
        guard estimate.count > 0 else {
            return String(
                localized: "This app sees nothing to remove, but the CLI decides what is unused and may still free space."
            )
        }
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: estimate.bytes),
            countStyle: .file
        )
        return String(
            localized: "About \(estimate.count) image(s) and \(bytes). The CLI decides what is actually unused, so the result may differ."
        )
    }
}
