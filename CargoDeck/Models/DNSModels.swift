import Darwin
import Foundation

nonisolated struct DNSDomainName: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty else { throw CommandValidationError.empty(field: "DNS domain") }
        guard value.count <= 253, value.first != "-", labels.allSatisfy({ label in
            String(label).range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
        }) else {
            throw CommandValidationError.invalid(field: "DNS domain", value: value)
        }
        rawValue = value
    }
}

nonisolated struct DNSNameserver: Hashable, Sendable {
    let value: String

    init(validating value: String) throws {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1 else {
            throw CommandValidationError.invalid(field: "DNS nameserver", value: value)
        }
        self.value = value
    }

    var isIPv4: Bool {
        var address = in_addr()
        return inet_pton(AF_INET, value, &address) == 1
    }
}

nonisolated struct DNSOption: Hashable, Sendable {
    let value: String

    init(validating value: String) throws {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*(:[A-Za-z0-9]+)?$"#, options: .regularExpression) != nil else {
            throw CommandValidationError.invalid(field: "DNS option", value: value)
        }
        self.value = value
    }
}

nonisolated struct ResolverFile: Identifiable, Equatable, Sendable {
    let path: URL
    let domain: String
    let search: [String]
    let nameserver: String?
    let port: Int?
    var id: URL { path }

    static func parse(_ text: String, path: URL) -> ResolverFile? {
        var values: [String: [String]] = [:]
        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let parts = rawLine.split(whereSeparator: \Character.isWhitespace)
            guard parts.count >= 2 else { continue }
            values[String(parts[0]), default: []].append(parts.dropFirst().joined(separator: " "))
        }
        guard let domain = values["domain"]?.first,
              (try? DNSDomainName(validating: domain)) != nil else { return nil }
        return ResolverFile(path: path, domain: domain, search: values["search"] ?? [], nameserver: values["nameserver"]?.first, port: values["port"]?.first.flatMap(Int.init))
    }
}

nonisolated struct LocalDNSDomain: Identifiable, Equatable, Sendable {
    let name: String
    let resolverFile: ResolverFile?
    let isServiceDomain: Bool
    let registeredCount: Int
    var id: String { name }
}

nonisolated enum DNSReadiness: Equatable, Sendable {
    case resolving(domain: String)
    case serviceOnly(domain: String)
    case resolverOnly(domain: String)
    case notConfigured

    static func resolve(serviceDomain: String?, resolverDomains: [String]) -> DNSReadiness {
        if let serviceDomain, resolverDomains.contains(serviceDomain) { return .resolving(domain: serviceDomain) }
        if let serviceDomain { return .serviceOnly(domain: serviceDomain) }
        if let domain = resolverDomains.first { return .resolverOnly(domain: domain) }
        return .notConfigured
    }

    var designState: DSState {
        switch self { case .resolving: .running; case .serviceOnly, .resolverOnly: .attention; case .notConfigured: .idle }
    }

    var message: String {
        switch self {
        case .resolving(let domain): "Containers resolve from macOS as <name>.\(domain)."
        case .serviceOnly(let domain): "The service uses \(domain), but macOS is not pointed at it."
        case .resolverOnly(let domain): "macOS resolves \(domain), but the service does not register containers there."
        case .notConfigured: "Local container name resolution is not configured."
        }
    }
}

nonisolated struct DNSCreateConfiguration: Equatable, Sendable {
    let domain: DNSDomainName
    let localhostRedirect: DNSNameserver?
    var arguments: [String] { ["system", "dns", "create", domain.rawValue] + (localhostRedirect.map { ["--localhost", $0.value] } ?? []) }
    var sudoCommand: String { "sudo " + ProcessContainerCLI.displayInvocation(executable: "container", arguments: arguments) }
}

nonisolated struct DNSDeleteConfiguration: Equatable, Sendable {
    let domain: DNSDomainName
    var arguments: [String] { ["system", "dns", "delete", domain.rawValue] }
    var sudoCommand: String { "sudo " + ProcessContainerCLI.displayInvocation(executable: "container", arguments: arguments) }
}

nonisolated struct RegisteredName: Identifiable, Equatable, Sendable {
    let hostname: String
    let address: String
    let networkName: String
    let state: ContainerState
    var id: String { "\(hostname)|\(networkName)" }
}

nonisolated enum DNSProbeResult: Equatable, Sendable {
    case resolved(address: String, duration: Duration)
    case failed(String)
}
