import Foundation

nonisolated struct BuildKeyValue: Hashable, Sendable {
    let key: String
    let value: String

    init(key: String, value: String) throws {
        guard key.range(
            of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#,
            options: .regularExpression
        ) != nil else {
            throw CommandValidationError.invalid(field: "Build key", value: key)
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CommandValidationError.invalid(field: "Build value", value: value)
        }
        self.key = key
        self.value = value
    }

    var argument: String { "\(key)=\(value)" }
}

nonisolated struct LocalPath: Equatable, Sendable {
    let rawValue: String

    init(validating value: String, field: String) throws {
        guard !value.isEmpty else { throw CommandValidationError.empty(field: field) }
        guard value.first == "/",
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw CommandValidationError.invalid(field: field, value: value)
        }
        rawValue = value
    }
}

nonisolated struct BuildPlatform: Equatable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        guard value.range(
            of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)?$"#,
            options: .regularExpression
        ) != nil else {
            throw CommandValidationError.invalid(field: "Build platform", value: value)
        }
        rawValue = value
    }
}

nonisolated enum BuildOutputType: String, CaseIterable, Equatable, Sendable {
    case oci
    case tar
    case local
}

nonisolated struct BuildOutput: Equatable, Sendable {
    let type: BuildOutputType
    let destination: LocalPath?

    init(type: BuildOutputType, destination: String? = nil) throws {
        self.type = type
        self.destination = try destination.map {
            try LocalPath(validating: $0, field: "Build output destination")
        }
    }

    var argument: String {
        guard let destination else { return "type=\(type.rawValue)" }
        return "type=\(type.rawValue),dest=\(destination.rawValue)"
    }
}

nonisolated struct BuildConfiguration: Equatable, Sendable {
    let tag: ImageReference
    let contextDirectory: LocalPath
    let dockerfile: LocalPath?
    let buildArguments: [BuildKeyValue]
    let labels: [BuildKeyValue]
    let noCache: Bool
    let target: String?
    let platform: BuildPlatform?
    let operatingSystem: String?
    let architecture: String?
    let cpuLimit: CPULimit?
    let memoryLimit: MemoryLimit?
    let output: BuildOutput?
    let pull: Bool

    init(
        tag: String,
        contextDirectory: String,
        dockerfile: String? = nil,
        buildArguments: [BuildKeyValue] = [],
        labels: [BuildKeyValue] = [],
        noCache: Bool = false,
        target: String? = nil,
        platform: String? = nil,
        operatingSystem: String? = nil,
        architecture: String? = nil,
        cpuLimit: String? = nil,
        memoryLimit: String? = nil,
        output: BuildOutput? = nil,
        pull: Bool = false
    ) throws {
        self.tag = try ImageReference(validating: tag)
        self.contextDirectory = try LocalPath(
            validating: contextDirectory,
            field: "Build context directory"
        )
        self.dockerfile = try dockerfile.map {
            try LocalPath(validating: $0, field: "Dockerfile path")
        }
        try Self.requireUniqueKeys(buildArguments, field: "Build argument")
        try Self.requireUniqueKeys(labels, field: "Build label")
        self.buildArguments = buildArguments
        self.labels = labels
        self.noCache = noCache
        self.target = try target.map { try Self.validatedToken($0, field: "Build target") }
        self.platform = try platform.map(BuildPlatform.init(validating:))
        self.operatingSystem = try operatingSystem.map {
            try Self.validatedToken($0, field: "Build OS")
        }
        self.architecture = try architecture.map {
            try Self.validatedToken($0, field: "Build architecture")
        }
        self.cpuLimit = try cpuLimit.map(CPULimit.init)
        self.memoryLimit = try memoryLimit.map(MemoryLimit.init)
        self.output = output
        self.pull = pull
    }

    var arguments: [String] {
        var result = ["build", "--tag", tag.rawValue]
        if let dockerfile { result += ["--file", dockerfile.rawValue] }
        for argument in buildArguments { result += ["--build-arg", argument.argument] }
        for label in labels { result += ["--label", label.argument] }
        if noCache { result.append("--no-cache") }
        if let target { result += ["--target", target] }
        if let platform {
            result += ["--platform", platform.rawValue]
        } else {
            if let operatingSystem { result += ["--os", operatingSystem] }
            if let architecture { result += ["--arch", architecture] }
        }
        if let cpuLimit { result += ["--cpus", cpuLimit.value] }
        if let memoryLimit { result += ["--memory", memoryLimit.value] }
        if let output { result += ["--output", output.argument] }
        if pull { result.append("--pull") }
        result += ["--progress", "plain", contextDirectory.rawValue]
        return result
    }

    static func validatedToken(_ value: String, field: String) throws -> String {
        guard !value.isEmpty, value.first != "-",
              value.unicodeScalars.allSatisfy({
                $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CommandValidationError.invalid(field: field, value: value)
        }
        return value
    }

    private static func requireUniqueKeys(
        _ values: [BuildKeyValue],
        field: String
    ) throws {
        var keys = Set<String>()
        for value in values where !keys.insert(value.key).inserted {
            throw CommandValidationError.invalid(field: field, value: value.key)
        }
    }
}

nonisolated struct BuilderStartConfiguration: Equatable, Sendable {
    let cpuLimit: CPULimit?
    let memoryLimit: MemoryLimit?

    init(cpuLimit: String? = nil, memoryLimit: String? = nil) throws {
        self.cpuLimit = try cpuLimit.map(CPULimit.init)
        self.memoryLimit = try memoryLimit.map(MemoryLimit.init)
    }
}

nonisolated enum BuilderState: String, Equatable, Sendable {
    case absent
    case running
    case stopped
    case unknown
}

nonisolated struct BuilderStatus: Equatable, Sendable {
    let state: BuilderState
    let id: String?
    let image: String?
    let address: String?

    static let absent = BuilderStatus(state: .absent, id: nil, image: nil, address: nil)

    static func decode(from data: Data) throws -> BuilderStatus {
        let value = try JSONSerialization.jsonObject(with: data)
        let object: [String: Any]?
        if let array = value as? [[String: Any]] {
            object = array.first
        } else {
            object = value as? [String: Any]
        }
        guard let object else { return .absent }

        let flattened = flattenedValues(object)
        let reportedState = string(in: flattened, keys: ["state", "status"])
        let state: BuilderState
        switch reportedState?.lowercased() {
        case "running", "ready", "active": state = .running
        case "stopped", "created", "inactive", "exited": state = .stopped
        case nil: state = .unknown
        default: state = .unknown
        }
        return BuilderStatus(
            state: state,
            id: string(in: flattened, keys: ["id", "name"]),
            image: string(in: flattened, keys: ["imagereference", "image", "reference"]),
            address: string(in: flattened, keys: ["address", "ipv4address"])
        )
    }

    private static func flattenedValues(_ object: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        func append(_ dictionary: [String: Any]) {
            for (key, value) in dictionary {
                let normalized = key.lowercased().filter(\.isLetter)
                if result[normalized] == nil { result[normalized] = value }
                if let nested = value as? [String: Any] { append(nested) }
            }
        }
        append(object)
        return result
    }

    private static func string(in values: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = values[key.lowercased().filter(\.isLetter)] as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
