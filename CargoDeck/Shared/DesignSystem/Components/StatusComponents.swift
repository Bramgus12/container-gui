import SwiftUI

enum DSState: Equatable, Sendable {
    case running
    case attention
    case idle
    case destructive

    var color: Color {
        switch self {
        case .running: .dsStateRunning
        case .attention: .dsStateAttention
        case .idle: .dsStateIdle
        case .destructive: .dsStateDestructive
        }
    }
}

struct StateDot: View {
    let state: DSState
    let label: LocalizedStringResource?
    let accessibilityLabel: LocalizedStringResource

    init(
        _ state: DSState,
        label: LocalizedStringResource? = nil,
        accessibilityLabel: LocalizedStringResource
    ) {
        self.state = state
        self.label = label
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        HStack(spacing: DSMetrics.spacing8) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
            if let label {
                Text(label)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct StateChip: View {
    let title: LocalizedStringResource
    let state: DSState

    var body: some View {
        Text(title)
            .font(.dsSectionLabel)
            .textCase(.uppercase)
            .foregroundStyle(state.color)
            .padding(.horizontal, DSMetrics.spacing8)
            .padding(.vertical, DSMetrics.spacing4)
            .background(state.color.opacity(0.12), in: RoundedRectangle(cornerRadius: DSMetrics.controlRadius))
            .accessibilityLabel(title)
    }
}

struct TagChip: View {
    let title: LocalizedStringResource

    var body: some View {
        Text(title)
            .font(.dsSectionLabel)
            .textCase(.uppercase)
            .foregroundStyle(Color.dsTextSecondary)
            .padding(.horizontal, DSMetrics.spacing8)
            .padding(.vertical, DSMetrics.spacing4)
            .background(Color.dsSurfaceRaised, in: RoundedRectangle(cornerRadius: DSMetrics.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DSMetrics.controlRadius)
                    .stroke(Color.dsHairline)
            }
    }
}

#Preview("Status components") {
    HStack {
        StateDot(.running, label: "Running", accessibilityLabel: "Running")
        StateChip(title: "Paused", state: .attention)
        TagChip(title: "Unused")
    }
    .padding()
}
