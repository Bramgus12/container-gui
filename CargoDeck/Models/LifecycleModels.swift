import Foundation

/// Signals the app is willing to send with `container kill`. The CLI accepts any
/// signal name, but an allowlist keeps a free-text field from reaching the
/// process arguments and gives the UI a menu to render.
nonisolated enum KillSignal: String, CaseIterable, Equatable, Sendable {
    case term = "TERM"
    case kill = "KILL"
    case interrupt = "INT"
    case hangup = "HUP"
    case quit = "QUIT"
    case user1 = "USR1"
    case user2 = "USR2"

    var displayName: String {
        switch self {
        case .term: "SIGTERM (graceful)"
        case .kill: "SIGKILL (immediate)"
        case .interrupt: "SIGINT"
        case .hangup: "SIGHUP"
        case .quit: "SIGQUIT"
        case .user1: "SIGUSR1"
        case .user2: "SIGUSR2"
        }
    }
}

/// The `--user` value for `exec`, in the CLI's `name|uid[:gid]` form.
nonisolated struct ProcessUser: Equatable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        guard !value.isEmpty else {
            throw CommandValidationError.empty(field: "User")
        }
        guard value.range(
            of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*(?::[A-Za-z0-9_][A-Za-z0-9_.-]*)?$"#,
            options: .regularExpression
        ) != nil else {
            throw CommandValidationError.invalid(field: "User", value: value)
        }
        rawValue = value
    }
}

nonisolated struct ExecConfiguration: Equatable, Sendable {
    let command: [String]
    let environment: [EnvironmentVariable]
    let user: ProcessUser?
    let workingDirectory: LocalPath?
    let interactive: Bool
    let tty: Bool
    let detached: Bool

    init(
        command: [String],
        environment: [EnvironmentVariable] = [],
        user: String? = nil,
        workingDirectory: String? = nil,
        interactive: Bool = false,
        tty: Bool = false,
        detached: Bool = false
    ) throws {
        guard let executable = command.first, !executable.isEmpty else {
            throw CommandValidationError.empty(field: "Command")
        }
        // A leading dash would be read as an option by the CLI's parser rather
        // than as the program to run.
        guard executable.first != "-" else {
            throw CommandValidationError.invalid(field: "Command", value: executable)
        }
        let controlCharacters = CharacterSet.controlCharacters
        guard command.allSatisfy({ argument in
            !argument.unicodeScalars.contains { controlCharacters.contains($0) }
        }) else {
            throw CommandValidationError.invalid(field: "Command", value: command.joined(separator: " "))
        }
        self.command = command
        self.environment = environment
        self.user = try user.map { try ProcessUser(validating: $0) }
        self.workingDirectory = try workingDirectory.map {
            try LocalPath(validating: $0, field: "Working directory")
        }
        // Detaching closes the streams an interactive session needs.
        guard !(detached && (interactive || tty)) else {
            throw CommandValidationError.invalid(
                field: "Exec configuration",
                value: "Detached cannot be combined with interactive or TTY"
            )
        }
        self.interactive = interactive
        self.tty = tty
        self.detached = detached
    }

    func arguments(for identifier: ContainerIdentifier) -> [String] {
        var result = ["exec"]
        for variable in environment {
            result += ["--env", variable.argument]
        }
        if let user {
            result += ["--user", user.rawValue]
        }
        if let workingDirectory {
            result += ["--workdir", workingDirectory.rawValue]
        }
        if interactive {
            result.append("--interactive")
        }
        if tty {
            result.append("--tty")
        }
        if detached {
            result.append("--detach")
        }
        result.append(identifier.rawValue)
        result += command
        return result
    }
}

/// One side of a `container copy`. The CLI overloads a single argument with two
/// meanings, so the container form is composed here rather than by string
/// interpolation at the call site.
nonisolated enum CopyEndpoint: Equatable, Sendable {
    case host(LocalPath)
    case container(id: ContainerIdentifier, path: LocalPath)

    static func host(path: String) throws -> CopyEndpoint {
        .host(try LocalPath(validating: path, field: "Host path"))
    }

    static func container(id: String, path: String) throws -> CopyEndpoint {
        .container(
            id: try ContainerIdentifier(validating: id),
            path: try LocalPath(validating: path, field: "Container path")
        )
    }

    var argument: String {
        switch self {
        case .host(let path):
            path.rawValue
        case .container(let id, let path):
            "\(id.rawValue):\(path.rawValue)"
        }
    }

    var isContainer: Bool {
        if case .container = self { return true }
        return false
    }
}

nonisolated struct CopyOperation: Equatable, Sendable {
    let source: CopyEndpoint
    let destination: CopyEndpoint

    init(source: CopyEndpoint, destination: CopyEndpoint) throws {
        // The CLI copies between a container and the local filesystem; neither
        // host-to-host nor container-to-container is supported.
        guard source.isContainer != destination.isContainer else {
            throw CommandValidationError.invalid(
                field: "Copy operation",
                value: "Exactly one of the source and destination must be a container path"
            )
        }
        self.source = source
        self.destination = destination
    }

    var arguments: [String] {
        ["copy", source.argument, destination.argument]
    }
}
