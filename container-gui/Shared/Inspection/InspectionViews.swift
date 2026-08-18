import AppKit
import SwiftUI

struct InspectionSection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let content: Content

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSMetrics.spacing12) {
                SectionLabel(title, systemImage: systemImage)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A label/value pair. The value is always something the CLI emitted, so it is
/// always mono; the label is ours, so it never is.
struct InspectionValueRow: View {
    private let label: Text
    let value: String

    init(_ label: LocalizedStringKey, value: String?) {
        self.label = Text(label)
        self.value = value?.isEmpty == false ? value! : "—"
    }

    /// For labels that come from the inspected resource itself — annotation and
    /// label dictionary keys — which must not be looked up in the string catalog.
    init(rawLabel: String, value: String?) {
        label = Text(verbatim: rawLabel)
        self.value = value?.isEmpty == false ? value! : "—"
    }

    var body: some View {
        LabeledContent {
            MonoText(value: value, truncation: .middle)
        } label: {
            label
        }
    }
}

struct InspectionBooleanRow: View {
    let label: LocalizedStringKey
    let value: Bool

    var body: some View {
        LabeledContent(label) {
            Label(value ? "Enabled" : "Disabled", systemImage: value ? "checkmark.circle" : "minus.circle")
                .foregroundStyle(value ? Color.dsStateRunning : Color.dsTextSecondary)
        }
    }
}

struct InspectionTokenList: View {
    private let tokens: [InspectionToken]
    let emptyText: LocalizedStringKey

    init(_ values: [String], emptyText: LocalizedStringKey = "None") {
        var occurrences: [String: Int] = [:]
        tokens = values.map { value in
            let occurrence = occurrences[value, default: 0]
            occurrences[value] = occurrence + 1
            return InspectionToken(id: "\(value)-\(occurrence)", value: value)
        }
        self.emptyText = emptyText
    }

    var body: some View {
        if tokens.isEmpty {
            Text(emptyText)
                .foregroundStyle(Color.dsTextSecondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                ForEach(tokens) { token in
                    MonoText(value: token.value, truncation: .middle)
                        .padding(.horizontal, DSMetrics.spacing8)
                        .padding(.vertical, DSMetrics.spacing4)
                        .background(
                            Color.dsSurfaceRaised,
                            in: RoundedRectangle(cornerRadius: DSMetrics.controlRadius)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: DSMetrics.controlRadius)
                                .stroke(Color.dsHairline)
                        }
                }
            }
        }
    }
}

private struct InspectionToken: Identifiable {
    let id: String
    let value: String
}

struct InspectionKeyValueList: View {
    let values: [String: String]
    let emptyText: LocalizedStringKey

    init(_ values: [String: String], emptyText: LocalizedStringKey = "None") {
        self.values = values
        self.emptyText = emptyText
    }

    var body: some View {
        if values.isEmpty {
            Text(emptyText)
                .foregroundStyle(Color.dsTextSecondary)
        } else {
            ForEach(values.keys.sorted(), id: \.self) { key in
                InspectionValueRow(rawLabel: key, value: values[key])
            }
        }
    }
}

struct InspectionEnvironmentList: View {
    private let entries: [InspectionEnvironmentEntry]

    init(values: [String]) {
        entries = values.enumerated().map {
            InspectionEnvironmentEntry(offset: $0.offset, element: $0.element)
        }
    }

    var body: some View {
        if entries.isEmpty {
            Text("No environment variables")
                .foregroundStyle(Color.dsTextSecondary)
        } else {
            ForEach(entries) { entry in
                InspectionSensitiveValueRow(name: entry.name, value: entry.value)
            }
        }
    }
}

private struct InspectionEnvironmentEntry: Identifiable {
    let id: String
    let name: String
    let value: String

    init(offset: Int, element: String) {
        let parts = element.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        name = parts.first.map(String.init) ?? element
        value = parts.count == 2 ? String(parts[1]) : ""
        id = "\(offset)-\(name)"
    }
}

private struct InspectionSensitiveValueRow: View {
    let name: String
    let value: String
    @State private var revealsValue = false

    var body: some View {
        LabeledContent {
            HStack(spacing: DSMetrics.spacing8) {
                if revealsValue {
                    MonoText(value: value, truncation: .middle)
                } else {
                    MonoText(
                        value: String(repeating: "•", count: min(max(value.count, 8), 20)),
                        dimmed: true,
                        selectable: false
                    )
                }

                Button {
                    revealsValue.toggle()
                } label: {
                    Image(systemName: revealsValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealsValue ? "Hide value" : "Reveal value")
                .accessibilityLabel(revealsValue ? "Hide \(name)" : "Reveal \(name)")
            }
        } label: {
            Text(verbatim: name)
        }
    }
}

struct InspectionCopyRawJSONButton: View {
    let rawJSON: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rawJSON, forType: .string)
        } label: {
            Label("Copy Raw JSON", systemImage: "doc.on.doc")
        }
        .help("Copies full inspection data, including unmasked environment values.")
    }
}

func inspectionByteCount(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
}

func inspectionPlatform(_ platform: PlatformDTO?) -> String? {
    guard let platform else { return nil }
    let values = [platform.os, platform.architecture, platform.variant].compactMap { $0 }
    return values.isEmpty ? nil : values.joined(separator: " / ")
}
