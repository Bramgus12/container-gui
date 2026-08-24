import Foundation

nonisolated struct ContainerPruneResult: Equatable, Sendable {
    let removedContainerIDs: [String]
}

nonisolated protocol ContainerLifecycleManaging: Sendable {
    /// Creates a container without starting it and returns its identifier.
    func createContainer(_ configuration: RunConfiguration) async throws -> String

    func copy(_ operation: CopyOperation) async throws

    func exportContainer(
        id: String,
        to output: String
    ) -> AsyncThrowingStream<ProcessEvent, Error>

    func pruneContainers() async throws -> ContainerPruneResult

    /// One-shot exec: the command runs to completion and its output is streamed.
    func exec(
        containerID: String,
        configuration: ExecConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error>

    /// Interactive exec: standard input stays open for the caller to write to.
    func attachExec(
        containerID: String,
        configuration: ExecConfiguration,
        terminalSize: TerminalSize?
    ) throws -> any InteractiveProcessSession
}

nonisolated struct CLIContainerLifecycleService: ContainerLifecycleManaging {
    let cli: any ContainerCLI

    // Every command here can outlive the 60-second timeout that `run(_:)`
    // applies — creating pulls the image when it is missing, copying moves
    // arbitrarily large files, and pruning deletes one container at a time — so
    // they all go through the untimed streaming path.

    func createContainer(_ configuration: RunConfiguration) async throws -> String {
        let output = try await collectOutput(of: .create(configuration))
        let identifier = output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { (try? ContainerIdentifier(validating: $0)) != nil }

        guard let identifier else {
            throw CLIError.invalidOutput(
                description: "Creating the container did not report an identifier."
            )
        }
        return identifier
    }

    func copy(_ operation: CopyOperation) async throws {
        _ = try await collectOutput(of: .copy(operation))
    }

    func exportContainer(
        id: String,
        to output: String
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        do {
            let identifier = try ContainerIdentifier(validating: id)
            let path = try LocalPath(validating: output, field: "Export path")
            return cli.stream(.exportContainer(id: identifier, output: path))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func pruneContainers() async throws -> ContainerPruneResult {
        let output = try await collectOutput(of: .pruneContainers)
        return ContainerPruneResult(removedContainerIDs: Self.prunedContainerIDs(from: output))
    }

    func exec(
        containerID: String,
        configuration: ExecConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        do {
            let identifier = try ContainerIdentifier(validating: containerID)
            return cli.stream(.exec(id: identifier, configuration: configuration))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func attachExec(
        containerID: String,
        configuration: ExecConfiguration,
        terminalSize: TerminalSize?
    ) throws -> any InteractiveProcessSession {
        let identifier = try ContainerIdentifier(validating: containerID)
        return try cli.attach(
            .exec(id: identifier, configuration: configuration),
            terminalSize: terminalSize
        )
    }

    /// `container prune` prints one identifier per line. Anything that is not a
    /// valid identifier is a heading or a summary line, and is dropped.
    nonisolated static func prunedContainerIDs(from output: String) -> [String] {
        output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                (try? ContainerIdentifier(validating: line)) != nil
            }
    }

    private func collectOutput(of command: ContainerCommand) async throws -> String {
        var standardOutput = ""
        var standardError = ""
        do {
            for try await event in cli.stream(command) {
                switch event {
                case .standardOutput(let text):
                    standardOutput.append(text)
                case .standardError(let text):
                    standardError.append(text)
                case .terminated(let exitCode) where exitCode != 0:
                    throw CLIError.nonZeroExit(
                        invocation: ProcessContainerCLI.displayInvocation(
                            executable: "container",
                            arguments: command.arguments
                        ),
                        exitCode: exitCode,
                        standardError: standardError,
                        standardOutput: standardOutput
                    )
                case .terminated:
                    break
                }
            }
        } catch {
            throw sanitizedLifecycleError(error)
        }
        return standardOutput
    }
}

nonisolated private func sanitizedLifecycleError(_ error: Error) -> Error {
    guard let cliError = error as? CLIError else {
        if error is CancellationError { return error }
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
