import Foundation
import Observation

struct NetworkKeyValueDraft: Identifiable, Equatable {
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
final class NetworkCreateModel: Identifiable {
    let id = UUID()
    let capabilities: NetworkCapabilities

    var name = ""
    var mode: NetworkMode = .nat
    var ipv4Subnet = ""
    var ipv6Subnet = ""
    var labels: [NetworkKeyValueDraft] = []
    var plugin = NetworkCreateConfiguration.defaultPlugin
    var pluginVariant = ""
    var pluginOptions: [NetworkKeyValueDraft] = []

    init(capabilities: NetworkCapabilities) {
        self.capabilities = capabilities
    }

    var nameError: String? {
        validationMessage { _ = try NetworkName(validating: trimmed(name)) }
    }

    var ipv4Error: String? {
        optionalValidation(ipv4Subnet) {
            _ = try NetworkCIDR(validating: $0, family: .ipv4)
        }
    }

    var ipv6Error: String? {
        optionalValidation(ipv6Subnet) {
            _ = try NetworkCIDR(validating: $0, family: .ipv6)
        }
    }

    var pluginError: String? {
        let value = trimmed(plugin)
        guard !value.isEmpty else { return "Network plugin cannot be empty." }
        guard value.first != "-",
              value.unicodeScalars.allSatisfy({
                $0.isASCII
                    && !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
              }) else {
            return DiagnosticSanitizer.sanitize(
                CommandValidationError.invalid(
                    field: "Network plugin",
                    value: value
                ).localizedDescription
            )
        }
        return nil
    }

    var pluginVariantError: String? {
        guard pluginVariant.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return "Plugin variant cannot contain control characters."
    }

    func labelError(for draft: NetworkKeyValueDraft) -> String? {
        keyValueError(for: draft, in: labels, field: "Network label")
    }

    func optionError(for draft: NetworkKeyValueDraft) -> String? {
        keyValueError(for: draft, in: pluginOptions, field: "Network plugin option")
    }

    var configuration: NetworkCreateConfiguration? {
        try? makeConfiguration()
    }

    var commandPreview: String {
        guard let configuration else { return "container network create" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.createNetwork(configuration: configuration).arguments
        )
    }

    func addLabel() { labels.append(NetworkKeyValueDraft()) }
    func removeLabel(id: UUID) { labels.removeAll { $0.id == id } }
    func addPluginOption() { pluginOptions.append(NetworkKeyValueDraft()) }
    func removePluginOption(id: UUID) { pluginOptions.removeAll { $0.id == id } }

    private func makeConfiguration() throws -> NetworkCreateConfiguration {
        let customization: NetworkPluginCustomization
        switch capabilities.pluginCustomization {
        case .legacyVariant:
            let variant = trimmed(pluginVariant)
            customization = .legacyVariant(variant.isEmpty ? nil : variant)
        case .options:
            customization = .options(try pluginOptions.map(makeKeyValue))
        }
        let plugin = trimmed(plugin)
        return try NetworkCreateConfiguration(
            name: trimmed(name),
            mode: mode,
            ipv4Subnet: optionalTrimmed(ipv4Subnet),
            ipv6Subnet: optionalTrimmed(ipv6Subnet),
            labels: try labels.map(makeKeyValue),
            plugin: plugin == NetworkCreateConfiguration.defaultPlugin ? nil : plugin,
            customization: customization
        )
    }

    private func makeKeyValue(_ draft: NetworkKeyValueDraft) throws -> NetworkKeyValue {
        try NetworkKeyValue(key: trimmed(draft.key), value: draft.value)
    }

    private func keyValueError(
        for draft: NetworkKeyValueDraft,
        in values: [NetworkKeyValueDraft],
        field: String
    ) -> String? {
        let key = trimmed(draft.key)
        if !key.isEmpty, values.filter({ trimmed($0.key) == key }).count > 1 {
            return "Duplicate \(field.lowercased()) key."
        }
        return validationMessage { _ = try makeKeyValue(draft) }
    }

    private func optionalValidation(
        _ value: String,
        operation: (String) throws -> Void
    ) -> String? {
        guard let value = optionalTrimmed(value) else { return nil }
        return validationMessage { try operation(value) }
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
