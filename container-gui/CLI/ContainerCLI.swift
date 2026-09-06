import Foundation

nonisolated protocol ContainerCLI: Sendable {
    func run(_ command: ContainerCommand) async throws -> CommandResult
    func stream(_ command: ContainerCommand) -> AsyncThrowingStream<ProcessEvent, Error>

    /// Runs a command, optionally writing `standardInput` to the child and then
    /// closing the pipe. The payload is bytes rather than a `String` so a secret
    /// has one representation with one lifetime, and so it can never be
    /// mistaken for something argument-shaped.
    ///
    /// The only caller is registry login with `--password-stdin`.
    func run(
        _ command: ContainerCommand,
        standardInput: Data?
    ) async throws -> CommandResult

    /// Starts a command whose standard input stays open. A terminal size
    /// allocates a pseudo-terminal; without one the child gets plain pipes.
    func attach(
        _ command: ContainerCommand,
        terminalSize: TerminalSize?
    ) throws -> any InteractiveProcessSession
}

/// `nonisolated` because the project defaults to `MainActor` isolation: without
/// it this default implementation would be main-actor-bound, and every actor
/// conformance would be crossing isolation to reach it.
nonisolated extension ContainerCLI {
    /// Stubs and fixtures inherit the plain path for the nil case, so adding
    /// this requirement does not force boilerplate on every existing test
    /// double. Only a CLI that actually implements it can carry a payload.
    func run(
        _ command: ContainerCommand,
        standardInput: Data?
    ) async throws -> CommandResult {
        guard standardInput == nil else {
            throw CLIError.launchFailed(
                message: "This container CLI does not support standard input."
            )
        }
        return try await run(command)
    }
}

nonisolated extension ContainerCLI {
    /// Only the process-backed CLI can hold standard input open. Stubs and
    /// fixtures inherit a refusal rather than a silent no-op session.
    func attach(
        _ command: ContainerCommand,
        terminalSize: TerminalSize?
    ) throws -> any InteractiveProcessSession {
        throw CLIError.launchFailed(
            message: "This container CLI does not support interactive sessions."
        )
    }
}
