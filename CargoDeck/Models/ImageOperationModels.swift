import Foundation

// MARK: - Transport

/// The transport `--scheme` selects when the CLI talks to a registry.
///
/// `auto` deliberately emits **no flag at all**. The value vocabulary moved
/// between supported releases: 0.12.0 and 1.0.0 accept `http`, `https` and
/// `auto` and default to `auto`, while 1.3.1 accepts only `http` and `https`
/// and defaults to `https`. Emitting `--scheme auto` therefore fails outright on
/// current releases. Omitting the flag means "whatever this CLI defaults to",
/// which is valid on every supported release and is what the GUI's automatic
/// choice actually means.
nonisolated enum RegistryScheme: String, CaseIterable, Equatable, Sendable {
    case auto
    case https
    case http

    var arguments: [String] {
        switch self {
        case .auto: []
        case .https: ["--scheme", "https"]
        case .http: ["--scheme", "http"]
        }
    }

    /// Explicit HTTP sends credentials and layers over an unencrypted
    /// connection, so the sheets that offer it have to say so.
    var isUnencrypted: Bool { self == .http }
}

// MARK: - Platform selection

/// The `--platform` / `--os` / `--arch` trio the transfer commands share.
///
/// The CLI documents `--platform` as taking precedence over `--os` and `--arch`.
/// Rather than emit all three and rely on that, this type holds the invariant in
/// one place: a filled platform emits only `--platform`, and OS/architecture are
/// emitted only when platform is empty.
nonisolated struct ImagePlatformSelection: Equatable, Sendable {
    let platform: BuildPlatform?
    let operatingSystem: String?
    let architecture: String?

    static let none = ImagePlatformSelection()

    private init() {
        platform = nil
        operatingSystem = nil
        architecture = nil
    }

    /// Blank fields are normalized to `nil` here so the sheets can hand over raw
    /// text-field contents without each one repeating the same emptiness check.
    init(
        platform: String? = nil,
        operatingSystem: String? = nil,
        architecture: String? = nil
    ) throws {
        self.platform = try Self.normalized(platform).map {
            try BuildPlatform(validating: $0, field: "Image platform")
        }
        self.operatingSystem = try Self.normalized(operatingSystem).map {
            try BuildConfiguration.validatedToken($0, field: "Image OS")
        }
        self.architecture = try Self.normalized(architecture).map {
            try BuildConfiguration.validatedToken($0, field: "Image architecture")
        }
    }

    var isEmpty: Bool {
        platform == nil && operatingSystem == nil && architecture == nil
    }

    /// The number of controls the user actually set, for the sheet rails' badges.
    var setValueCount: Int {
        if platform != nil { return 1 }
        return [operatingSystem, architecture].compactMap { $0 }.count
    }

    var arguments: [String] {
        if let platform {
            return ["--platform", platform.rawValue]
        }
        var result: [String] = []
        if let operatingSystem { result += ["--os", operatingSystem] }
        if let architecture { result += ["--arch", architecture] }
        return result
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Capabilities

/// Version-derived support for the option surfaces that differ across supported
/// releases, resolved once from the preflight context so no view has to test a
/// version number itself.
nonisolated struct ImageCapabilities: Equatable, Sendable {
    /// `--max-concurrent-downloads` arrived in Apple Container 1.0.0. The 0.12
    /// pull surface has no such flag, and passing it there is a hard failure.
    static let concurrentDownloadsMinimumVersion = SemanticVersion(major: 1, minor: 0, patch: 0)

    let supportsConcurrentDownloadLimit: Bool

    init(version: SemanticVersion) {
        supportsConcurrentDownloadLimit = version >= Self.concurrentDownloadsMinimumVersion
    }

    init(supportsConcurrentDownloadLimit: Bool) {
        self.supportsConcurrentDownloadLimit = supportsConcurrentDownloadLimit
    }
}

// MARK: - Transfer configurations

nonisolated struct ImagePullConfiguration: Equatable, Sendable {
    let reference: ImageReference
    let scheme: RegistryScheme
    let platform: ImagePlatformSelection
    /// `nil` leaves the CLI's own default in place. A value is only ever set
    /// when ``ImageCapabilities/supportsConcurrentDownloadLimit`` is true.
    let maximumConcurrentDownloads: Int?

    init(
        reference: String,
        scheme: RegistryScheme = .auto,
        platform: ImagePlatformSelection = .none,
        maximumConcurrentDownloads: Int? = nil
    ) throws {
        self.reference = try ImageReference(validating: reference)
        self.scheme = scheme
        self.platform = platform
        if let maximumConcurrentDownloads, maximumConcurrentDownloads <= 0 {
            throw CommandValidationError.nonPositive(field: "Maximum concurrent downloads")
        }
        self.maximumConcurrentDownloads = maximumConcurrentDownloads
    }

    var arguments: [String] {
        ["image", "pull"]
            + scheme.arguments
            + ["--progress", "plain"]
            + (maximumConcurrentDownloads.map { ["--max-concurrent-downloads", String($0)] } ?? [])
            + platform.arguments
            + [reference.rawValue]
    }
}

nonisolated struct ImagePushConfiguration: Equatable, Sendable {
    let reference: ImageReference
    let scheme: RegistryScheme
    let platform: ImagePlatformSelection

    init(
        reference: String,
        scheme: RegistryScheme = .auto,
        platform: ImagePlatformSelection = .none
    ) throws {
        self.reference = try ImageReference(validating: reference)
        self.scheme = scheme
        self.platform = platform
    }

    var arguments: [String] {
        ["image", "push"]
            + scheme.arguments
            + ["--progress", "plain"]
            + platform.arguments
            + [reference.rawValue]
    }
}

nonisolated struct ImageTagConfiguration: Equatable, Sendable {
    let source: ImageReference
    let target: ImageReference

    init(source: String, target: String) throws {
        self.source = try ImageReference(validating: source)
        self.target = try ImageReference(validating: target)
        guard self.source != self.target else {
            throw CommandValidationError.invalid(field: "Target reference", value: target)
        }
    }

    var arguments: [String] {
        ["image", "tag", source.rawValue, target.rawValue]
    }
}

nonisolated struct ImageSaveConfiguration: Equatable, Sendable {
    let references: [ImageReference]
    let output: LocalPath
    let platform: ImagePlatformSelection

    /// Duplicates are dropped rather than rejected: the checklist and the
    /// selected row can name the same image, and asking the CLI to save it twice
    /// is not something the user meant.
    init(
        references: [String],
        output: String,
        platform: ImagePlatformSelection = .none
    ) throws {
        var seen = Set<String>()
        var validated: [ImageReference] = []
        for value in references {
            let reference = try ImageReference(validating: value)
            guard seen.insert(reference.rawValue).inserted else { continue }
            validated.append(reference)
        }
        guard !validated.isEmpty else {
            throw CommandValidationError.empty(field: "Image references")
        }
        self.references = validated
        self.output = try LocalPath(validating: output, field: "Archive path")
        self.platform = platform
    }

    var arguments: [String] {
        ["image", "save"]
            + platform.arguments
            + ["--output", output.rawValue]
            + references.map(\.rawValue)
    }
}

nonisolated struct ImageLoadConfiguration: Equatable, Sendable {
    let input: LocalPath
    /// The CLI's own wording: force loads archives that contain invalid member
    /// files. It does not bypass every import failure, and the sheet says so.
    let force: Bool

    init(input: String, force: Bool = false) throws {
        self.input = try LocalPath(validating: input, field: "Archive path")
        self.force = force
    }

    var arguments: [String] {
        ["image", "load", "--input", input.rawValue] + (force ? ["--force"] : [])
    }
}

/// Either a non-empty de-duplicated list of images, or every image — never both,
/// and never neither. The scope a destructive command runs with is exactly the
/// scope the confirmation showed, so it is settled at construction.
nonisolated struct ImageDeleteConfiguration: Equatable, Sendable {
    let references: [ImageReference]
    let all: Bool
    /// The CLI's narrow meaning: ignore errors for images that are not found.
    /// It does **not** force-remove an image a container still uses.
    let force: Bool

    init(references: [String] = [], all: Bool = false, force: Bool = false) throws {
        var seen = Set<String>()
        var validated: [ImageReference] = []
        for value in references {
            let reference = try ImageReference(validating: value)
            guard seen.insert(reference.rawValue).inserted else { continue }
            validated.append(reference)
        }

        if all {
            guard validated.isEmpty else {
                throw CommandValidationError.invalid(
                    field: "Image delete scope",
                    value: "--all with named images"
                )
            }
        } else {
            guard !validated.isEmpty else {
                throw CommandValidationError.empty(field: "Image references")
            }
        }

        self.references = validated
        self.all = all
        self.force = force
    }

    var arguments: [String] {
        ["image", "delete"]
            + (all ? ["--all"] : [])
            + (force ? ["--force"] : [])
            + references.map(\.rawValue)
    }
}
