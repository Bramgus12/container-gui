import SwiftUI

/// One column's identity, width and alignment. The header and every row read
/// from the same specs, which is what keeps them aligned.
struct DSTableColumn: Identifiable, Equatable {
    let id: String
    let title: LocalizedStringResource
    /// `nil` takes the remaining width, shared with the other flexible columns.
    let width: CGFloat?
    let alignment: Alignment

    init(
        _ id: String,
        _ title: LocalizedStringResource,
        width: CGFloat? = nil,
        alignment: Alignment = .leading
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

extension View {
    /// Sizes a cell to its column. Applied to both the header title and the row
    /// cell so the two line up.
    func dsColumn(_ column: DSTableColumn) -> some View {
        Group {
            if let width = column.width {
                frame(width: width, alignment: column.alignment)
            } else {
                frame(maxWidth: .infinity, alignment: column.alignment)
            }
        }
    }
}

/// The table the mockups draw: uppercase column labels over flat rows separated
/// by a single hairline, with no vertical dividers and no zebra striping, and a
/// selected row marked by a tinted fill and an accent rail rather than the
/// system's filled highlight.
///
/// This is deliberately not SwiftUI's `Table`, which draws column dividers that
/// cannot be turned off and owns its selection appearance. The trade is column
/// resizing and click-to-sort, neither of which these screens offered.
struct DSTable<Row: Identifiable, RowContent: View>: View {
    let rows: [Row]
    let columns: [DSTableColumn]
    @Binding var selection: Row.ID?
    @ViewBuilder let content: (Row) -> RowContent

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        DSTableRow(isSelected: selection == row.id) {
                            content(row)
                        }
                        .onTapGesture { selection = row.id }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color.dsSurface)
    }

    private var header: some View {
        HStack(spacing: DSMetrics.spacing12) {
            ForEach(columns) { column in
                Text(column.title)
                    .dsColumn(column)
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
