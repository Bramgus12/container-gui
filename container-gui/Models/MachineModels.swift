import Foundation

/// A machine is a long-lived VM booted from an OCI image, not a container you
/// run and discard. The service filters machines out of every container list, so
/// `container machine list` is the only place they appear — which is why they
/// get a destination of their own rather than a filter on Containers.

// MARK: - Value types

nonisolated struct MachineIdentifier: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        guard !value.isEmpty else {
            throw CommandValidationError.empty(field: "Machine name")
        }
        guard value.first != "-", Self.isValid(value) else {
            throw CommandValidationError.invalid(field: "Machine name", value: value)
        }
        rawValue = value
    }

    private static func isValid(_ value: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// `machine set` rejects anything at or below 1G with "Must be greater than
/// 1gb", so the rule lives here and the sheet can say so before the CLI does.
nonisolated struct MachineMemory: Equatable, Sendable {
    let value: String

    init(_ value: String) throws {
        guard let match = value.range(
            of: #"^([1-9][0-9]*)\s*([KMGTkmgt])[Bb]?$"#,
            options: .regularExpression
        ), match.lowerBound == value.startIndex else {
            throw CommandValidationError.invalid(field: "Memory", value: value)
        }
        guard Self.bytes(in: value) > 1_073_741_824 else {
            throw CommandValidationError.invalid(field: "Memory", value: value)
        }
        self.value = value
    }

    /// Only used to enforce the "greater than 1G" rule; the CLI is handed the
    /// original string so its own parser stays the authority.
    private static func bytes(in value: String) -> UInt64 {
        let digits = value.prefix { $0.isNumber }
        guard let amount = UInt64(digits) else { return 0 }
        let unit = value.dropFirst(digits.count)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .first
        let multiplier: UInt64
        switch unit {
        case "k": multiplier = 1_024
        case "m": multiplier = 1_048_576
        case "g": multiplier = 1_073_741_824
        case "t": multiplier = 1_099_511_627_776
        default: multiplier = 1
        }
        return amount.multipliedReportingOverflow(by: multiplier).partialValue
    }
}

nonisolated struct MachineCPUCount: Equatable, Sendable {
    let value: Int

    init(_ value: Int) throws {
        guard value > 0 else {
            throw CommandValidationError.nonPositive(field: "CPUs")
        }
        guard value <= 1_024 else {
            throw CommandValidationError.outOfRange(field: "CPUs", value: value)
        }
        self.value = value
    }
}

nonisolated enum MachineHomeMount: String, CaseIterable, Equatable, Sendable {
    case readWrite = "rw"
    case readOnly = "ro"
    case none

    init(validating value: String) throws {
        guard let mount = MachineHomeMount(rawValue: value.lowercased()) else {
            throw CommandValidationError.invalid(field: "Home mount", value: value)
        }
        self = mount
    }
}

/// The kernel path is the one machine setting the design shows as a tilde path.
/// `LocalPath` requires a leading slash, so this expands `~` rather than
/// rejecting what the user typed. An empty value resets to the system kernel,
/// which the CLI spells as `kernel=`.
nonisolated struct MachineKernelPath: Equatable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw CommandValidationError.empty(field: "Kernel path")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.first == "/",
              !expanded.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw CommandValidationError.invalid(field: "Kernel path", value: value)
        }
        rawValue = expanded
    }
}

nonisolated enum MachineState: Equatable, Sendable {
    case running
    case stopped
    case unknown(String)

    init(_ value: String?) {
        switch value?.lowercased() {
        case "running":
            self = .running
        case "stopped", "exited":
            self = .stopped
        case .some(let value):
            self = .unknown(value)
        case nil:
            self = .unknown("unknown")
        }
    }
}

/// `container machine` arrived in Apple Container 1.0.0. The app supports 0.12.0
/// upward, so the destination has to be able to disappear.
nonisolated struct MachineCapabilities: Equatable, Sendable {
    static let minimumVersion = SemanticVersion(major: 1, minor: 0, patch: 0)

    let isSupported: Bool

    init(version: SemanticVersion) {
        isSupported = version >= Self.minimumVersion
    }

    init(isSupported: Bool) {
        self.isSupported = isSupported
    }
}

// MARK: - Boot configuration

/// The five keys `machine set` accepts, and the same five `machine create`
/// takes as flags. Kept as one type so the create sheet and the boot-config
/// editor cannot drift apart.
///
/// `virtualization` and `kernelPath` are write-only in practice: they are stored
/// by the service but `machine inspect` does not report them back, so a value
/// read from the CLI is always `nil` for those two. See `MachineInspection`.
nonisolated struct MachineBootConfiguration: Equatable, Sendable {
    var cpus: MachineCPUCount?
    var memory: MachineMemory?
    var homeMount: MachineHomeMount?
    var virtualization: Bool?
    var kernel: MachineKernelPath?
    /// Distinct from `kernel == nil`: this asks the CLI to reset to the system
    /// kernel by sending an empty `kernel=`, which is not the same as leaving
    /// the setting alone.
    var resetsKernel = false

    init(
        cpus: MachineCPUCount? = nil,
        memory: MachineMemory? = nil,
        homeMount: MachineHomeMount? = nil,
        virtualization: Bool? = nil,
        kernel: MachineKernelPath? = nil,
        resetsKernel: Bool = false
    ) {
        self.cpus = cpus
        self.memory = memory
        self.homeMount = homeMount
        self.virtualization = virtualization
        self.kernel = kernel
        self.resetsKernel = resetsKernel
    }

    var isEmpty: Bool {
        cpus == nil && memory == nil && homeMount == nil
            && virtualization == nil && kernel == nil && !resetsKernel
    }

    /// `key=value` pairs for `machine set`.
    var settings: [String] {
        var settings: [String] = []
        if let cpus { settings.append("cpus=\(cpus.value)") }
        if let memory { settings.append("memory=\(memory.value)") }
        if let homeMount { settings.append("home-mount=\(homeMount.rawValue)") }
        if let virtualization { settings.append("virtualization=\(virtualization)") }
        if let kernel {
            settings.append("kernel=\(kernel.rawValue)")
        } else if resetsKernel {
            settings.append("kernel=")
        }
        return settings
    }

    /// The same five as flags, for `machine create`.
    var createFlags: [String] {
        var flags: [String] = []
        if let cpus { flags += ["--cpus", String(cpus.value)] }
        if let memory { flags += ["--memory", memory.value] }
        if let homeMount { flags += ["--home-mount", homeMount.rawValue] }
        if virtualization == true { flags.append("--virtualization") }
        if let kernel { flags += ["--kernel", kernel.rawValue] }
        return flags
    }
}

// MARK: - Configurations

nonisolated struct MachineCreateConfiguration: Equatable, Sendable {
    let image: ImageReference
    let name: MachineIdentifier?
    let operatingSystem: String?
    let architecture: String?
    let boot: MachineBootConfiguration
    let setsDefault: Bool
    let bootsAfterCreating: Bool

    init(
        image: String,
        name: String? = nil,
        operatingSystem: String? = nil,
        architecture: String? = nil,
        boot: MachineBootConfiguration = MachineBootConfiguration(),
        setsDefault: Bool = false,
        bootsAfterCreating: Bool = true
    ) throws {
        self.image = try ImageReference(validating: image)
        self.name = try name.flatMap {
            $0.isEmpty ? nil : try MachineIdentifier(validating: $0)
        }
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.boot = boot
        self.setsDefault = setsDefault
        self.bootsAfterCreating = bootsAfterCreating
    }

    var arguments: [String] {
        var arguments = ["machine", "create"]
        if let name { arguments += ["--name", name.rawValue] }
        if let operatingSystem { arguments += ["--os", operatingSystem] }
        if let architecture { arguments += ["--arch", architecture] }
        arguments += boot.createFlags
        if setsDefault { arguments.append("--set-default") }
        if !bootsAfterCreating { arguments.append("--no-boot") }
        arguments.append(image.rawValue)
        return arguments
    }
}

nonisolated struct MachineSetConfiguration: Equatable, Sendable {
    let name: MachineIdentifier?
    let boot: MachineBootConfiguration

    init(name: String?, boot: MachineBootConfiguration) throws {
        self.name = try name.flatMap {
            $0.isEmpty ? nil : try MachineIdentifier(validating: $0)
        }
        guard !boot.isEmpty else {
            throw CommandValidationError.empty(field: "Machine settings")
        }
        self.boot = boot
    }

    var arguments: [String] {
        var arguments = ["machine", "set"]
        if let name { arguments += ["--name", name.rawValue] }
        return arguments + boot.settings
    }
}

nonisolated struct MachineRunConfiguration: Equatable, Sendable {
    let name: MachineIdentifier?
    let command: [String]
    let environment: [EnvironmentVariable]
    let environmentFile: LocalPath?
    let user: ProcessUser?
    let runsAsRoot: Bool
    let workingDirectory: LocalPath?
    let interactive: Bool
    let tty: Bool
    let detached: Bool

    init(
        name: String?,
        command: [String] = [],
        environment: [EnvironmentVariable] = [],
        environmentFile: String? = nil,
        user: String? = nil,
        runsAsRoot: Bool = false,
        workingDirectory: String? = nil,
        interactive: Bool = true,
        tty: Bool = true,
        detached: Bool = false
    ) throws {
        self.name = try name.flatMap {
            $0.isEmpty ? nil : try MachineIdentifier(validating: $0)
        }
        // No leading-dash check: `arguments` always emits `--` before the
        // command, so `ls -la` reaches the machine intact instead of being read
        // as flags to `machine run` itself.
        self.command = command.filter { !$0.isEmpty }
        self.environment = environment
        self.environmentFile = try environmentFile.flatMap {
            $0.isEmpty ? nil : try LocalPath(validating: $0, field: "Environment file")
        }
        if runsAsRoot, user != nil, !(user?.isEmpty ?? true) {
            throw CommandValidationError.invalid(field: "User", value: user ?? "")
        }
        self.user = try user.flatMap {
            $0.isEmpty ? nil : try ProcessUser(validating: $0)
        }
        self.runsAsRoot = runsAsRoot
        self.workingDirectory = try workingDirectory.flatMap {
            $0.isEmpty ? nil : try LocalPath(validating: $0, field: "Working directory")
        }
        self.interactive = interactive
        self.tty = tty
        self.detached = detached
    }

    /// True when no command was given, which the CLI treats as a login shell.
    var isLoginShell: Bool { command.isEmpty }

    var arguments: [String] {
        var arguments = ["machine", "run"]
        if let name { arguments += ["--name", name.rawValue] }
        for variable in environment { arguments += ["--env", variable.argument] }
        if let environmentFile { arguments += ["--env-file", environmentFile.rawValue] }
        if runsAsRoot { arguments.append("--root") }
        if let user { arguments += ["--user", user.rawValue] }
        if let workingDirectory { arguments += ["--workdir", workingDirectory.rawValue] }
        if interactive { arguments.append("--interactive") }
        if tty { arguments.append("--tty") }
        if detached { arguments.append("--detach") }
        if !command.isEmpty { arguments += ["--"] + command }
        return arguments
    }
}

nonisolated struct MachineLogOptions: Equatable, Sendable {
    let name: MachineIdentifier?
    let showsBootLog: Bool
    let follow: Bool
    let tail: Int?

    init(
        name: String?,
        showsBootLog: Bool = false,
        follow: Bool = false,
        tail: Int? = nil
    ) throws {
        self.name = try name.flatMap {
            $0.isEmpty ? nil : try MachineIdentifier(validating: $0)
        }
        if let tail, tail <= 0 {
            throw CommandValidationError.nonPositive(field: "Line count")
        }
        self.showsBootLog = showsBootLog
        self.follow = follow
        self.tail = tail
    }

    var arguments: [String] {
        var arguments = ["machine", "logs"]
        if showsBootLog { arguments.append("--boot") }
        if follow { arguments.append("--follow") }
        if let tail { arguments += ["-n", String(tail)] }
        if let name { arguments.append(name.rawValue) }
        return arguments
    }
}

// MARK: - Decoding

nonisolated struct MachineDTO: Decodable, Equatable, Sendable {
    let id: String?
    let status: String?
    let isDefault: Bool?
    let ipAddress: String?
    let cpus: Int?
    let memory: UInt64?
    let diskSize: UInt64?
    let createdDate: CLIDateValue?

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case isDefault = "default"
        case ipAddress
        case cpus
        case memory
        case diskSize
        case createdDate
    }
}

nonisolated struct MachineImageDescriptorDTO: Decodable, Equatable, Sendable {
    let digest: String?
    let mediaType: String?
    let size: Int?
}

nonisolated struct MachineImageDTO: Decodable, Equatable, Sendable {
    let reference: String?
    let descriptor: MachineImageDescriptorDTO?
}

nonisolated struct MachinePlatformDTO: Decodable, Equatable, Sendable {
    let os: String?
    let architecture: String?
}

nonisolated struct MachineUserSetupDTO: Decodable, Equatable, Sendable {
    let username: String?
    let uid: Int?
    let gid: Int?
}

nonisolated struct MachineInspectionDTO: Decodable, Equatable, Sendable {
    let id: String?
    let status: String?
    let ipAddress: String?
    let cpus: Int?
    let memory: UInt64?
    let diskSize: UInt64?
    let homeMount: String?
    /// Stored by the service but absent from every `machine inspect` payload
    /// observed on 1.3.0. Decoded anyway so a later CLI that reports it works
    /// without a code change.
    let virtualization: Bool?
    let kernelPath: String?
    let createdDate: CLIDateValue?
    let startedDate: CLIDateValue?
    let image: MachineImageDTO?
    let platform: MachinePlatformDTO?
    let userSetup: MachineUserSetupDTO?
}

nonisolated struct MachineSummary: Identifiable, Equatable, Sendable {
    let id: String
    let state: MachineState
    let isDefault: Bool
    let address: String?
    let cpus: Int?
    let memoryBytes: UInt64?
    let diskBytes: UInt64?
    let createdAt: Date?

    init?(dto: MachineDTO) {
        guard let id = dto.id, !id.isEmpty else { return nil }
        self.id = id
        state = MachineState(dto.status)
        isDefault = dto.isDefault ?? false
        address = dto.ipAddress
        cpus = dto.cpus
        memoryBytes = dto.memory
        diskBytes = dto.diskSize
        createdAt = dto.createdDate?.date
    }

    /// Inspection carries the same fields under different nesting, so it builds
    /// a summary through here rather than duplicating the shape.
    init(
        id: String,
        state: MachineState,
        isDefault: Bool,
        address: String?,
        cpus: Int?,
        memoryBytes: UInt64?,
        diskBytes: UInt64?,
        createdAt: Date?
    ) {
        self.id = id
        self.state = state
        self.isDefault = isDefault
        self.address = address
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.createdAt = createdAt
    }
}

nonisolated struct MachineInspection: Equatable, Sendable {
    let summary: MachineSummary
    let imageReference: String?
    let imageDigest: String?
    let operatingSystem: String?
    let architecture: String?
    let homeMount: MachineHomeMount?
    let virtualization: Bool?
    let kernelPath: String?
    let username: String?
    let uid: Int?
    let gid: Int?
    let startedAt: Date?
    let rawJSON: String

    init?(dto: MachineInspectionDTO, rawJSON: String) {
        guard let id = dto.id, !id.isEmpty else { return nil }
        summary = MachineSummary(
            id: id,
            state: MachineState(dto.status),
            isDefault: false,
            address: dto.ipAddress,
            cpus: dto.cpus,
            memoryBytes: dto.memory,
            diskBytes: dto.diskSize,
            createdAt: dto.createdDate?.date
        )
        imageReference = dto.image?.reference
        imageDigest = dto.image?.descriptor?.digest
        operatingSystem = dto.platform?.os
        architecture = dto.platform?.architecture
        homeMount = dto.homeMount.flatMap { MachineHomeMount(rawValue: $0.lowercased()) }
        virtualization = dto.virtualization
        kernelPath = dto.kernelPath
        username = dto.userSetup?.username
        uid = dto.userSetup?.uid
        gid = dto.userSetup?.gid
        startedAt = dto.startedDate?.date
        self.rawJSON = rawJSON
    }

    var platformDescription: String? {
        guard let operatingSystem, let architecture else {
            return operatingSystem ?? architecture
        }
        return "\(operatingSystem)/\(architecture)"
    }

    var userDescription: String? {
        guard let username else { return nil }
        guard let uid else { return username }
        return "\(username) · uid \(uid)"
    }
}
