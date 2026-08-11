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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}

struct InspectionValueRow: View {
    let label: LocalizedStringKey
    let value: String

    init(_ label: LocalizedStringKey, value: String?) {
        self.label = label
        self.value = value?.isEmpty == false ? value! : "—"
    }

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct InspectionBooleanRow: View {
    let label: LocalizedStringKey
    let value: Bool

    var body: some View {
        LabeledContent(label) {
            Label(value ? "Enabled" : "Disabled", systemImage: value ? "checkmark.circle" : "minus.circle")
                .foregroundStyle(value ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
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
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                ForEach(tokens) { token in
                    Text(token.value)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
                .foregroundStyle(.secondary)
        } else {
            ForEach(values.keys.sorted(), id: \.self) { key in
                InspectionValueRow(LocalizedStringKey(key), value: values[key])
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
                .foregroundStyle(.secondary)
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
        LabeledContent(name) {
            HStack(spacing: 6) {
                if revealsValue {
                    Text(value)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(String(repeating: "•", count: min(max(value.count, 8), 20)))
                        .font(.callout.monospaced())
                        .lineLimit(1)
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
