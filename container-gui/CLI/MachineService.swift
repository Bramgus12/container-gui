import Foundation

nonisolated protocol MachineManaging: Sendable {
    func listMachines() async throws -> [MachineSummary]
    func inspectMachine(name: String) async throws -> MachineInspection
    func createMachine(_ configuration: MachineCreateConfiguration) async throws -> String
    func applyBootConfiguration(_ configuration: MachineSetConfiguration) async throws
    func setDefaultMachine(name: String) async throws
    func stopMachine(name: String) async throws
    func deleteMachine(name: String) async throws
    /// Streams rather than runs: `machine logs --follow` never terminates, so it
    /// must not be bound by the 60-second timeout `run(_:)` applies.
    nonisolated func streamLogs(_ options: MachineLogOptions) -> AsyncThrowingStream<ProcessEvent, Error>
    /// Starts `machine run` behind a pseudo-terminal. A terminal size is what
    /// makes the session allocate one, so a shell gets a real TTY.
    nonisolated func attachRun(
        _ configuration: MachineRunConfiguration,
        terminalSize: TerminalSize
    ) throws -> any InteractiveProcessSession
}

actor CLIMachineService: MachineManaging {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func listMachines() async throws -> [MachineSummary] {
        do {
            let result = try await cli.run(.listMachines)
            let dtos = try JSONDecoder().decode(
                [MachineDTO].self,
                from: Data(result.standardOutput.utf8)
            )
            return dtos.compactMap(MachineSummary.init(dto:))
        } catch let error as DecodingError {
            throw CLIError.invalidOutput(
                description: "The machine list could not be decoded as JSON: \(error.localizedDescription)"
            )
        } catch {
            throw sanitizedMachineError(error)
        }
    }

    func inspectMachine(name: String) async throws -> MachineInspection {
        do {
            let identifier = try MachineIdentifier(validating: name)
            let result = try await cli.run(.inspectMachine(id: identifier))
            let data = Data(result.standardOutput.utf8)
            // `machine inspect` wraps its single result in an array. A future
            // version emitting the bare object decodes just as well.
            let dtos: [MachineInspectionDTO]
            if let array = try? JSONDecoder().decode([MachineInspectionDTO].self, from: data) {
                dtos = array
            } else {
                dtos = [try JSONDecoder().decode(MachineInspectionDTO.self, from: data)]
            }
            guard let dto = dtos.first(where: { $0.id == identifier.rawValue }) ?? dtos.first,
                  let inspection = MachineInspection(dto: dto, rawJSON: result.standardOutput)
            else {
                throw CLIError.invalidOutput(
                    description: "Machine inspection returned no matching entry for \(identifier.rawValue)."
                )
            }
            return inspection
        } catch let error as DecodingError {
            throw CLIError.invalidOutput(
                description: "Machine inspection could not be decoded as JSON: \(error.localizedDescription)"
            )
        } catch {
            throw sanitizedMachineError(error)
        }
    }

    /// Creating pulls the image, creates the machine and — unless `--no-boot` —
    /// boots it, so it streams: the whole point is that it takes a while and the
    /// caller wants the progress. The created name is the last line of stdout.
    func createMachine(_ configuration: MachineCreateConfiguration) async throws -> String {
        var standardOutput = ""
        do {
            for try await event in cli.stream(.createMachine(configuration: configuration)) {
                switch event {
                case .standardOutput(let text):
                    standardOutput += text
                case .standardError:
                    break
                case .terminated(let exitCode):
                    guard exitCode == 0 else {
                        throw CLIError.nonZeroExit(
                            invocation: "container machine create",
                            exitCode: exitCode,
                            standardError: ""
                        )
                    }
                }
            }
        } catch {
            throw sanitizedMachineError(error)
        }
        let name = standardOutput
            .split(whereSeparator: \Character.isNewline)
            .last
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name, !name.isEmpty else {
            return configuration.name?.rawValue ?? ""
        }
        return name
    }

    func applyBootConfiguration(_ configuration: MachineSetConfiguration) async throws {
        do {
            _ = try await cli.run(.setMachineConfiguration(configuration))
        } catch {
            throw sanitizedMachineError(error)
        }
    }

    func setDefaultMachine(name: String) async throws {
        do {
            let identifier = try MachineIdentifier(validating: name)
            _ = try await cli.run(.setDefaultMachine(id: identifier))
        } catch {
            throw sanitizedMachineError(error)
        }
    }

    func stopMachine(name: String) async throws {
        do {
            let identifier = try MachineIdentifier(validating: name)
            _ = try await cli.run(.stopMachine(id: identifier))
        } catch {
            throw sanitizedMachineError(error)
        }
    }

    func deleteMachine(name: String) async throws {
        do {
            let identifier = try MachineIdentifier(validating: name)
            _ = try await cli.run(.deleteMachine(id: identifier))
        } catch {
            throw sanitizedMachineError(error)
        }
    }

    nonisolated func attachRun(
        _ configuration: MachineRunConfiguration,
        terminalSize: TerminalSize
    ) throws -> any InteractiveProcessSession {
        do {
            return try cli.attach(
                .machineRun(configuration: configuration),
                terminalSize: terminalSize
            )
        } catch {
            throw sanitizedMachineError(error)
        }
    }

    nonisolated func streamLogs(
        _ options: MachineLogOptions
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        let cli = cli
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in cli.stream(.machineLogs(options)) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: sanitizedMachineError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

nonisolated private func sanitizedMachineError(_ error: Error) -> Error {
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
