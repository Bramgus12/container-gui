import Foundation

nonisolated struct ImageDTO: Decodable, Equatable, Sendable {
    let reference: String?
    let name: String?
    let digest: String?
    let size: UInt64?
    let createdAt: String?
    let platform: PlatformDTO?
    let descriptor: ImageDescriptorDTO?
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
        case configuration
        case variants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
        size = try container.decodeIfPresent(UInt64.self, forKey: .size)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? container.decodeIfPresent(String.self, forKey: .creationDate)
        platform = try container.decodeIfPresent(PlatformDTO.self, forKey: .platform)
        descriptor = try container.decodeIfPresent(ImageDescriptorDTO.self, forKey: .descriptor)
        configuration = try container.decodeIfPresent(ImageConfigurationDTO.self, forKey: .configuration)
        variants = try container.decodeIfPresent([ImageVariantDTO].self, forKey: .variants)
    }
}

nonisolated struct ImageConfigurationDTO: Decodable, Equatable, Sendable {
    let reference: String?
    let name: String?
    let descriptor: ImageDescriptorDTO?
    let createdAt: String?
    let creationDate: String?
}

nonisolated struct ImageDescriptorDTO: Decodable, Equatable, Sendable {
    let digest: String?
    let size: UInt64?
    let mediaType: String?
}

nonisolated struct ImageVariantDTO: Decodable, Equatable, Sendable {
    let digest: String?
    let size: UInt64?
    let platform: PlatformDTO?
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

        let descriptor = dto.descriptor ?? configuration?.descriptor
        let platform = dto.platform ?? dto.variants?.first { variant in
            variant.platform?.os != "unknown" && variant.platform?.architecture != "unknown"
        }?.platform

        self.reference = reference
        digest = dto.digest ?? descriptor?.digest
        size = dto.size ?? descriptor?.size
        createdAt = parseImageDate(dto.createdAt ?? configuration?.createdAt ?? configuration?.creationDate)
        operatingSystem = platform?.os
        architecture = platform?.architecture
    }
}

nonisolated private func parseImageDate(_ value: String?) -> Date? {
    guard let value else {
        return nil
    }
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
        return date
    }
    return try? Date.ISO8601FormatStyle().parse(value)
}
