import Foundation

nonisolated struct ImageDTO: Decodable, Equatable, Sendable {
    let reference: String?
    let name: String?
    let digest: String?
    let size: UInt64?
    let createdAt: CLIDateValue?
    let platform: PlatformDTO?
    let descriptor: ImageDescriptorDTO?
    let index: ImageDescriptorDTO?
    let configuration: ImageConfigurationDTO?
    let variants: [ImageVariantDTO]?

    private enum CodingKeys: String, CodingKey {
        case reference
        case name
        case digest
        case size
        case createdAt
        case creationDate
        case platform
        case descriptor
        case index
        case configuration
        case variants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
        size = try container.decodeIfPresent(UInt64.self, forKey: .size)
        createdAt = try container.decodeIfPresent(CLIDateValue.self, forKey: .createdAt)
            ?? container.decodeIfPresent(CLIDateValue.self, forKey: .creationDate)
        platform = try container.decodeIfPresent(PlatformDTO.self, forKey: .platform)
        descriptor = try container.decodeIfPresent(ImageDescriptorDTO.self, forKey: .descriptor)
        index = try container.decodeIfPresent(ImageDescriptorDTO.self, forKey: .index)
        configuration = try container.decodeIfPresent(ImageConfigurationDTO.self, forKey: .configuration)
        variants = try container.decodeIfPresent([ImageVariantDTO].self, forKey: .variants)
    }

    var containsInspectionData: Bool {
        reference?.isEmpty == false
            || name?.isEmpty == false
            || configuration?.reference?.isEmpty == false
            || configuration?.name?.isEmpty == false
            || descriptor?.containsData == true
            || index?.containsData == true
            || variants?.contains(where: \.containsData) == true
    }
}

nonisolated struct ImageConfigurationDTO: Decodable, Equatable, Sendable {
    let reference: String?
    let name: String?
    let descriptor: ImageDescriptorDTO?
    let createdAt: CLIDateValue?
    let creationDate: CLIDateValue?
}

nonisolated struct ImageDescriptorDTO: Decodable, Equatable, Sendable {
    let digest: String?
    let size: UInt64?
    let mediaType: String?
    let urls: [String]?
    let annotations: [String: String]?
    let platform: PlatformDTO?
    let artifactType: String?

    var containsData: Bool {
        digest?.isEmpty == false || mediaType?.isEmpty == false || size != nil
    }
}

nonisolated struct ImageVariantDTO: Decodable, Equatable, Sendable {
    let digest: String?
    let size: UInt64?
    let platform: PlatformDTO?
    let config: OCIImageDTO?

    var containsData: Bool {
        digest?.isEmpty == false || size != nil || platform != nil || config != nil
    }
}

nonisolated struct OCIImageDTO: Decodable, Equatable, Sendable {
    let created: String?
    let author: String?
    let architecture: String?
    let os: String?
    let osVersion: String?
    let osFeatures: [String]?
    let variant: String?
    let config: OCIImageConfigurationDTO?
    let rootfs: OCIRootFSDTO?
    let history: [OCIHistoryDTO]?
}

nonisolated struct OCIImageConfigurationDTO: Decodable, Equatable, Sendable {
    let user: String?
    let environment: [String]?
    let entrypoint: [String]?
    let command: [String]?
    let workingDirectory: String?
    let labels: [String: String]?
    let stopSignal: String?

    private enum CodingKeys: String, CodingKey {
        case user = "User"
        case environment = "Env"
        case entrypoint = "Entrypoint"
        case command = "Cmd"
        case workingDirectory = "WorkingDir"
        case labels = "Labels"
        case stopSignal = "StopSignal"
    }
}

nonisolated struct OCIRootFSDTO: Decodable, Equatable, Sendable {
    let type: String?
    let diffIDs: [String]?

    private enum CodingKeys: String, CodingKey {
        case type
        case diffIDs = "diff_ids"
    }
}

nonisolated struct OCIHistoryDTO: Decodable, Equatable, Sendable {
    let created: String?
    let createdBy: String?
    let author: String?
    let comment: String?
    let emptyLayer: Bool?

    private enum CodingKeys: String, CodingKey {
        case created
        case createdBy = "created_by"
        case author
        case comment
        case emptyLayer = "empty_layer"
    }
}

nonisolated struct ImageSummary: Identifiable, Equatable, Sendable {
    var id: String {
        reference
    }

    let reference: String
    let digest: String?
    let size: UInt64?
    let createdAt: Date?
    let operatingSystem: String?
    let architecture: String?

    init?(dto: ImageDTO) {
        let configuration = dto.configuration
        guard let reference = dto.reference ?? dto.name ?? configuration?.reference ?? configuration?.name,
              !reference.isEmpty else {
            return nil
        }

        let descriptor = dto.descriptor ?? dto.index ?? configuration?.descriptor
        let platform = dto.platform ?? dto.variants?.first { variant in
            variant.platform?.os != "unknown" && variant.platform?.architecture != "unknown"
        }?.platform

        self.reference = reference
        digest = dto.digest ?? descriptor?.digest
        size = dto.size ?? descriptor?.size
        createdAt = (dto.createdAt ?? configuration?.createdAt ?? configuration?.creationDate)?.date
        operatingSystem = platform?.os
        architecture = platform?.architecture
    }
}

nonisolated struct ImageDeletionPlan: Identifiable, Equatable, Sendable {
    var id: String { image.id }

    let image: ImageSummary
    let dependentContainers: [ContainerSummary]
    let unresolvedContainers: [ContainerSummary]

    var hasStableIdentity: Bool { image.digest != nil }

    var blockedContainers: [ContainerSummary] {
        dependentContainers.filter { container in
            if image.digest != nil && container.imageDigest == nil {
                return true
            }
            switch container.state {
            case .created, .running, .stopped, .paused:
                return false
            case .unknown:
                return true
            }
        }
    }
}

nonisolated struct ImageInspection: Equatable, Sendable {
    let reference: String
    let descriptor: ImageDescriptorDTO?
    let createdAt: Date?
    let variants: [ImageInspectionVariant]
    let rawJSON: String

    init?(dto: ImageDTO, fallbackReference: String, rawJSON: String) {
        let configuration = dto.configuration
        let reference = dto.reference ?? dto.name ?? configuration?.reference ?? configuration?.name
            ?? fallbackReference
        guard !reference.isEmpty else { return nil }

        self.reference = reference
        descriptor = dto.descriptor ?? dto.index ?? configuration?.descriptor
        createdAt = (dto.createdAt ?? configuration?.createdAt ?? configuration?.creationDate)?.date
        variants = (dto.variants ?? []).enumerated().map { offset, variant in
            ImageInspectionVariant(dto: variant, offset: offset)
        }
        self.rawJSON = rawJSON
    }
}

nonisolated struct ImageInspectionVariant: Identifiable, Equatable, Sendable {
    let id: String
    let digest: String?
    let size: UInt64?
    let platform: PlatformDTO?
    let createdAt: Date?
    let author: String?
    let operatingSystem: String?
    let architecture: String?
    let osVersion: String?
    let osFeatures: [String]
    let variant: String?
    let configuration: OCIImageConfigurationDTO?
    let rootFS: OCIRootFSDTO?
    let layers: [ImageLayerDigest]
    let history: [ImageHistoryEntry]

    init(dto: ImageVariantDTO, offset: Int) {
        id = "\(dto.digest ?? "\(dto.platform?.os ?? "unknown")-\(dto.platform?.architecture ?? "unknown")")-\(offset)"
        digest = dto.digest
        size = dto.size
        platform = dto.platform
        createdAt = parseImageDate(dto.config?.created)
        author = dto.config?.author
        operatingSystem = dto.config?.os ?? dto.platform?.os
        architecture = dto.config?.architecture ?? dto.platform?.architecture
        osVersion = dto.config?.osVersion
        osFeatures = dto.config?.osFeatures ?? []
        variant = dto.config?.variant ?? dto.platform?.variant
        configuration = dto.config?.config
        rootFS = dto.config?.rootfs
        var occurrences: [String: Int] = [:]
        layers = (dto.config?.rootfs?.diffIDs ?? []).map { digest in
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            return ImageLayerDigest(id: "\(digest)-\(occurrence)", digest: digest)
        }
        history = (dto.config?.history ?? []).enumerated().map { offset, item in
            ImageHistoryEntry(dto: item, offset: offset)
        }
    }
}

nonisolated struct ImageLayerDigest: Identifiable, Equatable, Sendable {
    let id: String
    let digest: String
}

nonisolated struct ImageHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let createdAt: Date?
    let createdBy: String?
    let author: String?
    let comment: String?
    let emptyLayer: Bool

    init(dto: OCIHistoryDTO, offset: Int) {
        id = "\(offset)-\(dto.created ?? "")-\(dto.createdBy ?? "")"
        createdAt = parseImageDate(dto.created)
        createdBy = dto.createdBy
        author = dto.author
        comment = dto.comment
        emptyLayer = dto.emptyLayer ?? false
    }
}

nonisolated func parseImageDate(_ value: String?) -> Date? {
    guard let value else {
        return nil
    }
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
        return date
    }
    return try? Date.ISO8601FormatStyle().parse(value)
}
