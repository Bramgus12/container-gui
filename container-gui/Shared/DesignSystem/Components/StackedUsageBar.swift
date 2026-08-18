import SwiftUI

/// One proportional bar split into named segments, plus the legend that names
/// them. Used by the sidebar disk block and the System disk card so both read
/// the same total the same way.
struct StackedUsageBar: View {
    struct Segment: Identifiable, Equatable {
        let id: String
        let title: LocalizedStringResource
        let bytes: UInt64
        let color: Color

        init(id: String, title: LocalizedStringResource, bytes: UInt64, color: Color) {
            self.id = id
            self.title = title
            self.bytes = bytes
            self.color = color
        }

        static func == (lhs: Segment, rhs: Segment) -> Bool {
            lhs.id == rhs.id && lhs.bytes == rhs.bytes
        }
    }

    let segments: [Segment]
    var height: CGFloat = 6

    private var total: UInt64 {
        segments.reduce(0) { $0 &+ $1.bytes }
    }

    var body: some View {
        GeometryReader { proxy in
            let drawn = segments.filter { $0.bytes > 0 }
            let spacing = CGFloat(max(0, drawn.count - 1))
            let availableWidth = max(0, proxy.size.width - spacing)
            HStack(spacing: 1) {
                if drawn.isEmpty {
                    Rectangle().fill(Color.dsHairline)
                } else {
                    ForEach(drawn) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: availableWidth * fraction(of: segment))
                    }
                }
            }
            .clipShape(Capsule())
            .background(Color.dsHairline, in: Capsule())
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Disk usage")
        .accessibilityValue(accessibilityValue)
    }

    private func fraction(of segment: Segment) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(Double(segment.bytes) / Double(total))
    }

    private var accessibilityValue: Text {
        let described = segments
            .filter { $0.bytes > 0 }
            .map { "\(String(localized: $0.title)) \(Self.format($0.bytes))" }
            .joined(separator: ", ")
        return Text(verbatim: described)
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

/// The legend beneath a `StackedUsageBar`: a swatch, the segment name, and the
/// figure it stands for.
struct StackedUsageLegend: View {
    let segments: [StackedUsageBar.Segment]

    var body: some View {
        ForEach(segments.filter { $0.bytes > 0 }) { segment in
            HStack(spacing: DSMetrics.spacing8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(segment.color)
                    .frame(width: 8, height: 8)
                Text(segment.title)
                Spacer()
                Text(StackedUsageBar.format(segment.bytes))
                    .font(.cliMonoTabular)
                    .monospacedDigit()
            }
            .foregroundStyle(Color.dsTextSecondary)
        }
    }
}

extension SystemDiskUsage {
    /// The disk figures split the way both the sidebar and the System card show
    /// them: what each resource holds, then everything reclaimable in amber.
    var usageSegments: [StackedUsageBar.Segment] {
        let images = resource(named: "image")
        let volumes = resource(named: "volume")
        let containers = resource(named: "container")

        let imageSize = images?.sizeBytes ?? 0
        let volumeSize = volumes?.sizeBytes ?? 0
        let containerSize = containers?.sizeBytes ?? 0

        let reclaimable = min(totalSizeBytes, totalReclaimableBytes)
        let known = min(totalSizeBytes, imageSize &+ volumeSize &+ containerSize)
        let other = totalSizeBytes - known

        // Reclaimable bytes are already counted inside each resource's size, so
        // they are subtracted out before being shown as their own segment.
        let imageReclaimable = min(imageSize, images?.reclaimableBytes ?? 0)
        let volumeReclaimable = min(volumeSize, volumes?.reclaimableBytes ?? 0)
        let containerReclaimable = min(containerSize, containers?.reclaimableBytes ?? 0)
        let knownReclaimable = min(
            reclaimable,
            imageReclaimable &+ volumeReclaimable &+ containerReclaimable
        )
        let otherReclaimable = min(other, reclaimable - knownReclaimable)

        return [
            .init(
                id: "images",
                title: "Images",
                bytes: imageSize - imageReclaimable,
                color: .dsBlue400
            ),
            .init(
                id: "containers",
                title: "Containers",
                bytes: containerSize - containerReclaimable,
                color: .dsBlue300
            ),
            .init(
                id: "volumes",
                title: "Volumes",
                bytes: volumeSize - volumeReclaimable,
                color: .dsBlue200
            ),
            .init(
                id: "other",
                title: "Other",
                bytes: other - otherReclaimable,
                color: .dsBlue100
            ),
            .init(
                id: "reclaimable",
                title: "Reclaimable",
                bytes: reclaimable,
                color: .dsStateAttention
            ),
        ]
    }
}
