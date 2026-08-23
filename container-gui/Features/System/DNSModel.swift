import AppKit
import Foundation
import Observation

enum DNSLoadingState: Equatable, Sendable {
    case idle, loading, loaded
    case failed(String)
}

/// The privileged domain change in flight, so the sheet and the list can show
/// which domain macOS is authenticating and keep a second request out.
enum DNSMutation: Equatable, Sendable {
    case create(String)
    case delete(String)

    var domain: String {
        switch self { case .create(let domain), .delete(let domain): domain }
    }
}

@MainActor
@Observable
final class DNSModel {
    private(set) var listState: DNSLoadingState = .idle
    private(set) var domains: [LocalDNSDomain] = []
    private(set) var serviceDomain: String?
    private(set) var readiness: DNSReadiness = .notConfigured
    private(set) var probe: DNSProbeResult?
    private(set) var isProbing = false
    private(set) var registeredNames: [RegisteredName] = []
    private(set) var didCopyCommand = false
    private(set) var actionError: String?
    private(set) var activeMutation: DNSMutation?
    private(set) var isWritingConfig = false
    /// A domain written to `config.toml` that the service has not reported yet,
    /// which means it loads its DNS domain at start and needs restarting.
    private(set) var pendingServiceDomain: String?

    private let service: any DNSManaging
    private let resolverReader: any ResolverDirectoryReading
    private let hostResolver: any HostResolving
    private let failureLog: OperationFailureLog
    private let copier: any DiagnosticsCopying
    private let configFile: any ServiceDomainWriting
    private var refreshGeneration = 0

    init(service: any DNSManaging, resolverReader: any ResolverDirectoryReading, hostResolver: any HostResolving, failureLog: OperationFailureLog, copier: (any DiagnosticsCopying)? = nil, configFile: (any ServiceDomainWriting)? = nil) {
        self.service = service
        self.resolverReader = resolverReader
        self.hostResolver = hostResolver
        self.failureLog = failureLog
        self.copier = copier ?? SystemDiagnosticsCopier()
        self.configFile = configFile ?? ContainerConfigFile(url: resolverReader.configFileURL())
    }

    func loadIfNeeded() async { if listState == .idle { await refresh() } }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        listState = .loading
        actionError = nil
        async let domainResult = Self.capture { try await self.service.listDomains() }
        async let propertyResult = Self.capture { try await self.service.loadServiceDomain() }
        let (listed, property) = await (domainResult, propertyResult)
        guard generation == refreshGeneration else { return }
        do {
            let listedDomains = try listed.get()
            serviceDomain = try property.get()
            let resolverFiles = resolverReader.resolverFiles()
            let names = Set(listedDomains).union(serviceDomain.map { [$0] } ?? [])
            domains = names.sorted().map { name in
                LocalDNSDomain(name: name, resolverFile: resolverFiles.first { $0.domain == name }, isServiceDomain: name == serviceDomain, registeredCount: registeredNames.filter { $0.hostname.hasSuffix(".\(name)") }.count)
            }
            readiness = .resolve(serviceDomain: serviceDomain, resolverDomains: listedDomains)
            if pendingServiceDomain == serviceDomain { pendingServiceDomain = nil }
            listState = .loaded
        } catch {
            if Self.isCancellation(error) { listState = domains.isEmpty ? .idle : .loaded; return }
            failureLog.record(operation: "Refresh DNS settings", error: error)
            listState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    func updateRegisteredNames(from containers: [ContainerSummary]) {
        guard let serviceDomain else { registeredNames = []; return }
        registeredNames = containers.compactMap { container in
            guard let address = container.address else { return nil }
            return RegisteredName(hostname: "\(container.id).\(serviceDomain)", address: address, networkName: container.networkNames.first ?? "—", state: container.state)
        }
    }

    func probeResolution() async {
        guard !isProbing, let host = registeredNames.first?.hostname else { return }
        isProbing = true
        defer { isProbing = false }
        probe = await hostResolver.resolve(host)
        if case .failed(let message) = probe { actionError = DiagnosticSanitizer.sanitize(message) }
    }

    /// Adds the domain to `/etc/resolver` after macOS has authenticated the
    /// user, and reports whether the domain is now present.
    @discardableResult
    func createDomain(_ configuration: DNSCreateConfiguration) async -> Bool {
        await mutate(.create(configuration.domain.rawValue), operation: "Create DNS domain") {
            try await self.service.createDomain(configuration)
        }
    }

    /// Removes the domain from `/etc/resolver` after macOS has authenticated the
    /// user, and reports whether the domain is gone.
    @discardableResult
    func deleteDomain(_ configuration: DNSDeleteConfiguration) async -> Bool {
        await mutate(.delete(configuration.domain.rawValue), operation: "Delete DNS domain") {
            try await self.service.deleteDomain(configuration)
        }
    }

    /// Sets the service domain in `config.toml` for the user. The file is theirs,
    /// so this needs no administrator access — but the service reads its DNS
    /// domain at start, so the write only counts once the service reports it.
    @discardableResult
    func setServiceDomain(_ domain: DNSDomainName) async -> Bool {
        guard !isWritingConfig, activeMutation == nil else { return false }
        isWritingConfig = true
        actionError = nil
        defer { isWritingConfig = false }

        do {
            _ = try configFile.writeServiceDomain(domain)
        } catch {
            failureLog.record(operation: "Set service DNS domain", error: error)
            actionError = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return false
        }

        pendingServiceDomain = domain.rawValue
        await refresh()
        return true
    }

    func copyCreateCommand(_ configuration: DNSCreateConfiguration) { copy(configuration.sudoCommand) }
    func copyDeleteCommand(_ configuration: DNSDeleteConfiguration) { copy(configuration.sudoCommand) }
    func configSnippet(domain: String? = nil) -> String { "[dns]\ndomain = \"\(domain ?? serviceDomain ?? "cont")\"" }
    func copyConfigSnippet(domain: String? = nil) { copy(configSnippet(domain: domain)) }
    func revealConfigFile() { NSWorkspace.shared.activateFileViewerSelecting([resolverReader.configFileURL()]) }
    /// The config file's path, abbreviated with `~` the way the user would write it.
    var configFilePath: String { (resolverReader.configFileURL().path as NSString).abbreviatingWithTildeInPath }
    func dismissActionError() { actionError = nil }

    /// Runs one privileged change at a time and reloads afterwards, so the list
    /// reflects what `/etc/resolver` holds rather than what was asked for. A
    /// dismissed password dialog leaves no error behind: nothing changed, and
    /// the user already knows why.
    private func mutate(
        _ mutation: DNSMutation,
        operation: String,
        work: @escaping () async throws -> Void
    ) async -> Bool {
        guard activeMutation == nil else { return false }
        activeMutation = mutation
        actionError = nil
        defer { activeMutation = nil }

        do {
            try await work()
        } catch {
            if Self.isCancellation(error) { return false }
            failureLog.record(operation: operation, error: error)
            actionError = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return false
        }

        await refresh()
        let exists = domains.contains { $0.name == mutation.domain }
        switch mutation {
        case .create: return exists
        case .delete: return !exists
        }
    }

    private func copy(_ value: String) { copier.copy(value); didCopyCommand = true }
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || error as? CLIError == .cancelled
            || error as? PrivilegedCommandError == .cancelled
    }
    private static func capture<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
