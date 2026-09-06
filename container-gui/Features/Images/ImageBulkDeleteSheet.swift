import SwiftUI

/// Two-step by construction: the form picks a scope, Review re-reads images and
/// containers, and only a scope that survived that recheck can be confirmed.
/// Anything that changes the form throws the confirmation away again.
struct ImageBulkDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ImageBulkDeleteModel
    @Bindable var appModel: AppModel
    let onStart: (ImageDeleteConfiguration) -> Void

    var body: some View {
        SheetScaffold(
            command: model.commandPreview(from: appModel.images),
            commandAccessibilityID: "images.bulkDelete.preview"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(
                    title: "Delete images",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .dsStateDestructive
                )
                content
            }
            .background(Color.dsCanvas)
        } footer: {
            SheetCancelButton(accessibilityID: "images.bulkDelete.cancel") { dismiss() }
                .disabled(model.isPreparing)

            Spacer()

            Button {
                Task { await model.prepareConfirmation(using: appModel) }
            } label: {
                if model.isPreparing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Review…")
                }
            }
            .disabled(!model.hasSelection || model.isPreparing)
            .accessibilityIdentifier("images.bulkDelete.review")

            Button(role: .destructive) {
                guard model.confirmedScope != nil,
                      let configuration = model.configuration(from: appModel.images) else { return }
                onStart(configuration)
                dismiss()
            } label: {
                Text(confirmTitle)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.confirmedScope == nil || model.isPreparing)
            .accessibilityIdentifier("images.bulkDelete.confirm")
        }
        .interactiveDismissDisabled(model.isPreparing)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing12) {
            Picker("Scope", selection: Binding(
                get: { model.mode },
                set: { model.setMode($0) }
            )) {
                Text("Selected images").tag(ImageBulkDeleteModel.Mode.named)
                Text("All images").tag(ImageBulkDeleteModel.Mode.all)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DSMetrics.spacing16)
            .padding(.top, DSMetrics.spacing12)
            .accessibilityIdentifier("images.bulkDelete.mode")

            if model.mode == .named {
                ImageChecklist(
                    images: appModel.images,
                    selection: model.selectedReferences,
                    annotation: { image in
                        let count = appModel.inventoryIndex.containers(using: image).count
                        return count == 0 ? nil : String(localized: "\(count) container(s)")
                    },
                    toggle: model.toggle,
                    accessibilityID: "images.bulkDelete.checklist"
                )
            } else {
                InlineBanner(
                    message: "Every image will be deleted",
                    detail: String(localized: "This runs container image delete --all against all \(appModel.images.count) local images. Images a container still uses are preserved by the CLI."),
                    scope: .card,
                    severity: .attention
                )
                .padding(.horizontal, DSMetrics.spacing16)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
                Toggle("Ignore targets that are already missing", isOn: Binding(
                    get: { model.ignoreMissing },
                    set: { model.setIgnoreMissing($0) }
                ))
                .accessibilityIdentifier("images.bulkDelete.ignoreMissing")

                Text(
                    "This is the CLI's --force flag, and it only suppresses not-found errors. It never removes an image a container is using."
                )
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)

                if let message = model.staleScopeMessage {
                    InlineBanner(
                        message: "Review again",
                        detail: message,
                        scope: .card,
                        severity: .attention
                    )
                    .accessibilityIdentifier("images.bulkDelete.stale")
                }

                if let scope = model.confirmedScope {
                    confirmationSummary(scope)
                }
            }
            .padding(.horizontal, DSMetrics.spacing16)
            .padding(.bottom, DSMetrics.spacing16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func confirmationSummary(_ scope: ImageBulkDeleteScope) -> some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
            InlineBanner(
                message: "Ready to delete",
                detail: String(localized: "\(scope.references.count) image(s), \(Self.formatBytes(scope.totalBytes)). This cannot be undone."),
                scope: .card,
                severity: .error
            )
            .accessibilityIdentifier("images.bulkDelete.summary")

            if !scope.blockedReferences.isEmpty {
                InlineBanner(
                    message: "Some images are still in use",
                    detail: String(localized: "\(scope.blockedReferences.count) of them are used by a container and will be preserved by the CLI: \(scope.blockedReferences.prefix(3).joined(separator: ", ")). Delete those containers first, or use the single-image delete, which offers to remove them for you."),
                    scope: .card,
                    severity: .attention
                )
                .accessibilityIdentifier("images.bulkDelete.blocked")
            }
        }
    }

    private var confirmTitle: LocalizedStringResource {
        model.mode == .all ? "Delete All Images" : "Delete Images"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
