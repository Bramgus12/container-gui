import SwiftUI

@MainActor
@Observable
final class AddLocalDomainModel: Identifiable {
    let id = UUID()
    var domain = ""
    var localhostRedirect = ""
    private(set) var didCopy = false
    let dns: DNSModel
    init(dns: DNSModel) { self.dns = dns }

    var domainError: String? { validation { _ = try DNSDomainName(validating: trimmed(domain)) } }
    var localhostError: String? {
        guard !trimmed(localhostRedirect).isEmpty else { return nil }
        return validation { let address = try DNSNameserver(validating: trimmed(localhostRedirect)); if !address.isIPv4 { throw CommandValidationError.invalid(field: "localhost redirect", value: address.value) } }
    }
    var configuration: DNSCreateConfiguration? {
        guard domainError == nil, localhostError == nil else { return nil }
        return try? DNSCreateConfiguration(domain: DNSDomainName(validating: trimmed(domain)), localhostRedirect: trimmed(localhostRedirect).isEmpty ? nil : DNSNameserver(validating: trimmed(localhostRedirect)))
    }
    var sudoCommand: String { configuration?.sudoCommand ?? "sudo container system dns create" }
    var previewDomain: String {
        let domain = trimmed(domain)
        return domain.isEmpty ? "test" : domain
    }
    func copy() { guard let configuration else { return }; dns.copyCreateCommand(configuration); didCopy = true }
    private func validation(_ work: () throws -> Void) -> String? { do { try work(); return nil } catch { return DiagnosticSanitizer.sanitize(error.localizedDescription) } }
    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct AddLocalDomainSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AddLocalDomainModel
    var body: some View {
        SheetScaffold(command: model.sudoCommand, commandAccessibilityID: "system.dns.create.preview") {
            Form {
                Section("Local domain") {
                    LabeledContent("Domain") { TextField("test", text: $model.domain).labelsHidden().dsMonoField().accessibilityIdentifier("system.dns.create.domain") }
                    if let error = model.domainError { Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive) }
                    Text("Containers will answer as <name>.\(model.previewDomain)").font(.caption).foregroundStyle(Color.dsTextSecondary)
                    LabeledContent("Redirect an IP to localhost (optional)") { TextField("192.168.64.1", text: $model.localhostRedirect).labelsHidden().dsMonoField().accessibilityIdentifier("system.dns.create.localhost") }
                    if let error = model.localhostError { Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive) }
                    InlineBanner(message: "The service domain must also be set in config.toml or containers will not register here.", scope: .card, severity: .attention, actionTitle: "Copy TOML") { model.dns.copyConfigSnippet(domain: model.domain) }
                    Button("Reveal Config") { model.dns.revealConfigFile() }
                }
            }.formStyle(.grouped)
        } footer: {
            SheetCancelButton { dismiss() }
            Spacer()
            Text("Run the copied command in Terminal; the app does not request your administrator password.").font(.caption).foregroundStyle(Color.dsTextSecondary)
            Button(model.didCopy ? "Copied" : "Copy Command") { model.copy() }.buttonStyle(.borderedProminent).disabled(model.configuration == nil).accessibilityIdentifier("system.dns.create.copy")
            Button("Re-check") { Task { await model.dns.refresh(); if model.dns.domains.contains(where: { $0.name == model.domain }) { dismiss() } } }.accessibilityIdentifier("system.dns.create.recheck")
        }
    }
}
