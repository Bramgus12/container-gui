import Foundation

nonisolated struct VolumeName: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        guard !value.isEmpty else {
            throw CommandValidationError.empty(field: "Volume name")
        }
        guard value.count <= 128,
              value.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,127})$"#,
                options: .regularExpression
              ) != nil else {
            throw CommandValidationError.invalid(field: "Volume name", value: value)
        }
        rawValue = value
    }
}

nonisolated struct VolumeKeyValue: Hashable, Sendable {
    let key: String
    let value: String

    init(key: String, value: String) throws {
        guard !key.isEmpty else {
            throw CommandValidationError.empty(field: "Volume key")
        }
        guard !key.unicodeScalars.contains(where: {
            $0 == "=" || CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }), !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        })
        else {
            throw CommandValidationError.invalid(field: "Volume option", value: key)
        }
        self.key = key
        self.value = value
    }

    var argument: String { "\(key)=\(value)" }
}

nonisolated struct VolumeSize: Equatable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        guard value.range(
            of: #"^[1-9][0-9]*(?:[KMGTPEkmgtpe](?:[Bb])?)?$"#,
            options: .regularExpression
        ) != nil else {
            throw CommandValidationError.invalid(field: "Volume size", value: value)
        }
        rawValue = value
    }
}

nonisolated struct VolumeCreateConfiguration: Equatable, Sendable {
    let name: VolumeName
    let labels: [VolumeKeyValue]
    let options: [VolumeKeyValue]
    let size: VolumeSize?

    init(
        name: String,
        labels: [VolumeKeyValue] = [],
        options: [VolumeKeyValue] = [],
        size: String? = nil
    ) throws {
        self.name = try VolumeName(validating: name)
        try Self.requireUniqueKeys(labels, field: "Volume label")
        try Self.requireUniqueKeys(options, field: "Volume option")
        self.labels = labels
        self.options = options
        self.size = try size.map(VolumeSize.init(validating:))
    }

    private static func requireUniqueKeys(
        _ values: [VolumeKeyValue],
        field: String
    ) throws {
        var keys = Set<String>()
        for value in values where !keys.insert(value.key).inserted {
            throw CommandValidationError.invalid(field: field, value: value.key)
        }
    }
}

nonisolated struct VolumeConfigurationDTO: Decodable, Equatable, Sendable {
    let creationDate: CLIDateValue?
    let driver: String?
    let format: String?
    let labels: [String: String]?
    let name: String?
    let options: [String: String]?
    let sizeInBytes: UInt64?
    let source: String?

    private enum CodingKeys: String, CodingKey {
        case creationDate
        case createdAt
        case driver
        case format
        case labels
        case name
        case id
        case options
        case sizeInBytes
        case size
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        creationDate = try container.decodeIfPresent(CLIDateValue.self, forKey: .creationDate)
            ?? container.decodeIfPresent(CLIDateValue.self, forKey: .createdAt)
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        options = try container.decodeIfPresent([String: String].self, forKey: .options)
        sizeInBytes = try container.decodeFlexibleUInt64(forKeys: [.sizeInBytes, .size])
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}

nonisolated struct VolumeDTO: Decodable, Equatable, Sendable {
    let id: String?
    let configuration: VolumeConfigurationDTO?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case config
        case configuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .name)
        configuration = try container.decodeIfPresent(
            VolumeConfigurationDTO.self,
            forKey: .configuration
        ) ?? container.decodeIfPresent(VolumeConfigurationDTO.self, forKey: .config)
    }
}

nonisolated struct VolumeSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let driver: String?
    let format: String?
    let creationDate: Date?
    let sizeInBytes: UInt64?
    let source: String?
    let labels: [String: String]
    let options: [String: String]
    let isAnonymous: Bool

    init?(dto: VolumeDTO) {
        guard let name = dto.configuration?.name ?? dto.id, !name.isEmpty else { return nil }
        id = dto.id?.isEmpty == false ? dto.id! : name
        self.name = name
        driver = dto.configuration?.driver
        format = dto.configuration?.format
        creationDate = dto.configuration?.creationDate?.date
        sizeInBytes = dto.configuration?.sizeInBytes
        source = dto.configuration?.source
        labels = dto.configuration?.labels ?? [:]
        options = dto.configuration?.options ?? [:]
        isAnonymous = labels["com.apple.container.resource.anonymous"] != nil
    }
}

nonisolated struct VolumeInspection: Equatable, Sendable {
    let summary: VolumeSummary
    let rawJSON: String

    init?(dto: VolumeDTO, rawJSON: String) {
        guard let summary = VolumeSummary(dto: dto) else { return nil }
        self.summary = summary
        self.rawJSON = rawJSON
    }
}

private extension KeyedDecodingContainer {
    nonisolated func decodeFlexibleUInt64(forKeys keys: [Key]) throws -> UInt64? {
        for key in keys {
            if let value = try? decode(UInt64.self, forKey: key) {
                return value
            }
            if let value = try? decode(String.self, forKey: key),
               let parsed = UInt64(value) {
                return parsed
            }
        }
        return nil
    }
}
