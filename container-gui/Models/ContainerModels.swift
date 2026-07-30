import Foundation

struct ContainerDTO: Decodable, Equatable, Sendable {
    let id: String?
    let configuration: ContainerConfigurationDTO?
    let status: ContainerStatusDTO?
    let networks: [ContainerNetworkDTO]?
    let creationDate: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case configuration
        case status
        case networks
        case creationDate
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        configuration = try container.decodeIfPresent(ContainerConfigurationDTO.self, forKey: .configuration)
        status = try container.decodeIfPresent(ContainerStatusDTO.self, forKey: .status)
        networks = try container.decodeIfPresent([ContainerNetworkDTO].self, forKey: .networks)
        creationDate = try container.decodeIfPresent(String.self, forKey: .creationDate)
            ?? container.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

struct ContainerConfigurationDTO: Decodable, Equatable, Sendable {
    let id: String?
    let image: CLIReferenceDTO?
    let platform: PlatformDTO?
    let creationDate: String?
    let initProcess: InitProcessDTO?
    let resources: ContainerResourcesDTO?
    let networks: [ContainerNetworkDTO]?
    let publishedPorts: [PublishedPortDTO]?
    let mounts: [ContainerMountDTO]?
    let labels: [String: String]?
    let readOnly: Bool?
}

struct CLIReferenceDTO: Decodable, Equatable, Sendable {
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

struct PlatformDTO: Decodable, Equatable, Sendable {
    let os: String?
    let architecture: String?
    let variant: String?
}

struct InitProcessDTO: Decodable, Equatable, Sendable {
    let executable: String?
    let arguments: [String]?
    let environment: [String]?
    let workingDirectory: String?
}

struct ContainerResourcesDTO: Decodable, Equatable, Sendable {
    let cpus: Int?
    let memoryInBytes: UInt64?

    private enum CodingKeys: String, CodingKey {
        case cpus
        case memoryInBytes
        case memory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try container.decodeLossyIntIfPresent(forKey: .cpus)
        memoryInBytes = try container.decodeLossyUInt64IfPresent(forKeys: [.memoryInBytes, .memory])
    }
}

struct ContainerStatusDTO: Decodable, Equatable, Sendable {
    let state: String?
    let startedDate: String?
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
        startedDate = try container.decodeIfPresent(String.self, forKey: .startedDate)
        exitCode = try container.decodeLossyIntIfPresent(forKey: .exitCode)
        networks = try container.decodeIfPresent([ContainerNetworkDTO].self, forKey: .networks)
    }
}

struct ContainerNetworkDTO: Decodable, Equatable, Sendable {
    let network: String?
    let hostname: String?
    let address: String?
    let ipv4Address: String?
    let ipv6Address: String?
    let gateway: String?
    let macAddress: String?
    let mtu: Int?
}

struct PublishedPortDTO: Decodable, Equatable, Sendable {
    let hostAddress: String?
    let hostPort: Int?
    let containerPort: Int?
    let proto: String?

    private enum CodingKeys: String, CodingKey {
        case hostAddress
        case hostPort
        case containerPort
        case proto
        case protocolName = "protocol"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostAddress = try container.decodeIfPresent(String.self, forKey: .hostAddress)
        hostPort = try container.decodeLossyIntIfPresent(forKey: .hostPort)
        containerPort = try container.decodeLossyIntIfPresent(forKey: .containerPort)
        proto = try container.decodeIfPresent(String.self, forKey: .proto)
            ?? container.decodeIfPresent(String.self, forKey: .protocolName)
    }
}

struct ContainerMountDTO: Decodable, Equatable, Sendable {
    let source: String?
    let destination: String?
    let options: [String]?
    let type: String?

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
        type = try? container.decode(String.self, forKey: .type)
    }
}

enum ContainerState: Equatable, Sendable {
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

struct ContainerSummary: Identifiable, Equatable, Sendable {
    let id: String
    let image: String?
    let state: ContainerState
    let operatingSystem: String?
    let architecture: String?
    let address: String?
    let createdAt: Date?

    init?(dto: ContainerDTO) {
        guard let id = dto.configuration?.id ?? dto.id, !id.isEmpty else {
            return nil
        }
        let networks = dto.status?.networks ?? dto.networks ?? dto.configuration?.networks
        self.id = id
        image = dto.configuration?.image?.reference
        state = ContainerState(dto.status?.state)
        operatingSystem = dto.configuration?.platform?.os
        architecture = dto.configuration?.platform?.architecture
        address = networks?.first?.ipv4Address ?? networks?.first?.address ?? networks?.first?.ipv6Address
        createdAt = parseCLIDate(dto.configuration?.creationDate ?? dto.creationDate)
    }
}

struct ContainerNetwork: Equatable, Sendable {
    let name: String?
    let hostname: String?
    let ipv4Address: String?
    let ipv6Address: String?
    let macAddress: String?
}

struct ContainerDetails: Identifiable, Equatable, Sendable {
    let id: String
    let summary: ContainerSummary
    let networks: [ContainerNetwork]
    let ports: [PublishedPortDTO]
    let mounts: [ContainerMountDTO]
    let resources: ContainerResourcesDTO?

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
                macAddress: $0.macAddress
            )
        }
        ports = dto.configuration?.publishedPorts ?? []
        mounts = dto.configuration?.mounts ?? []
        resources = dto.configuration?.resources
    }
}

private func parseCLIDate(_ value: String?) -> Date? {
    guard let value else {
        return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private extension KeyedDecodingContainer {
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
