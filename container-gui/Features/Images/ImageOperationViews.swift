import AppKit
import SwiftUI

/// The one progress strip every streaming image operation uses, so pull, push,
/// save, load, delete and prune all report the same way and all cancel from the
/// same place.
struct ImageOperationProgressRow: View {
    let activity: ImageOperationActivity
    let cancel: () -> Void
    let dismiss: () -> Void
    @State private var showsTranscript = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DSMetrics.spacing12) {
                ProgressView(value: activity.isRunning ? activity.fraction : 1)
                    .frame(width: 100)
                VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                    MonoText(value: activity.invocation, truncation: .middle)
                    Text(statusText)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Spacer()
                Button(showsTranscript ? "Hide Output" : "Show Output") {
                    showsTranscript.toggle()
                }
                .accessibilityIdentifier("images.operation.output")

                if activity.isRunning {
                    Button("Cancel", role: .cancel, action: cancel)
                        .accessibilityIdentifier("images.operation.cancel")
                } else {
                    Button("Dismiss", systemImage: "xmark", action: dismiss)
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("images.operation.dismiss")
                }
            }
            .padding(.horizontal, DSMetrics.spacing12)
            .frame(minHeight: 48)

            if showsTranscript {
                ScrollView {
                    Text(activity.transcript)
                        .font(.cliMono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DSMetrics.spacing8)
                }
                .frame(maxHeight: 160)
                .background(Color.dsSurface)
                .accessibilityIdentifier("images.operation.transcript")
            }
        }
        .background(background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
        }
        .accessibilityIdentifier("images.operation")
    }

    private var statusText: String {
        switch activity.state {
        case .running: activity.label
        case .succeeded: String(localized: "Finished")
        case .cancelled: String(localized: "Cancelled — the result may be partly applied")
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch activity.state {
        case .running, .succeeded: .dsTextSecondary
        case .cancelled: .dsStateAttention
        case .failed: .dsStateDestructive
        }
    }

    private var background: Color {
        switch activity.state {
        case .running, .succeeded: .dsBlue100.opacity(0.35)
        case .cancelled: .dsStateAttention.opacity(0.12)
        case .failed: .dsStateDestructive.opacity(0.12)
        }
    }
}

/// The `--scheme` control, shared by pull and push.
struct ImageSchemeSection: View {
    @Binding var scheme: RegistryScheme
    let accessibilityID: String

    var body: some View {
        Section("Transport") {
            Picker("Scheme", selection: $scheme) {
                Text("Automatic").tag(RegistryScheme.auto)
                Text(verbatim: "HTTPS").tag(RegistryScheme.https)
                Text(verbatim: "HTTP").tag(RegistryScheme.http)
            }
            .accessibilityIdentifier(accessibilityID)

            if scheme.isUnencrypted {
                InlineBanner(
                    message: "HTTP is not encrypted",
                    detail: String(localized: "Image data and any credentials travel in the clear. Use HTTP only on a network you control."),
                    scope: .card,
                    severity: .attention
                )
            }
        }
    }
}

/// The `--platform` / `--os` / `--arch` trio, shared by pull, push and save.
struct ImagePlatformSection: View {
    @Binding var platform: String
    @Binding var operatingSystem: String
    @Binding var architecture: String
    let error: String?
    let accessibilityPrefix: String

    var body: some View {
        Section("Platform") {
            LabeledContent("Platform") {
                TextField(text: $platform, prompt: Text(verbatim: "linux/arm64")) {
                    Text("Platform")
                }
                .labelsHidden()
                .dsMonoField()
                .accessibilityIdentifier(accessibilityPrefix + ".platform")
            }
            LabeledContent("OS") {
                TextField(text: $operatingSystem, prompt: Text(verbatim: "linux")) {
                    Text("OS")
                }
                .labelsHidden()
                .dsMonoField()
                .disabled(!platform.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier(accessibilityPrefix + ".os")
            }
            LabeledContent("Architecture") {
                TextField(text: $architecture, prompt: Text(verbatim: "arm64")) {
                    Text("Architecture")
                }
                .labelsHidden()
                .dsMonoField()
                .disabled(!platform.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier(accessibilityPrefix + ".arch")
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.dsStateDestructive)
            }
            Text("Platform takes precedence: when it is set, OS and architecture are not sent.")
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
        }
    }
}

/// A validation message under a field, or nothing.
struct FieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.dsStateDestructive)
        }
    }
}

/// The checklist both the save and the bulk-delete sheets use to pick several
/// images without turning the main table into a multi-selection.
struct ImageChecklist: View {
    let images: [ImageSummary]
    let selection: Set<String>
    /// Rendered next to a row when it needs a caveat — a dependent-container
    /// count, for instance.
    var annotation: (ImageSummary) -> String?
    let toggle: (String) -> Void
    let accessibilityID: String

    var body: some View {
        List(images) { image in
            Button {
                toggle(image.reference)
            } label: {
                HStack(spacing: DSMetrics.spacing8) {
                    Image(
                        systemName: selection.contains(image.reference)
                            ? "checkmark.square.fill"
                            : "square"
                    )
                    .foregroundStyle(
                        selection.contains(image.reference)
                            ? Color.dsBlue400
                            : Color.dsTextSecondary
                    )
                    MonoText(value: image.reference, truncation: .middle, selectable: false)
                    Spacer(minLength: DSMetrics.spacing8)
                    if let annotation = annotation(image) {
                        Text(annotation)
                            .font(.caption)
                            .foregroundStyle(Color.dsStateAttention)
                    }
                    MonoText(
                        value: image.size.map {
                            ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: $0),
                                countStyle: .file
                            )
                        } ?? "—",
                        dimmed: true,
                        tabular: true,
                        selectable: false
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityID + ".row")
            .accessibilityAddTraits(selection.contains(image.reference) ? [.isSelected] : [])
        }
        .frame(minHeight: 180)
        .accessibilityIdentifier(accessibilityID)
    }
}
