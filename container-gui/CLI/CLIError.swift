import Foundation

enum CLIError: Error, Equatable, Sendable {
    case executableNotFound(URL)
    case executableIsNotAFile(URL)
    case executableIsNotExecutable(URL)
    case launchFailed(message: String)
    case nonZeroExit(invocation: String, exitCode: Int32, standardError: String)
    case invalidOutput(description: String)
    case outputLimitExceeded(limit: Int)
    case cancelled
}

extension CLIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executableNotFound(let url):
            "Container executable was not found at \(url.path)."
        case .executableIsNotAFile(let url):
            "The selected container executable is not a regular file: \(url.path)."
        case .executableIsNotExecutable(let url):
            "The selected container executable cannot be executed: \(url.path)."
        case .launchFailed(let message):
            "Container could not be launched: \(message)"
        case .nonZeroExit(_, let exitCode, let standardError):
            standardError.isEmpty
                ? "Container exited with status \(exitCode)."
                : "Container exited with status \(exitCode): \(standardError)"
        case .invalidOutput(let description):
            "Container returned invalid output: \(description)"
        case .outputLimitExceeded(let limit):
            "Container output exceeded the \(limit)-byte safety limit."
        case .cancelled:
            "The operation was cancelled."
        }
    }
}
