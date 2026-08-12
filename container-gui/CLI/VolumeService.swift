import Foundation

nonisolated protocol VolumeManaging: Sendable {
    func listVolumes() async throws -> [VolumeSummary]
    func inspectVolume(name: String) async throws -> VolumeInspection
    func createVolume(_ configuration: VolumeCreateConfiguration) async throws
    func deleteVolume(name: String) async throws
    func pruneVolumes() async throws -> [String]
}

actor CLIVolumeService: VolumeManaging {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func listVolumes() async throws -> [VolumeSummary] {
        do {
            let result = try await cli.run(.listVolumes)
            let dtos = try JSONDecoder().decode(
                [VolumeDTO].self,
                from: Data(result.standardOutput.utf8)
            )
            return dtos.compactMap(VolumeSummary.init(dto:))
        } catch let error as DecodingError {
            throw CLIError.invalidOutput(
                description: "The volume list could not be decoded as JSON: \(error.localizedDescription)"
            )
        } catch {
            throw sanitizedVolumeError(error)
        }
    }

    func inspectVolume(name: String) async throws -> VolumeInspection {
        do {
            let volumeName = try VolumeName(validating: name)
            let result = try await cli.run(.inspectVolume(name: volumeName))
            let data = Data(result.standardOutput.utf8)
            let dtos: [VolumeDTO]
            if let array = try? JSONDecoder().decode([VolumeDTO].self, from: data) {
                dtos = array
            } else {
                dtos = [try JSONDecoder().decode(VolumeDTO.self, from: data)]
            }
            guard let dto = dtos.first(where: {
                VolumeSummary(dto: $0)?.name == volumeName.rawValue
            }), let inspection = VolumeInspection(dto: dto, rawJSON: result.standardOutput)
            else {
                throw CLIError.invalidOutput(
                    description: "Volume inspection returned no matching entry for \(volumeName.rawValue)."
                )
            }
            return inspection
        } catch let error as DecodingError {
            throw CLIError.invalidOutput(
                description: "Volume inspection could not be decoded as JSON: \(error.localizedDescription)"
            )
        } catch {
            throw sanitizedVolumeError(error)
        }
    }

    func createVolume(_ configuration: VolumeCreateConfiguration) async throws {
        do {
            _ = try await cli.run(.createVolume(configuration: configuration))
        } catch {
            throw sanitizedVolumeError(error)
        }
    }

    func deleteVolume(name: String) async throws {
        do {
            let volumeName = try VolumeName(validating: name)
            _ = try await cli.run(.deleteVolume(name: volumeName))
        } catch {
            throw sanitizedVolumeError(error)
        }
    }

    func pruneVolumes() async throws -> [String] {
        do {
            let result = try await cli.run(.pruneVolumes)
            return Self.prunedVolumeNames(from: result.standardOutput)
        } catch {
            throw sanitizedVolumeError(error)
        }
    }

    nonisolated static func prunedVolumeNames(from output: String) -> [String] {
        output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                (try? VolumeName(validating: line)) != nil
            }
    }
}

nonisolated private func sanitizedVolumeError(_ error: Error) -> Error {
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
