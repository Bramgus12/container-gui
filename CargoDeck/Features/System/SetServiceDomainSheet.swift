import SwiftUI

@MainActor
@Observable
final class SetServiceDomainModel: Identifiable {
    let id = UUID()
    var domain: String
    private(set) var saveError: String?
    let dns: DNSModel

    init(dns: DNSModel) {
        self.dns = dns
        domain = dns.serviceDomain ?? dns.pendingServiceDomain ?? ""
    }

    var domainError: String? {
        let value = trimmed(domain)
        guard !value.isEmpty else { return nil }
        do { _ = try DNSDomainName(validating: value); return nil }
        catch { return DiagnosticSanitizer.sanitize(error.localizedDescription) }
    }

    var configuration: DNSDomainName? {
        guard domainError == nil else { return nil }
        return try? DNSDomainName(validating: trimmed(domain))
    }

    var isSaving: Bool { dns.isWritingConfig }
    var snippet: String { dns.configSnippet(domain: configuration?.rawValue) }
    var configPath: String { dns.configFilePath }

    func save() async -> Bool {
        guard let configuration else { return false }
        saveError = nil
        let saved = await dns.setServiceDomain(configuration)
        saveError = saved ? nil : dns.actionError
        return saved
    }

    func copySnippet() { dns.copyConfigSnippet(domain: trimmed(domain)) }
    func reveal() { dns.revealConfigFile() }
    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Sets `[dns] domain` in the user's `config.toml`, the value that decides which
/// domain the service registers container names under. The file belongs to the
/// user, so unlike the resolver entry this needs no administrator access.
struct SetServiceDomainSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SetServiceDomainModel

    var body: some View {
        SheetScaffold(command: model.snippet, commandAccessibilityID: "system.dns.domain.preview", minHeight: 380) {
            VStack(spacing: 0) {
                SheetHeader(title: "Service Domain")
                Form {
                    Section("Domain") {
                        LabeledContent("Domain") {
                            TextField("cont", text: $model.domain)
                                .labelsHidden()
                                .dsMonoField()
                                .accessibilityIdentifier("system.dns.domain.field")
                        }
                        if let error = model.domainError {
                            Text(error).font(.caption).foregroundStyle(Color.dsStateDestructive)
                        }
                        Text("The app writes this to \(model.configPath), leaving every other setting in the file untouched.")
                            .font(.caption)
                            .foregroundStyle(Color.dsTextSecondary)
                        InlineBanner(message: "The service reads its DNS domain when it starts, so restart it from the Service card above to apply a change.", scope: .card, severity: .info)
                        Button("Reveal Config") { model.reveal() }
                        if let error = model.saveError {
                            InlineBanner(message: "The domain could not be saved", detail: error, scope: .card, severity: .error, copyValue: model.snippet)
                                .accessibilityIdentifier("system.dns.domain.error")
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } footer: {
            SheetCancelButton { dismiss() }
            Spacer()
            if model.isSaving { ProgressView().controlSize(.small) }
            Button("Copy TOML") { model.copySnippet() }
                .disabled(model.isSaving)
                .accessibilityIdentifier("system.dns.domain.copy")
            Button("Save") { Task { if await model.save() { dismiss() } } }
                .buttonStyle(.borderedProminent)
                .disabled(model.configuration == nil || model.isSaving)
                .accessibilityIdentifier("system.dns.domain.save")
        }
    }
}
