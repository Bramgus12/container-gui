nonisolated enum ProcessEvent: Equatable, Sendable {
    case standardOutput(String)
    case standardError(String)
    case terminated(exitCode: Int32)
}
