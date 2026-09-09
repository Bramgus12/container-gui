import SwiftUI

/// The chrome every sheet shares, so all modals read the same way: a content
/// pane that fills the sheet, the command the sheet will run, and a footer whose
/// leading edge cancels and whose trailing edge steps through pages and submits.
///
/// Do not attach an `accessibilityIdentifier` to a sheet built from this: an
/// identifier on the root replaces the identifier of every control inside it,
/// which leaves the footer's buttons unaddressable. Name the controls instead.
struct SheetScaffold<Content: View, Footer: View>: View {
    /// The command preview shown above the footer. Sheets that do not run a
    /// command leave this empty and get a plain separator in its place.
    var command: String?
    var commandAccessibilityID = "command.strip"
    /// Configuration sheets all open at the same size; message sheets pass a
    /// smaller one so a single sentence does not sit in an empty window.
    var minWidth = DSMetrics.sheetWidth
    var minHeight = DSMetrics.sheetHeight
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let command {
                CommandStrip(command: command, accessibilityID: commandAccessibilityID)
            } else {
                Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
            }

            HStack(spacing: DSMetrics.spacing8) {
                footer()
            }
            .padding()
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
    }
}

/// The body of a paged sheet: the page rail on the leading edge and the selected
/// page filling the rest of the sheet.
struct SheetRailPane<Section: SheetSection, Content: View>: View {
    let title: LocalizedStringResource
    @Binding var selection: Section
    /// The badge for each page, or `nil` for pages with nothing countable.
    var count: (Section) -> Int? = { _ in nil }
    let accessibilityID: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            SheetSectionRail(
                title: title,
                selection: $selection,
                count: count,
                accessibilityID: accessibilityID
            )
            Rectangle().fill(Color.dsHairline).frame(width: DSMetrics.hairline)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The body of a configuration sheet: the page rail beside the grouped form that
/// holds the selected page's sections.
struct SheetSectionPane<Section: SheetSection, Content: View>: View {
    let title: LocalizedStringResource
    @Binding var selection: Section
    /// The badge for each page, or `nil` for pages with nothing countable.
    var count: (Section) -> Int? = { _ in nil }
    let accessibilityID: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        SheetRailPane(
            title: title,
            selection: $selection,
            count: count,
            accessibilityID: accessibilityID
        ) {
            Form {
                content()
            }
            .formStyle(.grouped)
        }
    }
}

/// The title row for sheets that have no page rail, so their title lands where
/// the rail's title would.
struct SheetHeader<Accessory: View>: View {
    let title: LocalizedStringResource
    /// Message sheets lead with a tinted symbol that names the outcome.
    var systemImage: String?
    var tint = Color.dsTextPrimary
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSMetrics.spacing8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.dsScreenTitle)
                .foregroundStyle(tint)
            Spacer(minLength: DSMetrics.spacing8)
            accessory()
        }
        .padding(DSMetrics.spacing16)
        .background(Color.dsSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
        }
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(title: LocalizedStringResource, systemImage: String? = nil, tint: Color = .dsTextPrimary) {
        self.init(title: title, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// The footer's cancel button, so every sheet dismisses from the same place with
/// the same keyboard shortcut.
struct SheetCancelButton: View {
    var title: LocalizedStringResource = "Cancel"
    var accessibilityID: String?
    let action: () -> Void

    var body: some View {
        Button(role: .cancel, action: action) {
            Text(title)
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(accessibilityID ?? "sheet.cancel")
    }
}

/// Back and Next for the sheets whose form is split across rail pages.
struct SheetPagingButtons<Section: SheetSection>: View {
    @Binding var selection: Section
    var isDisabled = false
    let accessibilityIDPrefix: String

    var body: some View {
        Button("Back") { selection = selection.previous ?? selection }
            .disabled(selection.previous == nil || isDisabled)
            .accessibilityIdentifier(accessibilityIDPrefix + ".back")

        Button("Next") { selection = selection.next ?? selection }
            .disabled(selection.next == nil || isDisabled)
            .accessibilityIdentifier(accessibilityIDPrefix + ".next")
    }
}
