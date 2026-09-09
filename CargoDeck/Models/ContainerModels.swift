import Foundation

nonisolated struct CLIDateValue: Decodable, Equatable, Sendable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            date = Date(timeIntervalSinceReferenceDate: value)
            return
        }
        let value = try container.decode(String.self)
        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            date = parsed
        } else {
            date = try Date.ISO8601FormatStyle().parse(value)
        }
    }
}

nonisolated struct ContainerDTO: Decodable, Equatable, Sendable {
    let id: String?
    let configuration: ContainerConfigurationDTO?
    let status: ContainerStatusDTO?
    let networks: [ContainerNetworkDTO]?
    let creationDate: CLIDateValue?
    let startedDate: CLIDateValue?

    private enum CodingKeys: String, CodingKey {
        case id
        case configuration
        case status
        case networks
        case creationDate
        case createdAt
        case startedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        configuration = try container.decodeIfPresent(ContainerConfigurationDTO.self, forKey: .configuration)
        status = try container.decodeIfPresent(ContainerStatusDTO.self, forKey: .status)
        networks = try container.decodeIfPresent([ContainerNetworkDTO].self, forKey: .networks)
        creationDate = try container.decodeIfPresent(CLIDateValue.self, forKey: .creationDate)
            ?? container.decodeIfPresent(CLIDateValue.self, forKey: .createdAt)
        startedDate = try container.decodeIfPresent(CLIDateValue.self, forKey: .startedDate)
    }
}

nonisolated struct ContainerConfigurationDTO: Decodable, Equatable, Sendable {
    let id: String?
    let image: CLIReferenceDTO?
    let platform: PlatformDTO?
    let creationDate: CLIDateValue?
    let initProcess: InitProcessDTO?
    let resources: ContainerResourcesDTO?
    let networks: [ContainerNetworkDTO]?
    let publishedPorts: [PublishedPortDTO]?
    let publishedSockets: [PublishedSocketDTO]?
    let mounts: [ContainerMountDTO]?
    let labels: [String: String]?
    let sysctls: [String: String]?
    let dns: ContainerDNSDTO?
    let rosetta: Bool?
    let runtimeHandler: String?
    let virtualization: Bool?
    let ssh: Bool?
    let readOnly: Bool?
    let useInit: Bool?
    let capAdd: [String]?
    let capDrop: [String]?
    let shmSize: UInt64?
    let stopSignal: String?
    let maskedPaths: [String]?
    let readonlyPaths: [String]?
}

nonisolated struct CLIReferenceDTO: Decodable, Equatable, Sendable {
    let reference: String?
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case reference
        case name
        case digest
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            reference = value
            digest = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
            ?? container.decodeIfPresent(String.self, forKey: .name)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
    }
}

nonisolated struct PlatformDTO: Decodable, Equatable, Sendable {
    let os: String?
    let architecture: String?
    let variant: String?
    let osVersion: String?
    let osFeatures: [String]?
}

nonisolated struct InitProcessDTO: Decodable, Equatable, Sendable {
    let executable: String?
    let arguments: [String]?
    let environment: [String]?
    let workingDirectory: String?
    let terminal: Bool?
    let user: InspectionValue?
    let supplementalGroups: [UInt32]?
    let rlimits: [ProcessRlimitDTO]?
}

nonisolated struct ProcessRlimitDTO: Decodable, Equatable, Identifiable, Sendable {
    let limit: String?
    let soft: UInt64?
    let hard: UInt64?

    var id: String { limit ?? "unknown" }
}

nonisolated struct ContainerResourcesDTO: Decodable, Equatable, Sendable {
    let cpus: Int?
    let memoryInBytes: UInt64?
    let storage: UInt64?
    let cpuOverhead: Int?

    private enum CodingKeys: String, CodingKey {
        case cpus
        case memoryInBytes
        case memory
        case storage
        case cpuOverhead
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try container.decodeLossyIntIfPresent(forKey: .cpus)
        memoryInBytes = try container.decodeLossyUInt64IfPresent(forKeys: [.memoryInBytes, .memory])
        storage = try container.decodeLossyUInt64IfPresent(forKeys: [.storage])
        cpuOverhead = try container.decodeLossyIntIfPresent(forKey: .cpuOverhead)
    }
}

nonisolated struct ContainerStatusDTO: Decodable, Equatable, Sendable {
    let state: String?
    let startedDate: CLIDateValue?
    let exitCode: Int?
    let networks: [ContainerNetworkDTO]?

    private enum CodingKeys: String, CodingKey {
        case status
        case state
        case startedDate
        case exitCode
        case networks
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            state = value
            startedDate = nil
            exitCode = nil
            networks = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .status)
            ?? container.decodeIfPresent(String.self, forKey: .state)
        startedDate = try container.decodeIfPresent(CLIDateValue.self, forKey: .startedDate)
        exitCode = try container.decodeLossyIntIfPresent(forKey: .exitCode)
        networks = try container.decodeIfPresent([ContainerNetworkDTO].self, forKey: .networks)
    }
}

nonisolated struct ContainerNetworkDTO: Decodable, Equatable, Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let network: String?
        let hostname: String?
        let macAddress: String?
        let ipv4Address: String?
    }

    let network: String?
    let hostname: String?
    let address: String?
    let ipv4Address: String?
    let ipv6Address: String?
    let gateway: String?
    let ipv4Gateway: String?
    let macAddress: String?
    let mtu: Int?
    let variant: String?
    let options: ContainerNetworkOptionsDTO?

    var id: ID {
        ID(
            network: network,
            hostname: options?.hostname ?? hostname,
            macAddress: options?.macAddress ?? macAddress,
            ipv4Address: ipv4Address ?? address
        )
    }
}

nonisolated struct ContainerNetworkOptionsDTO: Decodable, Equatable, Sendable {
    let hostname: String?
    let macAddress: String?
    let mtu: Int?
}

nonisolated struct ContainerDNSDTO: Decodable, Equatable, Sendable {
    let nameservers: [String]?
    let domain: String?
    let searchDomains: [String]?
    let options: [String]?
}

nonisolated struct PublishedPortDTO: Decodable, Equatable, Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let hostAddress: String?
        let hostPort: Int?
        let containerPort: Int?
        let proto: String?
        let count: Int?
    }

    let hostAddress: String?
    let hostPort: Int?
    let containerPort: Int?
    let proto: String?
    let count: Int?

    var id: ID {
        ID(
            hostAddress: hostAddress,
            hostPort: hostPort,
            containerPort: containerPort,
            proto: proto,
            count: count
        )
    }

    private enum CodingKeys: String, CodingKey {
        case hostAddress
        case hostPort
        case containerPort
        case proto
        case protocolName = "protocol"
        case count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostAddress = try container.decodeIfPresent(String.self, forKey: .hostAddress)
        hostPort = try container.decodeLossyIntIfPresent(forKey: .hostPort)
        containerPort = try container.decodeLossyIntIfPresent(forKey: .containerPort)
        proto = try container.decodeIfPresent(String.self, forKey: .proto)
            ?? container.decodeIfPresent(String.self, forKey: .protocolName)
        count = try container.decodeLossyIntIfPresent(forKey: .count)
    }
}

nonisolated struct PublishedSocketDTO: Decodable, Equatable, Identifiable, Sendable {
    let containerPath: String?
    let hostPath: String?
    let permissions: InspectionValue?

    var id: String { containerPath ?? hostPath ?? "unknown" }

    private enum CodingKeys: String, CodingKey {
        case containerPath
        case hostPath
        case permissions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containerPath = try Self.decodePath(container, key: .containerPath)
        hostPath = try Self.decodePath(container, key: .hostPath)
        permissions = try container.decodeIfPresent(InspectionValue.self, forKey: .permissions)
    }

    private static func decodePath(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String? {
        guard let value = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value.hasPrefix("file:"), let url = URL(string: value), url.isFileURL else { return value }
        return url.path(percentEncoded: false)
    }
}

nonisolated struct ContainerMountDTO: Decodable, Equatable, Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case destination(String)
        case source(String)
        case anonymous(options: [String]?, type: String?)
    }

    let source: String?
    let destination: String?
    let options: [String]?
    let type: String?

    var id: ID {
        if let destination {
            return .destination(destination)
        }
        if let source {
            return .source(source)
        }
        return .anonymous(options: options, type: type)
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case destination
        case target
        case options
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
            ?? container.decodeIfPresent(String.self, forKey: .target)
        options = try container.decodeIfPresent([String].self, forKey: .options)
        type = try container.decodeIfPresent(InspectionValue.self, forKey: .type)?.compactDescription
    }
}

nonisolated indirect enum InspectionValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(String)
    case bool(Bool)
    case object([String: InspectionValue])
    case array([InspectionValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(String(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value.formatted())
        } else if let value = try? container.decode([String: InspectionValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([InspectionValue].self))
        }
    }

    var compactDescription: String {
        switch self {
        case .string(let value), .number(let value): value
        case .bool(let value): value ? "Yes" : "No"
        case .null: "None"
        case .array(let values): values.map(\.compactDescription).joined(separator: ", ")
        case .object(let values):
            values.sorted { $0.key < $1.key }.map { key, value in
                let nested = value.compactDescription
                return nested.isEmpty ? key : "\(key): \(nested)"
            }.joined(separator: ", ")
        }
    }

    var processUserDescription: String {
        guard case .object(let values) = self else { return compactDescription }
        if case .object(let id)? = values["id"],
           let uid = id["uid"]?.scalarDescription,
           let gid = id["gid"]?.scalarDescription {
            return "\(uid):\(gid)"
        }
        if case .object(let raw)? = values["raw"],
           let user = raw["userString"]?.scalarDescription {
            return user
        }
        return compactDescription
    }

    private var scalarDescription: String? {
        switch self {
        case .string(let value), .number(let value): value
        default: nil
        }
    }
}

nonisolated enum ContainerState: Equatable, Sendable {
    case created
    case running
    case stopped
    case paused
    case unknown(String)

    init(_ value: String?) {
        switch value?.lowercased() {
        case "created":
            self = .created
        case "running":
            self = .running
        case "stopped", "exited":
            self = .stopped
        case "paused":
            self = .paused
        case .some(let value):
            self = .unknown(value)
        case nil:
            self = .unknown("unknown")
        }
    }
}

nonisolated struct ContainerSummary: Identifiable, Equatable, Sendable {
    let id: String
    let image: String?
    let imageDigest: String?
    let state: ContainerState
    let operatingSystem: String?
    let architecture: String?
    let address: String?
    let createdAt: Date?
    let startedAt: Date?
    let publishedPorts: [PublishedPortDTO]
    let mounts: [ContainerMountDTO]
    let networkNames: [String]

    init?(dto: ContainerDTO) {
        guard let id = dto.configuration?.id ?? dto.id, !id.isEmpty else {
            return nil
        }
        let networks = dto.status?.networks ?? dto.networks ?? dto.configuration?.networks
        self.id = id
        image = dto.configuration?.image?.reference
        imageDigest = dto.configuration?.image?.digest
        state = ContainerState(dto.status?.state)
        operatingSystem = dto.configuration?.platform?.os
        architecture = dto.configuration?.platform?.architecture
        address = networks?.first?.ipv4Address ?? networks?.first?.address ?? networks?.first?.ipv6Address
        createdAt = parseCLIDate(dto.configuration?.creationDate ?? dto.creationDate)
        startedAt = parseCLIDate(dto.status?.startedDate ?? dto.startedDate)
        publishedPorts = dto.configuration?.publishedPorts ?? []
        mounts = dto.configuration?.mounts ?? []
        networkNames = (networks ?? [])
            .compactMap(\.network)
            .uniqued()
    }

    var portSummary: String {
        guard !publishedPorts.isEmpty else { return "—" }
        return publishedPorts.prefix(2).map { port in
            let container = port.containerPort.map(String.init) ?? "—"
            let proto = port.proto ?? "tcp"
            if let hostPort = port.hostPort {
                return "\(hostPort):\(container)/\(proto)"
            }
            return "\(container)/\(proto)"
        }.joined(separator: ", ") + (publishedPorts.count > 2 ? " +\(publishedPorts.count - 2)" : "")
    }
}

private extension Sequence where Element: Hashable {
    nonisolated func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

nonisolated struct ContainerNetwork: Equatable, Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case name(String)
        case macAddress(String)
        case ipv4Address(String)
        case ipv6Address(String)
        case hostname(String)
        case unknown
    }

    let name: String?
    let hostname: String?
    let ipv4Address: String?
    let ipv6Address: String?
    let gateway: String?
    let macAddress: String?
    let mtu: Int?
    let variant: String?

    var id: ID {
        if let name { return .name(name) }
        if let macAddress { return .macAddress(macAddress) }
        if let ipv4Address { return .ipv4Address(ipv4Address) }
        if let ipv6Address { return .ipv6Address(ipv6Address) }
        if let hostname { return .hostname(hostname) }
        return .unknown
    }
}

nonisolated struct ContainerDetails: Identifiable, Equatable, Sendable {
    let id: String
    let summary: ContainerSummary
    let networks: [ContainerNetwork]
    let ports: [PublishedPortDTO]
    let mounts: [ContainerMountDTO]
    let resources: ContainerResourcesDTO?
    let imageDigest: String?
    let createdAt: Date?
    let startedAt: Date?
    let exitCode: Int?
    let platform: PlatformDTO?
    let process: InitProcessDTO?
    let configuredNetworks: [ContainerNetworkDTO]
    let sockets: [PublishedSocketDTO]
    let labels: [String: String]
    let sysctls: [String: String]
    let dns: ContainerDNSDTO?
    let rosetta: Bool?
    let runtimeHandler: String?
    let virtualization: Bool?
    let ssh: Bool?
    let readOnly: Bool?
    let useInit: Bool?
    let capAdd: [String]
    let capDrop: [String]
    let shmSize: UInt64?
    let stopSignal: String?
    let maskedPaths: [String]?
    let readonlyPaths: [String]?

    init?(dto: ContainerDTO) {
        guard let summary = ContainerSummary(dto: dto) else {
            return nil
        }
        let sourceNetworks = dto.status?.networks ?? dto.networks ?? dto.configuration?.networks ?? []
        id = summary.id
        self.summary = summary
        networks = sourceNetworks.map {
            ContainerNetwork(
                name: $0.network,
                hostname: $0.hostname,
                ipv4Address: $0.ipv4Address ?? $0.address,
                ipv6Address: $0.ipv6Address,
                gateway: $0.ipv4Gateway ?? $0.gateway,
                macAddress: $0.macAddress,
                mtu: $0.mtu,
                variant: $0.variant
            )
        }
        ports = dto.configuration?.publishedPorts ?? []
        mounts = dto.configuration?.mounts ?? []
        resources = dto.configuration?.resources
        imageDigest = dto.configuration?.image?.digest
        createdAt = parseCLIDate(dto.configuration?.creationDate ?? dto.creationDate)
        startedAt = parseCLIDate(dto.status?.startedDate ?? dto.startedDate)
        exitCode = dto.status?.exitCode
        platform = dto.configuration?.platform
        process = dto.configuration?.initProcess
        configuredNetworks = dto.configuration?.networks ?? []
        sockets = dto.configuration?.publishedSockets ?? []
        labels = dto.configuration?.labels ?? [:]
        sysctls = dto.configuration?.sysctls ?? [:]
        dns = dto.configuration?.dns
        rosetta = dto.configuration?.rosetta
        runtimeHandler = dto.configuration?.runtimeHandler
        virtualization = dto.configuration?.virtualization
        ssh = dto.configuration?.ssh
        readOnly = dto.configuration?.readOnly
        useInit = dto.configuration?.useInit
        capAdd = dto.configuration?.capAdd ?? []
        capDrop = dto.configuration?.capDrop ?? []
        shmSize = dto.configuration?.shmSize
        stopSignal = dto.configuration?.stopSignal
        maskedPaths = dto.configuration?.maskedPaths
        readonlyPaths = dto.configuration?.readonlyPaths
    }
}

nonisolated private func parseCLIDate(_ value: CLIDateValue?) -> Date? {
    value?.date
}

nonisolated private extension KeyedDecodingContainer {
    func decodeLossyIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeLossyUInt64IfPresent(forKeys keys: [Key]) throws -> UInt64? {
        for key in keys {
            if let value = try? decodeIfPresent(UInt64.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(String.self, forKey: key), let result = UInt64(value) {
                return result
            }
        }
        return nil
    }
}
