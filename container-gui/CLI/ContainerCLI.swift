import Foundation

nonisolated protocol ContainerCLI: Sendable {
    func run(_ command: ContainerCommand) async throws -> CommandResult
    func stream(_ command: ContainerCommand) -> AsyncThrowingStream<ProcessEvent, Error>
}
