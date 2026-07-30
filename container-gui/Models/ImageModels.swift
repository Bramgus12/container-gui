import Foundation

nonisolated struct ImageDTO: Decodable, Equatable, Sendable {
    let reference: String?
    let name: String?
    let digest: String?
    let size: UInt64?
    let createdAt: String?
    let platform: PlatformDTO?
    let descriptor: ImageDescriptorDTO?

    private enum CodingKeys: String, CodingKey {
        case reference
        case name
        case digest
        case size
        case createdAt
        case creationDate
        case platform
        case descriptor
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
    }
}

nonisolated struct ImageDescriptorDTO: Decodable, Equatable, Sendable {
    let digest: String?
    let size: UInt64?
    let mediaType: String?
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
        guard let reference = dto.reference ?? dto.name, !reference.isEmpty else {
            return nil
        }
        self.reference = reference
        digest = dto.digest ?? dto.descriptor?.digest
        size = dto.size ?? dto.descriptor?.size
        if let value = dto.createdAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdAt = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        } else {
            createdAt = nil
        }
        operatingSystem = dto.platform?.os
        architecture = dto.platform?.architecture
    }
}
