import Foundation

nonisolated protocol RegistryManaging: Sendable {
    func listRegistries() async throws -> [RegistrySummary]
    /// `password` is handed straight to the child's stdin and released. It is
    /// never stored, logged, or turned into an argument.
    func login(_ configuration: RegistryLoginConfiguration, password: String) async throws
    func logout(host: String) async throws
}

actor CLIRegistryService: RegistryManaging {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    /// `--quiet` prints one hostname per line. The structured formats carry no
    /// extra fact the list needs, and their shape has moved between releases,
    /// so parsing lines keeps this working across every supported CLI.
    func listRegistries() async throws -> [RegistrySummary] {
        do {
            let result = try await cli.run(.listRegistries)
            return Self.hosts(from: result.standardOutput)
        } catch {
            throw sanitizedRegistryError(error)
        }
    }

    func login(_ configuration: RegistryLoginConfiguration, password: String) async throws {
        do {
            // The CLI reads one line from stdin, so the payload is the secret
            // plus a newline and nothing else. It goes out of scope with this
            // call rather than being retained anywhere.
            var payload = Data(password.utf8)
            payload.append(0x0A)
            _ = try await cli.run(
                .loginRegistry(configuration: configuration),
                standardInput: payload
            )
        } catch {
            throw sanitizedRegistryError(error)
        }
    }

    func logout(host: String) async throws {
        do {
            let validated = try RegistryHost(validating: host)
            _ = try await cli.run(.logoutRegistry(host: validated))
        } catch {
            throw sanitizedRegistryError(error)
        }
    }

    /// Validated, de-duplicated and sorted. A line that is not a host — a
    /// heading, a warning, a blank — is dropped rather than shown as a registry.
    nonisolated static func hosts(from output: String) -> [RegistrySummary] {
        var seen = Set<String>()
        var result: [RegistrySummary] = []
        for line in output.split(whereSeparator: \Character.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = try? RegistryHost(validating: trimmed),
                  seen.insert(host.rawValue).inserted else { continue }
            result.append(RegistrySummary(host: host))
        }
        return result.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }
}

nonisolated func sanitizedRegistryError(_ error: Error) -> Error {
    guard let cliError = error as? CLIError else {
        return CLIError.launchFailed(
            message: DiagnosticSanitizer.sanitize(error.localizedDescription)
        )
    }
    switch cliError {
    case .nonZeroExit(let invocation, let exitCode, let standardError, let standardOutput):
        return CLIError.nonZeroExit(
            invocation: DiagnosticSanitizer.sanitize(invocation),
            exitCode: exitCode,
            standardError: DiagnosticSanitizer.sanitize(standardError),
            standardOutput: DiagnosticSanitizer.sanitize(standardOutput)
        )
    case .invalidOutput(let description):
        return CLIError.invalidOutput(description: DiagnosticSanitizer.sanitize(description))
    case .launchFailed(let message):
        return CLIError.launchFailed(message: DiagnosticSanitizer.sanitize(message))
    default:
        return cliError
    }
}
