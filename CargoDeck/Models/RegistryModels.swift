import Foundation

/// A registry server name: a host, optionally with a port. Deliberately *not* a
/// URL — the CLI takes `ghcr.io`, not `https://ghcr.io`, and the transport is
/// chosen by `--scheme` instead. Rejecting the scheme here means a pasted URL
/// fails in the login sheet with a message, rather than as a CLI error.
nonisolated struct RegistryHost: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CommandValidationError.empty(field: "Registry server")
        }
        guard trimmed.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?(?::[0-9]{1,5})?$"#,
            options: .regularExpression
        ) != nil else {
            throw CommandValidationError.invalid(field: "Registry server", value: trimmed)
        }
        rawValue = trimmed
    }
}

/// One logged-in registry. `registry list --quiet` reports host identity and
/// nothing else, which is all the list needs.
nonisolated struct RegistrySummary: Identifiable, Equatable, Sendable {
    var id: String { host }

    let host: String

    init(host: RegistryHost) {
        self.host = host.rawValue
    }
}

/// Everything `registry login` needs **except the password**.
///
/// The secret is absent by construction rather than by convention: it never
/// enters a command, so `ContainerCommand` stays safely `Equatable`, and
/// `ProcessContainerCLI.displayInvocation` cannot render it even by accident.
/// It reaches the child process only as stdin bytes.
nonisolated struct RegistryLoginConfiguration: Equatable, Sendable {
    let server: RegistryHost
    let username: String
    let scheme: RegistryScheme

    init(server: String, username: String, scheme: RegistryScheme = .auto) throws {
        self.server = try RegistryHost(validating: server)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw CommandValidationError.empty(field: "Registry username")
        }
        self.username = try BuildConfiguration.validatedToken(
            trimmedUsername,
            field: "Registry username"
        )
        self.scheme = scheme
    }

    var arguments: [String] {
        ["registry", "login", "--password-stdin"]
            + scheme.arguments
            + ["--username", username]
            + [server.rawValue]
    }
}

nonisolated enum RegistryListState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

nonisolated enum RegistryMutation: Equatable, Sendable {
    case login(String)
    case logout(String)

    var host: String {
        switch self {
        case .login(let host), .logout(let host): host
        }
    }
}
