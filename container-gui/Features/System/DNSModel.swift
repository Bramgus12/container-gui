import AppKit
import Foundation
import Observation

enum DNSLoadingState: Equatable, Sendable {
    case idle, loading, loaded
    case failed(String)
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

    private let service: any DNSManaging
    private let resolverReader: any ResolverDirectoryReading
    private let hostResolver: any HostResolving
    private let failureLog: OperationFailureLog
    private let copier: any DiagnosticsCopying
    private var refreshGeneration = 0

    init(service: any DNSManaging, resolverReader: any ResolverDirectoryReading, hostResolver: any HostResolving, failureLog: OperationFailureLog, copier: (any DiagnosticsCopying)? = nil) {
        self.service = service
        self.resolverReader = resolverReader
        self.hostResolver = hostResolver
        self.failureLog = failureLog
        self.copier = copier ?? SystemDiagnosticsCopier()
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

    func copyCreateCommand(_ configuration: DNSCreateConfiguration) { copy(configuration.sudoCommand) }
    func copyDeleteCommand(_ configuration: DNSDeleteConfiguration) { copy(configuration.sudoCommand) }
    func copyConfigSnippet(domain: String? = nil) { copy("[dns]\ndomain = \"\(domain ?? serviceDomain ?? "cont")\"") }
    func revealConfigFile() { NSWorkspace.shared.activateFileViewerSelecting([resolverReader.configFileURL()]) }
    func dismissActionError() { actionError = nil }

    private func copy(_ value: String) { copier.copy(value); didCopyCommand = true }
    private static func isCancellation(_ error: Error) -> Bool { error is CancellationError || error as? CLIError == .cancelled }
    private static func capture<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
