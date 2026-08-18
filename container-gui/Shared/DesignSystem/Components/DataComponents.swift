import SwiftUI

struct MetricTile: View {
    let value: String
    let unit: String?
    let caption: LocalizedStringResource

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
            HStack(alignment: .firstTextBaseline, spacing: DSMetrics.spacing4) {
                Text(value)
                    .font(DSFont.mono(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.dsTextPrimary)
                    .textSelection(.enabled)
                if let unit {
                    Text(unit)
                        .font(DSFont.mono(size: 12.5))
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            Text(caption)
                .font(.dsSectionLabel)
                .foregroundStyle(Color.dsTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSMetrics.spacing12)
        .background(Color.dsSurfaceRaised, in: RoundedRectangle(cornerRadius: DSMetrics.inlineRadius))
    }
}

struct UsageBar: View {
    let value: Double
    var tint: Color = .dsBlue400

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dsHairline)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 5)
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}
