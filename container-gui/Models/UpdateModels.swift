import Foundation

nonisolated enum AppVersion {
    static let current: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }()

    static func semantic(_ value: String = current) -> SemanticVersion? {
        try? SemanticVersion(value)
    }
}

nonisolated enum AppDistribution {
    static let repository = "Bramgus12/container-gui"

    static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!

    static let releasesURL = URL(
        string: "https://github.com/\(repository)/releases"
    )!

    /// The command documented in the README. Re-running it upgrades in place.
    static let installCommand = """
    curl -fsSL https://raw.githubusercontent.com/\(repository)/main/scripts/install.sh | bash
    """
}

nonisolated struct AppRelease: Equatable, Sendable {
    /// Release notes are bounded like every other piece of untrusted output the
    /// app displays.
    static let maximumNotesLength = 4_000

    let version: SemanticVersion
    let tag: String
    let name: String
    let notes: String
    let pageURL: URL
    let publishedAt: Date?

    init(
        version: SemanticVersion,
        tag: String,
        name: String,
        notes: String,
        pageURL: URL,
        publishedAt: Date?
    ) {
        self.version = version
        self.tag = tag
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
    }

    init(dto: GitHubReleaseDTO) throws {
        let tag = dto.tagName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !tag.isEmpty else {
            throw UpdateCheckError.invalidRelease(reason: "The release has no tag.")
        }

        var core = tag
        if core.hasPrefix("v") || core.hasPrefix("V") {
            core.removeFirst()
        }

        do {
            version = try SemanticVersion(core)
        } catch {
            throw UpdateCheckError.invalidRelease(
                reason: "The release tag \(tag) is not a version number."
            )
        }

        self.tag = tag
        let trimmedName = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = trimmedName.isEmpty ? tag : trimmedName
        notes = Self.boundedNotes(dto.body ?? "")
        pageURL = dto.htmlURL.flatMap(URL.init(string:))
            ?? AppDistribution.releasesURL
        publishedAt = dto.publishedAt.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
    }

    static func boundedNotes(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumNotesLength else { return trimmed }
        return String(trimmed.prefix(maximumNotesLength)) + "\n…"
    }
}

/// Decoded tolerantly: GitHub adds fields over time, and only the tag is
/// required for the app to make a decision.
nonisolated struct GitHubReleaseDTO: Decodable, Equatable, Sendable {
    let tagName: String?
    let name: String?
    let body: String?
    let htmlURL: String?
    let publishedAt: String?

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

nonisolated enum UpdateCheckError: Error, Equatable, Sendable {
    case rateLimited
    case notFound
    case unreachable(reason: String)
    case invalidResponse(status: Int)
    case invalidRelease(reason: String)
}

extension UpdateCheckError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .rateLimited:
            "GitHub is rate-limiting update checks. Try again later."
        case .notFound:
            "No published release was found."
        case .unreachable(let reason):
            "The update check could not reach GitHub: \(reason)"
        case .invalidResponse(let status):
            "GitHub returned an unexpected response (HTTP \(status))."
        case .invalidRelease(let reason):
            "The latest release could not be read. \(reason)"
        }
    }
}
