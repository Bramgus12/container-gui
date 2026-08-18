import SwiftUI

#Preview("Design system · Light") {
    DesignSystemCatalog()
        .preferredColorScheme(.light)
}

#Preview("Design system · Dark") {
    DesignSystemCatalog()
        .preferredColorScheme(.dark)
}

private struct DesignSystemCatalog: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSMetrics.spacing16) {
                SectionLabel(title: "Components")
                DSCard {
                    VStack(alignment: .leading, spacing: DSMetrics.spacing12) {
                        StateDot(.running, label: "Running", accessibilityLabel: "Running")
                        HStack {
                            StateChip(title: "Running", state: .running)
                            StateChip(title: "Failed", state: .destructive)
                            TagChip(title: "Unused")
                        }
                        MonoText(value: "ghcr.io/example/container:latest")
                        UsageBar(value: 0.62)
                        MetricTile(value: "148", unit: "MB", caption: "Memory")
                        InlineBanner(
                            message: "Command failed",
                            detail: "container image pull example",
                            severity: .error
                        )
                        SidebarRow(icon: "shippingbox", title: "Containers", count: 7)
                        EmptyState(
                            "No Containers",
                            systemImage: "shippingbox",
                            description: "Containers you create will appear here."
                        )
                        .frame(height: 120)
                    }
                }
                CommandStrip(command: "container ls --all")
            }
            .padding(DSMetrics.spacing24)
        }
        .frame(width: 520, height: 520)
        .background(Color.dsCanvas)
    }
}
