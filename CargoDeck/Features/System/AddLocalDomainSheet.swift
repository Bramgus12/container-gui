import SwiftUI

@MainActor
@Observable
final class AddLocalDomainModel: Identifiable {
    let id = UUID()
    var domain = ""
    var localhostRedirect = ""
    private(set) var didCopy = false
    private(set) var didSetServiceDomain = false
    private(set) var addError: String?
    private(set) var configError: String?
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
    var isAdding: Bool { dns.activeMutation == .create(trimmed(domain)) }
    /// True once this domain is the one the service registers containers under,
    /// whether it was already set or the sheet just wrote it.
    var isServiceDomain: Bool {
        let value = trimmed(domain)
        return !value.isEmpty && (dns.serviceDomain == value || dns.pendingServiceDomain == value)
    }

    /// Writes the domain being added to `config.toml`, so the sheet finishes the
    /// second half of the setup instead of describing it.
    func setAsServiceDomain() async {
        guard let domain = try? DNSDomainName(validating: trimmed(domain)) else { return }
        configError = nil
        didSetServiceDomain = await dns.setServiceDomain(domain)
        configError = didSetServiceDomain ? nil : dns.actionError
    }

    func copy() { guard let configuration else { return }; dns.copyCreateCommand(configuration); didCopy = true }
    /// The sheet stays up over the banner that would otherwise carry a failure,
    /// so it keeps this attempt's own message and shows it inline.
    func add() async -> Bool {
        guard let configuration else { return false }
        addError = nil
        let added = await dns.createDomain(configuration)
        addError = added ? nil : dns.actionError
        return added
    }
    private func validation(_ work: () throws -> Void) -> String? { do { try work(); return nil } catch { return DiagnosticSanitizer.sanitize(error.localizedDescription) } }
    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct AddLocalDomainSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AddLocalDomainModel
    @State fileprivate var sudoCommand: PrivilegedCommandModel?
    var body: some View {
        SheetScaffold(command: model.sudoCommand, commandAccessibilityID: "system.dns.create.preview") {
            Form {
                Section("Local domain") {
                    LabeledContent("Domain") { TextField("test", text: $model.domain).labelsHidden().dsMonoField().accessibilityIdentifier("system.dns.create.domain") }
                    if let error = model.domainError { Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive) }
                    Text("Containers will answer as <name>.\(model.previewDomain)").font(.caption).foregroundStyle(Color.dsTextSecondary)
                    LabeledContent("Redirect an IP to localhost (optional)") { TextField("192.168.64.1", text: $model.localhostRedirect).labelsHidden().dsMonoField().accessibilityIdentifier("system.dns.create.localhost") }
                    if let error = model.localhostError { Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive) }
                    if model.isServiceDomain {
                        InlineBanner(message: "This is already the service domain, so containers will register here.", scope: .card, severity: .info)
                    } else {
                        InlineBanner(message: "The service domain must also be set in config.toml or containers will not register here.", scope: .card, severity: .attention, actionTitle: "Set as Service Domain") { Task { await model.setAsServiceDomain() } }
                            .accessibilityIdentifier("system.dns.create.setServiceDomain")
                    }
                    if let error = model.configError {
                        InlineBanner(message: "config.toml could not be changed", detail: error, scope: .card, severity: .error, copyValue: model.dns.configSnippet(domain: model.domain))
                            .accessibilityIdentifier("system.dns.create.configError")
                    }
                    HStack { Button("Reveal Config") { model.dns.revealConfigFile() }; Button("Copy TOML") { model.dns.copyConfigSnippet(domain: model.domain) } }
                    if let error = model.addError {
                        InlineBanner(message: "The domain could not be added", detail: error, scope: .card, severity: .error, copyValue: model.sudoCommand)
                            .accessibilityIdentifier("system.dns.create.error")
                    }
                }
            }.formStyle(.grouped)
        } footer: {
            SheetCancelButton { dismiss() }
            Spacer()
            if model.isAdding {
                ProgressView().controlSize(.small)
                Text("Waiting for macOS to authenticate you…").font(.caption).foregroundStyle(Color.dsTextSecondary)
            } else {
                Text("Writing to /etc/resolver needs administrator access, so macOS will ask for your password.").font(.caption).foregroundStyle(Color.dsTextSecondary)
            }
            Button(model.didCopy ? "Copied" : "Copy Command") { model.copy() }.disabled(model.configuration == nil || model.isAdding).accessibilityIdentifier("system.dns.create.copy")
            Button("Run with sudo…") { if let configuration = model.configuration { sudoCommand = model.dns.makeSudoCommand(create: configuration) } }.disabled(model.configuration == nil || model.isAdding).accessibilityIdentifier("system.dns.create.sudo")
            Button("Re-check") { Task { await model.dns.refresh(); if model.dns.domains.contains(where: { $0.name == model.domain }) { dismiss() } } }.disabled(model.isAdding).accessibilityIdentifier("system.dns.create.recheck")
            Button("Add Domain") { Task { if await model.add() { dismiss() } } }.buttonStyle(.borderedProminent).disabled(model.configuration == nil || model.isAdding).accessibilityIdentifier("system.dns.create.submit")
        }
        .sheet(item: $sudoCommand) { command in
            PrivilegedCommandSheet(model: command) {
                // Reload from /etc/resolver rather than assuming the write
                // landed, then close the add sheet once the domain is really
                // there.
                await model.dns.refresh()
                if model.dns.domains.contains(where: { $0.name == model.domain }) { dismiss() }
            }
        }
    }
}
