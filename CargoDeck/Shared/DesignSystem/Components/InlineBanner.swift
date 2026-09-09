import AppKit
import SwiftUI

struct InlineBanner: View {
    enum Scope {
        case row
        case card
        case bar

        var padding: CGFloat {
            switch self {
            case .row: DSMetrics.spacing8
            case .card, .bar: DSMetrics.spacing12
            }
        }
    }

    enum Severity {
        case error
        case attention
        case info

        var color: Color {
            switch self {
            case .error: .dsStateDestructive
            case .attention: .dsStateAttention
            case .info: .dsBlue400
            }
        }

        var icon: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .attention: "exclamationmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    let message: LocalizedStringResource
    var detail: String?
    var scope: Scope = .bar
    var severity: Severity = .error
    var copyValue: String?
    /// Trailing button — "Try Again", "Start", "Prune…". Titled rather than
    /// icon-only, because it is the banner's way out.
    var actionTitle: LocalizedStringResource?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: DSMetrics.spacing12) {
            Image(systemName: severity.icon).foregroundStyle(severity.color)
            VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                Text(message).fontWeight(.semibold)
                if let detail {
                    MonoText(value: detail, dimmed: true, truncation: .middle)
                }
            }
            Spacer(minLength: DSMetrics.spacing8)
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle) }
            }
            if let copyValue {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                }
                .labelStyle(.iconOnly)
            }
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
            }
        }
        .padding(scope.padding)
        .background(severity.color.opacity(0.08), in: RoundedRectangle(cornerRadius: DSMetrics.inlineRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DSMetrics.inlineRadius)
                .stroke(severity.color.opacity(0.24))
        }
    }
}
