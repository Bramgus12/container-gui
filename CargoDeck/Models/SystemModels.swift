import Foundation

nonisolated struct SystemStatusDTO: Decodable, Equatable, Sendable {
    let status: String?
    let healthy: Bool?
    let version: String?
    let message: String?
}

nonisolated struct SystemStatus: Equatable, Sendable {
    let isRunning: Bool
    let version: String?
    let message: String?

    init(dto: SystemStatusDTO) {
        isRunning = dto.healthy ?? ["running", "healthy", "ready"].contains(dto.status?.lowercased())
        version = dto.version
        message = dto.message
    }
}

nonisolated struct SystemVersionDTO: Decodable, Equatable, Sendable {
    let appName: String
    let version: String
    let buildType: String?
    let commit: String?
}

nonisolated struct SystemVersion: Equatable, Sendable {
    let cli: SystemVersionDTO?
    let server: SystemVersionDTO?

    init(components: [SystemVersionDTO]) {
        cli = components.first { $0.appName == "container" }
        server = components.first { $0.appName == "container-apiserver" }
    }
}

/// The `container system property list` payload: an open-ended map of section
/// names to the values the service was configured with. The CLI has grown
/// sections over time — 1.3.0 emits build, container, dns, kernel, machine,
/// network, registry, and vminit — so this decodes whatever it is handed rather
/// than a fixed shape, and keeps every value as the string the CLI printed.
nonisolated struct SystemProperties: Equatable, Sendable {
    nonisolated struct Section: Identifiable, Equatable, Sendable {
        /// The CLI's own section name, such as `vminit`.
        let name: String
        /// The CLI's own keys, such as `homeMount`, and their printed values.
        let values: [String: String]

        var id: String { name }

        var displayName: String {
            Self.displayNames[name] ?? name.capitalized
        }

        private static let displayNames = [
            "build": "Builder defaults",
            "container": "Container defaults",
            "dns": "DNS",
            "kernel": "Kernel",
            "machine": "Machine",
            "network": "Network",
            "other": "Other",
            "registry": "Registry",
            "vminit": "VM init",
        ]
    }

    let sections: [Section]

    /// The sections the CLI is known to emit, in the order they read best: the
    /// virtual machine first, then what it runs, then where images come from.
    /// Anything the CLI adds later is appended alphabetically.
    private static let preferredOrder = [
        "machine",
        "container",
        "build",
        "kernel",
        "vminit",
        "registry",
        "network",
        "dns",
    ]

    static func decode(from data: Data) throws -> SystemProperties {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.invalidOutput(
                description: "System properties were not a JSON object."
            )
        }

        var sections: [Section] = []
        var loose: [String: String] = [:]
        for (name, value) in object {
            if let nested = value as? [String: Any] {
                sections.append(Section(name: name, values: flatten(nested)))
            } else if let scalar = string(from: value) {
                loose[name] = scalar
            }
        }
        if !loose.isEmpty {
            sections.append(Section(name: "other", values: loose))
        }

        return SystemProperties(sections: sections.sorted { left, right in
            let leftRank = preferredOrder.firstIndex(of: left.name) ?? preferredOrder.count
            let rightRank = preferredOrder.firstIndex(of: right.name) ?? preferredOrder.count
            if leftRank != rightRank { return leftRank < rightRank }
            return left.name < right.name
        })
    }

    func value(section: String, key: String) -> String? {
        sections.first { $0.name == section }?.values[key]
    }

    var dnsDomain: String? {
        value(section: "dns", key: "domain")
    }

    /// Nested objects become dotted keys, so a future section that groups its
    /// values still renders as a flat list.
    private static func flatten(
        _ object: [String: Any],
        prefix: String = ""
    ) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in object {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                values.merge(flatten(nested, prefix: path)) { current, _ in current }
            } else if let scalar = string(from: value) {
                values[path] = scalar
            }
        }
        return values
    }

    private static func string(from value: Any) -> String? {
        // JSON booleans arrive as NSNumber, so they have to be recognised before
        // the number case or `false` renders as `0`.
        if let number = value as? NSNumber,
           CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        switch value {
        case let string as String:
            return string
        // `stringValue` keeps whole numbers whole: `2` rather than `2.0`.
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return array.compactMap { string(from: $0) }.joined(separator: ", ")
        default:
            return nil
        }
    }
}

nonisolated struct ContainerStatsDTO: Decodable, Equatable, Sendable {
    let id: String
    let memoryUsageBytes: UInt64?
    let memoryLimitBytes: UInt64?
    let cpuUsageUsec: UInt64?
    let networkRxBytes: UInt64?
    let networkTxBytes: UInt64?
    let blockReadBytes: UInt64?
    let blockWriteBytes: UInt64?
    let numProcesses: Int?
}

nonisolated struct ContainerStats: Identifiable, Equatable, Sendable {
    let id: String
    let memoryUsageBytes: UInt64?
    let memoryLimitBytes: UInt64?
    let cpuUsageMicroseconds: UInt64?
    let networkReceivedBytes: UInt64?
    let networkTransmittedBytes: UInt64?
    let blockReadBytes: UInt64?
    let blockWrittenBytes: UInt64?
    let processCount: Int?

    init(dto: ContainerStatsDTO) {
        id = dto.id
        memoryUsageBytes = dto.memoryUsageBytes
        memoryLimitBytes = dto.memoryLimitBytes
        cpuUsageMicroseconds = dto.cpuUsageUsec
        networkReceivedBytes = dto.networkRxBytes
        networkTransmittedBytes = dto.networkTxBytes
        blockReadBytes = dto.blockReadBytes
        blockWrittenBytes = dto.blockWriteBytes
        processCount = dto.numProcesses
    }
}

nonisolated struct SystemDiskUsageDTO: Equatable, Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case type(String)
        case anonymous(
            totalCount: Int?,
            activeCount: Int?,
            sizeBytes: UInt64?,
            reclaimableBytes: UInt64?
        )
    }

    let type: String?
    let totalCount: Int?
    let activeCount: Int?
    let sizeBytes: UInt64?
    let reclaimableBytes: UInt64?

    var id: ID {
        if let type {
            return .type(type)
        }
        return .anonymous(
            totalCount: totalCount,
            activeCount: activeCount,
            sizeBytes: sizeBytes,
            reclaimableBytes: reclaimableBytes
        )
    }
}

nonisolated struct SystemDiskUsage: Equatable, Sendable {
    let resources: [SystemDiskUsageDTO]

    static func decode(from data: Data) throws -> SystemDiskUsage {
        let value = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]

        if let array = value as? [[String: Any]] {
            rows = array
        } else if let object = value as? [String: Any] {
            if let nested = ["resources", "usage", "diskUsage"]
                .compactMap({ object[$0] as? [[String: Any]] })
                .first {
                rows = nested
            } else {
                rows = object.compactMap { key, value in
                    guard var row = value as? [String: Any] else { return nil }
                    if Self.value(in: row, keys: ["type", "resource", "category"]) == nil {
                        row["type"] = key
                    }
                    return row
                }
            }
        } else {
            throw CLIError.invalidOutput(
                description: "System disk usage was not a JSON object or array."
            )
        }

        let resources = rows.map { row in
            SystemDiskUsageDTO(
                type: Self.string(in: row, keys: ["type", "resource", "category"]),
                totalCount: Self.integer(in: row, keys: ["totalCount", "total", "count"]),
                activeCount: Self.integer(in: row, keys: ["activeCount", "active"]),
                // `container system df --format json` emits `sizeInBytes`; the
                // other spellings are kept for older and future CLI versions.
                sizeBytes: Self.unsignedInteger(
                    in: row,
                    keys: ["sizeInBytes", "sizeBytes", "size", "totalSize"]
                ),
                reclaimableBytes: Self.unsignedInteger(
                    in: row,
                    keys: [
                        "reclaimableInBytes",
                        "reclaimableBytes",
                        "reclaimable",
                        "reclaimableSize",
                    ]
                )
            )
        }
        guard !resources.isEmpty else {
            throw CLIError.invalidOutput(
                description: "System disk usage contained no resource rows."
            )
        }
        return SystemDiskUsage(resources: resources)
    }

    private static func value(in row: [String: Any], keys: [String]) -> Any? {
        var normalized: [String: Any] = [:]
        for (key, value) in row {
            let normalizedKey = key.lowercased().filter(\.isLetter)
            if normalized[normalizedKey] == nil {
                normalized[normalizedKey] = value
            }
        }
        return keys.compactMap {
            normalized[$0.lowercased().filter(\.isLetter)]
        }.first
    }

    private static func string(in row: [String: Any], keys: [String]) -> String? {
        if let value = value(in: row, keys: keys) as? String {
            return value
        }
        return nil
    }

    private static func integer(in row: [String: Any], keys: [String]) -> Int? {
        guard let value = value(in: row, keys: keys) else { return nil }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func unsignedInteger(
        in row: [String: Any],
        keys: [String]
    ) -> UInt64? {
        guard let value = value(in: row, keys: keys) else { return nil }
        if let number = value as? NSNumber, number.int64Value >= 0 {
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return nil
    }
}

extension SystemDiskUsage {
    var totalSizeBytes: UInt64 {
        resources.compactMap(\.sizeBytes).reduce(0, &+)
    }

    var totalReclaimableBytes: UInt64 {
        resources.compactMap(\.reclaimableBytes).reduce(0, &+)
    }

    func resource(named name: String) -> SystemDiskUsageDTO? {
        resources.first { $0.type?.localizedCaseInsensitiveContains(name) == true }
    }
}
