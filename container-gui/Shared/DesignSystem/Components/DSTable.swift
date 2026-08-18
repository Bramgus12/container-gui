import SwiftUI

/// One column's identity, width, alignment and — when it can be sorted — the
/// order it sorts its rows into. The header and every row read from the same
/// specs, which is what keeps them aligned.
struct DSTableColumn<Row>: Identifiable {
    let id: String
    let title: LocalizedStringResource
    /// A fixed width, or `nil` to share the remaining space with the other
    /// flexible columns.
    let width: CGFloat?
    let alignment: Alignment
    /// Ascending comparator. A column without one cannot be sorted by.
    let ascending: ((Row, Row) -> Bool)?

    init(
        _ id: String,
        _ title: LocalizedStringResource,
        width: CGFloat? = nil,
        alignment: Alignment = .leading,
        ascending: ((Row, Row) -> Bool)? = nil
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.alignment = alignment
        self.ascending = ascending
    }
}

/// The table the mockups draw: uppercase column labels over flat rows separated
/// by a single hairline, with no vertical dividers and no zebra striping, and a
/// selected row marked by a tinted fill and an accent rail rather than the
/// system's filled highlight.
///
/// This is deliberately not SwiftUI's `Table`, which draws column dividers that
/// cannot be turned off and owns its selection appearance. Click-to-sort is
/// rebuilt here. Interactive column resizing is not: a drag handle for it could
/// not be made to receive a click or a drag under test, so it was withdrawn
/// rather than shipped unverified. Column widths are whatever each screen's
/// specs say.
///
/// Every width is derived from a single measurement of the table's own width,
/// and nothing here measures its own children. The withdrawn resize version did
/// measure each header cell and feed the result back into state, which re-laid
/// out the header and re-measured it — dragging a column drove that cycle until
/// AppKit killed the process for exceeding its update-constraints budget.
struct DSTable<Row: Identifiable, RowContent: View>: View {
    let rows: [Row]
    let columns: [DSTableColumn<Row>]
    @Binding var selection: Row.ID?
    @ViewBuilder let content: (Row) -> RowContent

    @State private var sortColumnID: String?
    @State private var sortAscending = true

    private static var minimumColumnWidth: CGFloat { 56 }

    private var sortedRows: [Row] {
        guard
            let sortColumnID,
            let ascending = columns.first(where: { $0.id == sortColumnID })?.ascending
        else { return rows }
        return rows.sorted { sortAscending ? ascending($0, $1) : ascending($1, $0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let widths = resolvedWidths(inTableWidth: proxy.size.width)
            VStack(spacing: 0) {
                header(widths)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedRows) { row in
                            DSTableRow(isSelected: selection == row.id) {
                                content(row)
                            }
                            .onTapGesture { selection = row.id }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .environment(\.dsColumnWidths, widths)
        }
        .background(Color.dsSurface)
    }

    /// Fixed columns keep their width; whatever is left is split between the
    /// flexible ones.
    private func resolvedWidths(inTableWidth total: CGFloat) -> [String: CGFloat] {
        let gutters = DSMetrics.spacing12 * CGFloat(max(0, columns.count - 1))
        let padding = DSMetrics.spacing12 * 2

        var widths: [String: CGFloat] = [:]
        var claimed: CGFloat = 0
        var flexible: [String] = []

        for column in columns {
            if let width = column.width {
                widths[column.id] = width
                claimed += width
            } else {
                flexible.append(column.id)
            }
        }

        guard !flexible.isEmpty else { return widths }
        let remaining = max(0, total - padding - gutters - claimed)
        let each = max(Self.minimumColumnWidth, remaining / CGFloat(flexible.count))
        for id in flexible {
            widths[id] = each
        }
        return widths
    }

    private func header(_ widths: [String: CGFloat]) -> some View {
        HStack(spacing: DSMetrics.spacing12) {
            ForEach(columns) { column in
                headerCell(for: column)
                    .frame(width: widths[column.id], alignment: column.alignment)
            }
        }
        .font(.dsSectionLabel)
        .tracking(0.8)
        .textCase(.uppercase)
        .foregroundStyle(Color.dsTextSecondary)
        .padding(.horizontal, DSMetrics.spacing12)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
        }
    }

    @ViewBuilder
    private func headerCell(for column: DSTableColumn<Row>) -> some View {
        let isSorted = sortColumnID == column.id
        let label = HStack(spacing: DSMetrics.spacing4) {
            if column.alignment == .trailing { Spacer(minLength: 0) }
            Text(column.title)
                .lineLimit(1)
            if isSorted {
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            if column.alignment != .trailing { Spacer(minLength: 0) }
        }
        .contentShape(Rectangle())

        if column.ascending != nil {
            Button {
                if isSorted {
                    sortAscending.toggle()
                } else {
                    sortColumnID = column.id
                    sortAscending = true
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSorted ? Color.dsTextPrimary : Color.dsTextSecondary)
            .help("Sort by \(String(localized: column.title))")
        } else {
            label
        }
    }
}

private struct DSColumnWidthsEnvironmentKey: EnvironmentKey {
    static let defaultValue: [String: CGFloat] = [:]
}

extension EnvironmentValues {
    /// Resolved column widths, read by row cells so they track the header.
    var dsColumnWidths: [String: CGFloat] {
        get { self[DSColumnWidthsEnvironmentKey.self] }
        set { self[DSColumnWidthsEnvironmentKey.self] = newValue }
    }
}

private struct DSColumnLayout: ViewModifier {
    let id: String
    let alignment: Alignment
    @Environment(\.dsColumnWidths) private var widths

    func body(content: Content) -> some View {
        content.frame(width: widths[id], alignment: alignment)
    }
}

extension View {
    /// Sizes a cell to its column, so it lines up with the header.
    func dsColumn<Row>(_ column: DSTableColumn<Row>) -> some View {
        modifier(DSColumnLayout(id: column.id, alignment: column.alignment))
    }
}

struct DSTableRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: DSMetrics.spacing12) {
            content
        }
        .padding(.horizontal, DSMetrics.spacing12)
        .frame(minHeight: DSMetrics.tableRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                Color.dsBlue100
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color.dsBlue400)
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
        }
        .contentShape(Rectangle())
    }
}
