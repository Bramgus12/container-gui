import Foundation

nonisolated protocol DNSManaging: Sendable {
    func listDomains() async throws -> [String]
    func loadServiceDomain() async throws -> String?
    /// Writes the `/etc/resolver` entry. macOS authenticates the user first.
    func createDomain(_ configuration: DNSCreateConfiguration) async throws
    /// Removes the `/etc/resolver` entry. macOS authenticates the user first.
    func deleteDomain(_ configuration: DNSDeleteConfiguration) async throws
    /// Starts `sudo container system dns …` behind a pseudo-terminal, so the
    /// user can run the privileged change in the app and watch it happen rather
    /// than copying it into Terminal.
    ///
    /// `sudo` refuses to prompt without a controlling terminal, which is exactly
    /// what the pseudo-terminal supplies. The password is typed into the
    /// embedded terminal and travels to `sudo` through the pty; the app does not
    /// store it, echo it, or write it anywhere.
    nonisolated func attachPrivileged(
        arguments: [String],
        terminalSize: TerminalSize
    ) throws -> any InteractiveProcessSession
}

actor CLIDNSService: DNSManaging {
    private let cli: any ContainerCLI
    /// The privileged commands bypass `cli` because they run through the macOS
    /// authentication dialog rather than as the logged-in user, so they need the
    /// executable's own path.
    private let executableURL: URL
    private let privilegedRunner: any PrivilegedCommandRunning

    init(
        cli: any ContainerCLI,
        executableURL: URL,
        privilegedRunner: any PrivilegedCommandRunning = OSAScriptPrivilegedCommandRunner()
    ) {
        self.cli = cli
        self.executableURL = executableURL
        self.privilegedRunner = privilegedRunner
    }

    func listDomains() async throws -> [String] {
        try await decode([String].self, command: .systemDNSList)
    }

    func loadServiceDomain() async throws -> String? {
        do {
            let result = try await cli.run(.systemProperties)
            let properties = try SystemProperties.decode(
                from: Data(result.standardOutput.utf8)
            )
            return properties.dnsDomain
        } catch {
            throw sanitizedDNSError(error)
        }
    }

    func createDomain(_ configuration: DNSCreateConfiguration) async throws {
        try await runPrivileged(
            arguments: configuration.arguments,
            prompt: "CargoDeck needs administrator access to add the local DNS domain “\(configuration.domain.rawValue)” to /etc/resolver."
        )
    }

    func deleteDomain(_ configuration: DNSDeleteConfiguration) async throws {
        try await runPrivileged(
            arguments: configuration.arguments,
            prompt: "CargoDeck needs administrator access to remove the local DNS domain “\(configuration.domain.rawValue)” from /etc/resolver."
        )
    }

    nonisolated func attachPrivileged(
        arguments: [String],
        terminalSize: TerminalSize
    ) throws -> any InteractiveProcessSession {
        let request = Self.privilegedRequest(
            executableURL: executableURL,
            arguments: arguments,
            terminalSize: terminalSize
        )
        do {
            return try PseudoTerminalSession(request: request, size: terminalSize)
        } catch {
            throw sanitizedDNSError(error)
        }
    }

    /// `sudo` is invoked by absolute path with the container executable as its
    /// first argument, so nothing is resolved through a `PATH` lookup and no
    /// shell parses any of it — ADR 0001 still holds. The arguments are passed
    /// as a vector, so a domain containing shell metacharacters is data rather
    /// than syntax.
    nonisolated static func privilegedRequest(
        executableURL: URL,
        arguments: [String],
        terminalSize: TerminalSize
    ) -> InteractiveSessionRequest {
        InteractiveSessionRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: [executableURL.path] + arguments,
            environment: ProcessContainerCLI.defaultEnvironment(),
            terminalSize: terminalSize
        )
    }

    private func runPrivileged(arguments: [String], prompt: String) async throws {
        do {
            _ = try await privilegedRunner.run(
                PrivilegedCommand(executableURL: executableURL, arguments: arguments, prompt: prompt)
            )
        } catch let error as PrivilegedCommandError {
            throw sanitizedPrivilegedError(error)
        } catch {
            throw sanitizedDNSError(error)
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, command: ContainerCommand) async throws -> Value {
        do {
            let result = try await cli.run(command)
            return try JSONDecoder().decode(type, from: Data(result.standardOutput.utf8))
        } catch let error as DecodingError {
            throw CLIError.invalidOutput(description: "DNS information could not be decoded as JSON: \(error.localizedDescription)")
        } catch {
            throw sanitizedDNSError(error)
        }
    }
}

nonisolated private func sanitizedPrivilegedError(_ error: PrivilegedCommandError) -> PrivilegedCommandError {
    switch error {
    case .cancelled: .cancelled
    case .launchFailed(let message): .launchFailed(message: DiagnosticSanitizer.sanitize(message))
    case .failed(let invocation, let exitCode, let message):
        .failed(
            invocation: DiagnosticSanitizer.sanitize(invocation),
            exitCode: exitCode,
            message: DiagnosticSanitizer.sanitize(message)
        )
    }
}

nonisolated private func sanitizedDNSError(_ error: Error) -> Error {
    guard let cliError = error as? CLIError else { return CLIError.launchFailed(message: DiagnosticSanitizer.sanitize(error.localizedDescription)) }
    switch cliError {
    case .nonZeroExit(let invocation, let exitCode, let standardError, let standardOutput):
        return CLIError.nonZeroExit(invocation: DiagnosticSanitizer.sanitize(invocation), exitCode: exitCode, standardError: DiagnosticSanitizer.sanitize(standardError), standardOutput: DiagnosticSanitizer.sanitize(standardOutput))
    case .invalidOutput(let description): return CLIError.invalidOutput(description: DiagnosticSanitizer.sanitize(description))
    case .launchFailed(let message): return CLIError.launchFailed(message: DiagnosticSanitizer.sanitize(message))
    default: return cliError
    }
}
