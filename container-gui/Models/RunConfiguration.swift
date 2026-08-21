import Foundation
import Darwin

nonisolated enum CommandValidationError: Error, Equatable, Sendable {
    case empty(field: String)
    case invalid(field: String, value: String)
    case nonPositive(field: String)
    case outOfRange(field: String, value: Int)
}

extension CommandValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty(let field):
            "\(field) cannot be empty."
        case .invalid(let field, let value):
            "\(value) is not a valid \(field.lowercased())."
        case .nonPositive(let field):
            "\(field) must be greater than zero."
        case .outOfRange(let field, let value):
            "\(field) value \(value) is outside the allowed range."
        }
    }
}

nonisolated struct ContainerIdentifier: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        guard !value.isEmpty else {
            throw CommandValidationError.empty(field: "Container identifier")
        }
        guard Self.isValid(value) else {
            throw CommandValidationError.invalid(field: "Container identifier", value: value)
        }
        rawValue = value
    }

    private static func isValid(_ value: String) -> Bool {
        guard value.first != "-", value.unicodeScalars.allSatisfy({
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

nonisolated struct ImageReference: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        guard !value.isEmpty else {
            throw CommandValidationError.empty(field: "Image reference")
        }
        guard value.first != "-",
              value.unicodeScalars.allSatisfy({
                  $0.isASCII
                      && !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw CommandValidationError.invalid(field: "Image reference", value: value)
        }
        rawValue = value
    }
}

nonisolated struct CPULimit: Equatable, Sendable {
    let value: String

    init(_ value: String) throws {
        guard value.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              decimal > 0
        else {
            throw CommandValidationError.invalid(field: "CPU limit", value: value)
        }
        self.value = value
    }
}

nonisolated struct MemoryLimit: Equatable, Sendable {
    let value: String

    init(_ value: String) throws {
        guard value.range(
            of: #"^[1-9][0-9]*(?:[KMGTPEkmgtpe](?:[Bb])?)?$"#,
            options: .regularExpression
        ) != nil else {
            throw CommandValidationError.invalid(field: "Memory limit", value: value)
        }
        self.value = value
    }
}

nonisolated struct EnvironmentVariable: Equatable, Sendable {
    let key: String
    let value: String

    init(key: String, value: String) throws {
        guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw CommandValidationError.invalid(field: "Environment variable key", value: key)
        }
        let controlCharacters = CharacterSet.controlCharacters
        guard !value.unicodeScalars.contains(where: { controlCharacters.contains($0) }) else {
            throw CommandValidationError.invalid(field: "Environment variable value", value: value)
        }
        self.key = key
        self.value = value
    }

    var argument: String {
        "\(key)=\(value)"
    }
}

nonisolated enum PortProtocol: String, Equatable, Sendable {
    case tcp
    case udp
}

nonisolated struct PortMapping: Equatable, Sendable {
    let hostAddress: String?
    let hostPort: Int
    let containerPort: Int
    let `protocol`: PortProtocol

    init(
        hostAddress: String? = nil,
        hostPort: Int,
        containerPort: Int,
        protocol: PortProtocol = .tcp
    ) throws {
        guard (1...65_535).contains(hostPort) else {
            throw CommandValidationError.outOfRange(field: "Host port", value: hostPort)
        }
        guard (1...65_535).contains(containerPort) else {
            throw CommandValidationError.outOfRange(field: "Container port", value: containerPort)
        }
        if let hostAddress {
            guard Self.isIPAddress(hostAddress) else {
                throw CommandValidationError.invalid(field: "Host IP address", value: hostAddress)
            }
        }
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocol = `protocol`
    }

    var argument: String {
        let address = hostAddress.map { $0.contains(":") ? "[\($0)]:" : "\($0):" } ?? ""
        let protocolSuffix = `protocol` == .tcp ? "" : "/\(`protocol`.rawValue)"
        return "\(address)\(hostPort):\(containerPort)\(protocolSuffix)"
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, value, &ipv6) == 1
    }
}

nonisolated enum ContainerMountSource: Equatable, Sendable {
    case volume(VolumeName)
    case hostPath(LocalPath)
}

nonisolated struct ContainerMount: Equatable, Sendable {
    let source: ContainerMountSource
    let target: LocalPath
    let isReadOnly: Bool

    init(volumeName: String, target: String, isReadOnly: Bool = false) throws {
        source = .volume(try VolumeName(validating: volumeName))
        self.target = try LocalPath(validating: target, field: "Container mount target")
        self.isReadOnly = isReadOnly
    }

    init(hostPath: String, target: String, isReadOnly: Bool = false) throws {
        source = .hostPath(try LocalPath(validating: hostPath, field: "Host mount source"))
        self.target = try LocalPath(validating: target, field: "Container mount target")
        self.isReadOnly = isReadOnly
    }

    var argument: String {
        let type: String
        let sourceValue: String
        switch source {
        case .volume(let name):
            type = "volume"
            sourceValue = name.rawValue
        case .hostPath(let path):
            type = "bind"
            sourceValue = path.rawValue
        }
        var values = ["type=\(type)", "source=\(sourceValue)", "target=\(target.rawValue)"]
        if isReadOnly { values.append("readonly") }
        return values.joined(separator: ",")
    }
}

nonisolated struct RunConfiguration: Equatable, Sendable {
    let image: ImageReference
    let name: ContainerIdentifier?
    let detached: Bool
    let removeWhenStopped: Bool
    let cpuLimit: CPULimit?
    let memoryLimit: MemoryLimit?
    let networks: [NetworkAttachment]
    let mounts: [ContainerMount]
    let ports: [PortMapping]
    let environment: [EnvironmentVariable]
    let disablesDNS: Bool
    let dnsNameservers: [DNSNameserver]
    let dnsDomain: DNSDomainName?
    let dnsSearchDomains: [DNSDomainName]
    let dnsOptions: [DNSOption]
    let command: [String]

    init(
        image: String,
        name: String? = nil,
        detached: Bool = true,
        removeWhenStopped: Bool = false,
        cpuLimit: String? = nil,
        memoryLimit: String? = nil,
        networks: [NetworkAttachment] = [],
        mounts: [ContainerMount] = [],
        ports: [PortMapping] = [],
        environment: [EnvironmentVariable] = [],
        disablesDNS: Bool = false,
        dnsNameservers: [DNSNameserver] = [],
        dnsDomain: DNSDomainName? = nil,
        dnsSearchDomains: [DNSDomainName] = [],
        dnsOptions: [DNSOption] = [],
        command: [String] = []
    ) throws {
        self.image = try ImageReference(validating: image)
        if let name {
            self.name = try ContainerIdentifier(validating: name)
        } else {
            self.name = nil
        }
        self.detached = detached
        self.removeWhenStopped = removeWhenStopped
        if let cpuLimit {
            self.cpuLimit = try CPULimit(cpuLimit)
        } else {
            self.cpuLimit = nil
        }
        if let memoryLimit {
            self.memoryLimit = try MemoryLimit(memoryLimit)
        } else {
            self.memoryLimit = nil
        }
        var networkNames = Set<String>()
        guard networks.allSatisfy({ networkNames.insert($0.network.rawValue).inserted }) else {
            throw CommandValidationError.invalid(
                field: "Network attachment",
                value: "Duplicate network"
            )
        }
        self.networks = networks
        var mountTargets = Set<String>()
        guard mounts.allSatisfy({ mountTargets.insert($0.target.rawValue).inserted }) else {
            throw CommandValidationError.invalid(
                field: "Container mount",
                value: "Duplicate target"
            )
        }
        self.mounts = mounts
        self.ports = ports
        self.environment = environment
        var nameservers = Set<String>()
        guard dnsNameservers.allSatisfy({ nameservers.insert($0.value).inserted }) else {
            throw CommandValidationError.invalid(field: "DNS", value: "Duplicate nameserver")
        }
        guard !disablesDNS || (dnsNameservers.isEmpty && dnsDomain == nil && dnsSearchDomains.isEmpty && dnsOptions.isEmpty) else {
            throw CommandValidationError.invalid(field: "DNS", value: "Values cannot be combined with --no-dns")
        }
        self.disablesDNS = disablesDNS
        self.dnsNameservers = dnsNameservers
        self.dnsDomain = dnsDomain
        self.dnsSearchDomains = dnsSearchDomains
        self.dnsOptions = dnsOptions
        self.command = command
    }

    var arguments: [String] {
        var result = ["run", "--progress", "plain"]
        if detached {
            result.append("--detach")
        }
        if removeWhenStopped {
            result.append("--rm")
        }
        if let name {
            result += ["--name", name.rawValue]
        }
        if let cpuLimit {
            result += ["--cpus", cpuLimit.value]
        }
        if let memoryLimit {
            result += ["--memory", memoryLimit.value]
        }
        for network in networks {
            result += ["--network", network.argument]
        }
        for mount in mounts {
            result += ["--mount", mount.argument]
        }
        for port in ports {
            result += ["--publish", port.argument]
        }
        for variable in environment {
            result += ["--env", variable.argument]
        }
        if disablesDNS {
            result.append("--no-dns")
        } else {
            for nameserver in dnsNameservers { result += ["--dns", nameserver.value] }
            if let dnsDomain { result += ["--dns-domain", dnsDomain.rawValue] }
            for search in dnsSearchDomains { result += ["--dns-search", search.rawValue] }
            for option in dnsOptions { result += ["--dns-option", option.value] }
        }
        result.append(image.rawValue)
        result += command
        return result
    }
}
