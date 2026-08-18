import SwiftUI

struct MonoText: View {
    enum Truncation {
        case head
        case middle
        case tail

        var mode: Text.TruncationMode {
            switch self {
            case .head: .head
            case .middle: .middle
            case .tail: .tail
            }
        }
    }

    let value: String
    var dimmed = false
    var truncation: Truncation = .tail
    var tabular = false
    var selectable = true

    @ViewBuilder
    var body: some View {
        let text = Text(value)
            .font(tabular ? .cliMonoTabular : (dimmed ? .cliMonoDim : .cliMono))
            .monospacedDigit()
            // Semantic rather than the raw tokens: inside a selected table row
            // AppKit inverts these, and a hardcoded colour would stay dark on
            // the selection fill.
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(truncation.mode)
        if selectable {
            text.textSelection(.enabled)
        } else {
            text
        }
    }
}
