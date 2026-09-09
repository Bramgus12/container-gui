import Foundation

nonisolated protocol NetworkManaging: Sendable {
    func listNetworks() async throws -> [NetworkSummary]
    func inspectNetwork(name: String) async throws -> NetworkInspection
    func createNetwork(_ configuration: NetworkCreateConfiguration) async throws
    func deleteNetwork(name: String) async throws
    func pruneNetworks() async throws -> [String]
}

actor CLINetworkService: NetworkManaging {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func listNetworks() async throws -> [NetworkSummary] {
        do {
            let result = try await cli.run(.listNetworks)
            let dtos = try JSONDecoder().decode(
                [NetworkDTO].self,
                from: Data(result.standardOutput.utf8)
            )
            return dtos.compactMap(NetworkSummary.init(dto:))
        } catch let error as DecodingError {
            throw CLIError.invalidOutput(
                description: "The network list could not be decoded as JSON: \(error.localizedDescription)"
            )
        } catch {
            throw sanitizedNetworkError(error)
        }
    }

    func inspectNetwork(name: String) async throws -> NetworkInspection {
        do {
            let networkName = try NetworkName(validating: name)
            let result = try await cli.run(.inspectNetwork(name: networkName))
            let data = Data(result.standardOutput.utf8)
            let dtos: [NetworkDTO]
            if let array = try? JSONDecoder().decode([NetworkDTO].self, from: data) {
                dtos = array
            } else {
                dtos = [try JSONDecoder().decode(NetworkDTO.self, from: data)]
            }
            guard let dto = dtos.first(where: {
                NetworkSummary(dto: $0)?.name == networkName.rawValue
            }), let inspection = NetworkInspection(dto: dto, rawJSON: result.standardOutput) else {
                throw CLIError.invalidOutput(
                    description: "Network inspection returned no matching entry for \(networkName.rawValue)."
                )
            }
            return inspection
        } catch let error as DecodingError {
            throw CLIError.invalidOutput(
                description: "Network inspection could not be decoded as JSON: \(error.localizedDescription)"
            )
        } catch {
            throw sanitizedNetworkError(error)
        }
    }

    func createNetwork(_ configuration: NetworkCreateConfiguration) async throws {
        do {
            _ = try await cli.run(.createNetwork(configuration: configuration))
        } catch {
            throw sanitizedNetworkError(error)
        }
    }

    func deleteNetwork(name: String) async throws {
        do {
            let networkName = try NetworkName(validating: name)
            _ = try await cli.run(.deleteNetwork(name: networkName))
        } catch {
            throw sanitizedNetworkError(error)
        }
    }

    func pruneNetworks() async throws -> [String] {
        do {
            let result = try await cli.run(.pruneNetworks)
            return result.standardOutput
                .split(whereSeparator: \Character.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            throw sanitizedNetworkError(error)
        }
    }
}

nonisolated private func sanitizedNetworkError(_ error: Error) -> Error {
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
