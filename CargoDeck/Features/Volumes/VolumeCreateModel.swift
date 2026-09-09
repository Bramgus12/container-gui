import Foundation
import Observation

struct VolumeKeyValueDraft: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

@MainActor
@Observable
final class VolumeCreateModel: Identifiable {
    let id = UUID()
    var name = ""
    var size = ""
    var labels: [VolumeKeyValueDraft] = []
    var options: [VolumeKeyValueDraft] = []

    var nameError: String? {
        validationMessage { _ = try VolumeName(validating: trimmed(name)) }
    }

    var sizeError: String? {
        let value = trimmed(size)
        guard !value.isEmpty else { return nil }
        return validationMessage { _ = try VolumeSize(validating: value) }
    }

    func labelError(for draft: VolumeKeyValueDraft) -> String? {
        keyValueError(for: draft, in: labels, field: "Volume label")
    }

    func optionError(for draft: VolumeKeyValueDraft) -> String? {
        keyValueError(for: draft, in: options, field: "Volume option")
    }

    var configuration: VolumeCreateConfiguration? { try? makeConfiguration() }

    var commandPreview: String {
        guard let configuration else { return "container volume create" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.createVolume(configuration: configuration).arguments
        )
    }

    func addLabel() { labels.append(VolumeKeyValueDraft()) }
    func addOption() { options.append(VolumeKeyValueDraft()) }
    func removeLabel(id: UUID) { labels.removeAll { $0.id == id } }
    func removeOption(id: UUID) { options.removeAll { $0.id == id } }

    private func makeConfiguration() throws -> VolumeCreateConfiguration {
        try VolumeCreateConfiguration(
            name: trimmed(name),
            labels: try labels.map(makeKeyValue),
            options: try options.map(makeKeyValue),
            size: optionalTrimmed(size)
        )
    }

    private func makeKeyValue(_ draft: VolumeKeyValueDraft) throws -> VolumeKeyValue {
        try VolumeKeyValue(key: trimmed(draft.key), value: draft.value)
    }

    private func keyValueError(
        for draft: VolumeKeyValueDraft,
        in rows: [VolumeKeyValueDraft],
        field: String
    ) -> String? {
        let key = trimmed(draft.key)
        if !key.isEmpty, rows.filter({ trimmed($0.key) == key }).count > 1 {
            return "Duplicate \(field.lowercased()) key."
        }
        return validationMessage { _ = try makeKeyValue(draft) }
    }

    private func validationMessage(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
