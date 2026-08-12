import Darwin
import Foundation

nonisolated struct NetworkName: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        guard !value.isEmpty else {
            throw CommandValidationError.empty(field: "Network name")
        }
        guard value.count <= 63,
              value.range(
                of: #"^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$"#,
                options: .regularExpression
              ) != nil else {
            throw CommandValidationError.invalid(field: "Network name", value: value)
        }
        rawValue = value
    }
}

nonisolated struct NetworkCIDR: Equatable, Sendable {
    enum AddressFamily: Equatable, Sendable {
        case ipv4
        case ipv6
    }

    let rawValue: String
    let address: String
    let prefixLength: Int
    let family: AddressFamily

    init(validating value: String, family requiredFamily: AddressFamily? = nil) throws {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              !pieces[0].isEmpty,
              pieces[1].range(of: #"^[0-9]{1,3}$"#, options: .regularExpression) != nil,
              let prefixLength = Int(pieces[1]) else {
            throw CommandValidationError.invalid(field: "Network CIDR", value: value)
        }

        let address = String(pieces[0])
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let family: AddressFamily
        let validPrefix: Bool
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            family = .ipv4
            validPrefix = (0...32).contains(prefixLength)
        } else if inet_pton(AF_INET6, address, &ipv6) == 1 {
            family = .ipv6
            validPrefix = (0...128).contains(prefixLength)
        } else {
            throw CommandValidationError.invalid(field: "Network CIDR", value: value)
        }
        guard validPrefix, requiredFamily == nil || requiredFamily == family else {
            throw CommandValidationError.invalid(field: "Network CIDR", value: value)
        }

        rawValue = value
        self.address = address
        self.prefixLength = prefixLength
        self.family = family
    }
}

nonisolated struct NetworkKeyValue: Hashable, Sendable {
    let key: String
    let value: String

    init(key: String, value: String) throws {
        guard !key.isEmpty else {
            throw CommandValidationError.empty(field: "Network key")
        }
        guard !key.unicodeScalars.contains(where: {
            $0 == "=" || CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw CommandValidationError.invalid(field: "Network key", value: key)
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CommandValidationError.invalid(field: "Network value", value: value)
        }
        self.key = key
        self.value = value
    }

    var argument: String { "\(key)=\(value)" }
}

nonisolated enum NetworkMode: String, CaseIterable, Equatable, Sendable {
    case nat
    case `internal`
}

nonisolated enum NetworkPluginCustomization: Equatable, Sendable {
    case legacyVariant(String?)
    case options([NetworkKeyValue])
}

nonisolated struct NetworkCapabilities: Equatable, Sendable {
    enum PluginCustomization: Equatable, Sendable {
        case legacyVariant
        case options
    }

    let pluginCustomization: PluginCustomization

    init(version: SemanticVersion) {
        pluginCustomization = version.major == 0 ? .legacyVariant : .options
    }
}

nonisolated struct NetworkCreateConfiguration: Equatable, Sendable {
    static let defaultPlugin = "container-network-vmnet"

    let name: NetworkName
    let mode: NetworkMode
    let ipv4Subnet: NetworkCIDR?
    let ipv6Subnet: NetworkCIDR?
    let labels: [NetworkKeyValue]
    let plugin: String?
    let customization: NetworkPluginCustomization

    init(
        name: String,
        mode: NetworkMode = .nat,
        ipv4Subnet: String? = nil,
        ipv6Subnet: String? = nil,
        labels: [NetworkKeyValue] = [],
        plugin: String? = nil,
        customization: NetworkPluginCustomization
    ) throws {
        self.name = try NetworkName(validating: name)
        self.mode = mode
        self.ipv4Subnet = try ipv4Subnet.map {
            try NetworkCIDR(validating: $0, family: .ipv4)
        }
        self.ipv6Subnet = try ipv6Subnet.map {
            try NetworkCIDR(validating: $0, family: .ipv6)
        }
        try Self.requireUniqueKeys(labels, field: "Network label")
        self.labels = labels

        if let plugin {
            guard !plugin.isEmpty,
                  plugin.first != "-",
                  plugin.unicodeScalars.allSatisfy({
                    $0.isASCII
                        && !CharacterSet.whitespacesAndNewlines.contains($0)
                        && !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw CommandValidationError.invalid(field: "Network plugin", value: plugin)
            }
        }
        self.plugin = plugin

        if case .options(let options) = customization {
            try Self.requireUniqueKeys(options, field: "Network plugin option")
        }
        if case .legacyVariant(let variant?) = customization,
           variant.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw CommandValidationError.invalid(field: "Network plugin variant", value: variant)
        }
        self.customization = customization
    }

    private static func requireUniqueKeys(
        _ values: [NetworkKeyValue],
        field: String
    ) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value.key).inserted {
            throw CommandValidationError.invalid(field: field, value: value.key)
        }
    }
}

nonisolated struct NetworkAttachment: Equatable, Sendable {
    let network: NetworkName
    let macAddress: String?
    let mtu: Int?

    init(network: String, macAddress: String? = nil, mtu: Int? = nil) throws {
        self.network = try NetworkName(validating: network)
        if let macAddress {
            guard macAddress.range(
                of: #"^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$"#,
                options: .regularExpression
            ) != nil else {
                throw CommandValidationError.invalid(field: "MAC address", value: macAddress)
            }
            self.macAddress = macAddress.uppercased()
        } else {
            self.macAddress = nil
        }
        if let mtu, !(1_280...65_535).contains(mtu) {
            throw CommandValidationError.outOfRange(field: "Network MTU", value: mtu)
        }
        self.mtu = mtu
    }

    var argument: String {
        var components = [network.rawValue]
        if let macAddress { components.append("mac=\(macAddress)") }
        if let mtu { components.append("mtu=\(mtu)") }
        return components.joined(separator: ",")
    }
}

nonisolated struct NetworkPluginInfoDTO: Decodable, Equatable, Sendable {
    let plugin: String?
    let variant: String?
}

nonisolated struct NetworkConfigurationDTO: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
    let mode: String?
    let creationDate: CLIDateValue?
    let ipv4Subnet: String?
    let ipv6Subnet: String?
    let labels: [String: String]?
    let pluginInfo: NetworkPluginInfoDTO?
    let plugin: String?
    let options: [String: String]?
}

nonisolated struct NetworkStatusDTO: Decodable, Equatable, Sendable {
    let ipv4Subnet: String?
    let ipv4Gateway: String?
    let ipv6Subnet: String?

    private enum CodingKeys: String, CodingKey {
        case ipv4Subnet
        case address
        case ipv4Gateway
        case gateway
        case ipv6Subnet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ipv4Subnet = try container.decodeIfPresent(String.self, forKey: .ipv4Subnet)
            ?? container.decodeIfPresent(String.self, forKey: .address)
        ipv4Gateway = try container.decodeIfPresent(String.self, forKey: .ipv4Gateway)
            ?? container.decodeIfPresent(String.self, forKey: .gateway)
        ipv6Subnet = try container.decodeIfPresent(String.self, forKey: .ipv6Subnet)
    }
}

nonisolated struct NetworkDTO: Decodable, Equatable, Sendable {
    let id: String?
    let state: String?
    let configuration: NetworkConfigurationDTO?
    let status: NetworkStatusDTO?

    private enum CodingKeys: String, CodingKey {
        case id
        case state
        case config
        case configuration
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        configuration = try container.decodeIfPresent(
            NetworkConfigurationDTO.self,
            forKey: .configuration
        ) ?? container.decodeIfPresent(NetworkConfigurationDTO.self, forKey: .config)
        status = try container.decodeIfPresent(NetworkStatusDTO.self, forKey: .status)
    }
}

nonisolated enum NetworkResourceState: String, Equatable, Sendable {
    case active
    case inactive
    case unknown

    init(reportedState: String?, hasStatus: Bool) {
        if let reportedState {
            switch reportedState.lowercased() {
            case "active", "running", "ready", "up": self = .active
            case "inactive", "stopped", "down": self = .inactive
            default: self = .unknown
            }
        } else {
            self = hasStatus ? .active : .unknown
        }
    }
}

nonisolated struct NetworkSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let state: NetworkResourceState
    let mode: String?
    let ipv4Subnet: String?
    let ipv6Subnet: String?
    let gateway: String?
    let plugin: String?
    let creationDate: Date?
    let isBuiltIn: Bool
    let labels: [String: String]
    let pluginOptions: [String: String]

    init?(dto: NetworkDTO) {
        guard let name = dto.configuration?.name
                ?? dto.configuration?.id
                ?? dto.id,
              !name.isEmpty else { return nil }
        id = dto.id?.isEmpty == false ? dto.id! : name
        self.name = name
        state = NetworkResourceState(reportedState: dto.state, hasStatus: dto.status != nil)
        mode = dto.configuration?.mode
        ipv4Subnet = dto.status?.ipv4Subnet ?? dto.configuration?.ipv4Subnet
        ipv6Subnet = dto.status?.ipv6Subnet ?? dto.configuration?.ipv6Subnet
        gateway = dto.status?.ipv4Gateway
        plugin = dto.configuration?.plugin ?? dto.configuration?.pluginInfo?.plugin
        creationDate = dto.configuration?.creationDate?.date
        labels = dto.configuration?.labels ?? [:]
        pluginOptions = dto.configuration?.options ?? [:]
        isBuiltIn = labels["com.apple.container.resource.role"] == "builtin" || name == "default"
    }
}

nonisolated struct NetworkInspection: Equatable, Sendable {
    let summary: NetworkSummary
    let configuredIPv4Subnet: String?
    let configuredIPv6Subnet: String?
    let legacyPluginVariant: String?
    let rawJSON: String

    init?(dto: NetworkDTO, rawJSON: String) {
        guard let summary = NetworkSummary(dto: dto) else { return nil }
        self.summary = summary
        configuredIPv4Subnet = dto.configuration?.ipv4Subnet
        configuredIPv6Subnet = dto.configuration?.ipv6Subnet
        legacyPluginVariant = dto.configuration?.pluginInfo?.variant
        self.rawJSON = rawJSON
    }
}
