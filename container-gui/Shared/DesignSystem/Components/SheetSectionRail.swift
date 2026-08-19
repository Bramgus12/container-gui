import SwiftUI

/// One page of a multi-section sheet, listed by ``SheetSectionRail``.
///
/// Conformers are plain enumerations, so `next` and `previous` fall out of the
/// case order and drive the sheet's Back and Next buttons.
protocol SheetSection: Hashable, CaseIterable where AllCases == [Self] {
    var title: LocalizedStringResource { get }
    /// Pages that must be filled in before the sheet can submit are marked with
    /// an asterisk in the rail.
    var isRequired: Bool { get }
}

extension SheetSection {
    var isRequired: Bool { false }

    var next: Self? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    var previous: Self? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }
}

/// The narrow page list on the leading edge of a sheet, paired with a single
/// full-width form pane. Shared by the run-container and build-image sheets so
/// both read the same way.
struct SheetSectionRail<Section: SheetSection>: View {
    let title: LocalizedStringResource
    @Binding var selection: Section
    /// The badge for each page, or `nil` for pages with nothing countable.
    let count: (Section) -> Int?
    let accessibilityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
            SectionLabel(title: title)
                .padding(.bottom, DSMetrics.spacing8)
            ForEach(Section.allCases, id: \.self) { section in
                SheetSectionRailRow(
                    title: section.title,
                    count: count(section),
                    isRequired: section.isRequired,
                    isSelected: selection == section
                ) {
                    selection = section
                }
            }
            Spacer()
        }
        .padding(DSMetrics.spacing12)
        .frame(width: 150)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dsSurfaceRaised)
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct SheetSectionRailRow: View {
    let title: LocalizedStringResource
    let count: Int?
    let isRequired: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: DSMetrics.spacing4) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                if isRequired {
                    Text(verbatim: "*")
                        .foregroundStyle(Color.dsStateAttention)
                        .accessibilityLabel("Required")
                }
                Spacer()
                if let count, count > 0 {
                    Text(count, format: .number)
                        .font(.cliMonoTabular)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .padding(.vertical, DSMetrics.spacing8)
            .padding(.horizontal, DSMetrics.spacing8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.dsBlue100 : .clear,
            in: RoundedRectangle(cornerRadius: DSMetrics.controlRadius)
        )
    }
}
