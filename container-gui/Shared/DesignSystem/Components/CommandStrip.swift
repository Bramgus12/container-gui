import AppKit
import SwiftUI

struct CommandStrip: View {
    let command: String
    var showsCopyButton = true
    /// Named by the screen that owns it, so each strip is addressable.
    var accessibilityID = "command.strip"

    var body: some View {
        HStack(spacing: DSMetrics.spacing12) {
            Image(systemName: "terminal")
                .foregroundStyle(Color.dsTextTertiary)
            MonoText(value: command, dimmed: true, truncation: .middle)
            Spacer(minLength: DSMetrics.spacing8)
            if showsCopyButton {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .labelStyle(.iconOnly)
                    .help("Copy command")
            }
        }
        .padding(.horizontal, DSMetrics.spacing12)
        .frame(minHeight: 36)
        .background(Color.dsSurfaceRaised)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
        }
        .accessibilityIdentifier(accessibilityID)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
