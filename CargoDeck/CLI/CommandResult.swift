import Foundation

nonisolated struct CommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
    let duration: Duration
    let invocation: String

    var succeeded: Bool {
        exitCode == 0
    }
}
