import Foundation

nonisolated protocol DNSManaging: Sendable {
    func listDomains() async throws -> [String]
    func loadServiceDomain() async throws -> String?
}

actor CLIDNSService: DNSManaging {
    private let cli: any ContainerCLI
    init(cli: any ContainerCLI) { self.cli = cli }

    func listDomains() async throws -> [String] {
        try await decode([String].self, command: .systemDNSList)
    }

    func loadServiceDomain() async throws -> String? {
        let properties = try await decode(SystemPropertiesDTO.self, command: .systemProperties)
        return properties.dns?.domain
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

nonisolated private struct SystemPropertiesDTO: Decodable {
    struct DNS: Decodable { let domain: String? }
    let dns: DNS?
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
