import Foundation

nonisolated protocol ContainerCLI: Sendable {
    func run(_ command: ContainerCommand) async throws -> CommandResult
    func stream(_ command: ContainerCommand) -> AsyncThrowingStream<ProcessEvent, Error>

    /// Starts a command whose standard input stays open. A terminal size
    /// allocates a pseudo-terminal; without one the child gets plain pipes.
    func attach(
        _ command: ContainerCommand,
        terminalSize: TerminalSize?
    ) throws -> any InteractiveProcessSession
}

extension ContainerCLI {
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
