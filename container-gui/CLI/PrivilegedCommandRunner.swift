import Foundation

/// A command the app runs as root once macOS has authenticated the user.
///
/// The app is notarized, hardened, and unsandboxed, so it can ask macOS for an
/// administrator authentication and run a single command with the result. The
/// commands this covers are the ones the Apple Container CLI refuses to run as
/// the logged-in user: creating and deleting `/etc/resolver` entries.
nonisolated struct PrivilegedCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    /// The sentence macOS shows above the password field. The dialog is raised
    /// by `osascript` rather than by the app, so the prompt is the only place
    /// the reason for the request can be stated.
    let prompt: String

    /// The equivalent Terminal command, so a failure can name what was run and
    /// the user can repeat it by hand.
    var displayInvocation: String {
        "sudo " + ProcessContainerCLI.displayInvocation(
            executableURL: executableURL,
            arguments: arguments
        )
    }
}

nonisolated protocol PrivilegedCommandRunning: Sendable {
    /// Runs the command as root and returns its standard output.
    func run(_ command: PrivilegedCommand) async throws -> String
}

nonisolated enum PrivilegedCommandError: Error, Equatable, Sendable {
    /// The user dismissed the macOS password dialog, or gave up after three
    /// wrong passwords. Callers treat this as "nothing happened", not a failure.
    case cancelled
    case launchFailed(message: String)
    case failed(invocation: String, exitCode: Int32, message: String)
}

extension PrivilegedCommandError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelled:
            "The administrator request was cancelled."
        case .launchFailed(let message):
            "The administrator request could not be started: \(message)"
        case .failed(_, let exitCode, let message):
            message.isEmpty
                ? "The administrator command exited with status \(exitCode)."
                : message
        }
    }
}

/// Runs a command as root through `osascript`'s `do shell script … with
/// administrator privileges`, which raises the standard macOS authentication
/// dialog and runs the command through the Security Agent.
///
/// The alternative — a `SMAppService` privileged helper — installs a permanent
/// root daemon and asks the user to approve it in Login Items. That is a heavy
/// trade for two commands a user runs a handful of times, so the app takes the
/// per-command authentication instead: nothing is installed, and every run is
/// authorised on its own.
actor OSAScriptPrivilegedCommandRunner: PrivilegedCommandRunning {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    /// `do shell script` inherits very little, so the command states the
    /// environment it needs. Both values match what `sudo` hands a command on a
    /// stock macOS install, so running from the app and running the copied
    /// command in Terminal leave the same files behind.
    static let path = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let outputLimit = 64 * 1_024

    private let homeDirectory: String

    init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDirectory = homeDirectory
    }

    func run(_ command: PrivilegedCommand) async throws -> String {
        let script = Self.script(for: command, homeDirectory: homeDirectory)
        let result = try await Self.execute(script)
        guard result.exitCode == 0 else {
            throw Self.failure(
                standardError: result.standardError,
                exitCode: result.exitCode,
                invocation: command.displayInvocation
            )
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Script

    static func script(for command: PrivilegedCommand, homeDirectory: String) -> String {
        let shellCommand = self.shellCommand(for: command, homeDirectory: homeDirectory)
        return "do shell script \(literal(shellCommand))"
            + " with prompt \(literal(command.prompt))"
            + " with administrator privileges"
    }

    static func shellCommand(for command: PrivilegedCommand, homeDirectory: String) -> String {
        let words = [
            "/usr/bin/env",
            "HOME=\(homeDirectory)",
            "PATH=\(path)",
            command.executableURL.path,
        ] + command.arguments
        return words.map(quoted).joined(separator: " ")
    }

    /// Single quotes survive every byte a shell would otherwise expand, so every
    /// word is quoted whatever it holds.
    static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// AppleScript string literals escape only the backslash and the quote.
    static func literal(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "\"", with: #"\""#)
        return "\"\(escaped)\""
    }

    // MARK: - Failures

    /// `osascript` reports a failed script as
    /// `<file>:<range>: execution error: <message> (<number>)`, where the number
    /// is the shell's exit status, or `-128` when the user cancelled.
    static func failure(
        standardError: String,
        exitCode: Int32,
        invocation: String
    ) -> PrivilegedCommandError {
        let text = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.range(
            of: #"execution error:[\s\S]*\(-?\d+\)$"#,
            options: [.regularExpression]
        ) else {
            return .failed(invocation: invocation, exitCode: exitCode, message: text)
        }

        var detail = String(text[match]).replacingOccurrences(
            of: #"^execution error:\s*"#,
            with: "",
            options: .regularExpression
        )
        var code = exitCode
        if let suffix = detail.range(of: #"\s*\((-?\d+)\)$"#, options: .regularExpression) {
            let digits = detail[suffix].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            code = Int32(digits) ?? exitCode
            detail.removeSubrange(suffix)
        }
        guard code != -128 else { return .cancelled }
        return .failed(
            invocation: invocation,
            exitCode: code,
            message: detail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Process

    private static func execute(_ script: String) async throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let output = PrivilegedOutput(limit: outputLimit)
        let drainQueue = DispatchQueue(label: "OSAScriptPrivilegedCommandRunner.pipe-drain")
        let clock = ContinuousClock()
        let start = clock.now

        process.executableURL = executableURL
        process.arguments = ["-e", script]
        // The command states the environment it runs under, so nothing of the
        // app's own environment is passed through to the script.
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            drainQueue.async { output.append(data, isError: false) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            drainQueue.async { output.append(data, isError: true) }
        }

        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { process in
                        standardOutput.fileHandleForReading.readabilityHandler = nil
                        standardError.fileHandleForReading.readabilityHandler = nil
                        drainQueue.async {
                            if let rest = try? standardOutput.fileHandleForReading.readToEnd() {
                                output.append(rest, isError: false)
                            }
                            if let rest = try? standardError.fileHandleForReading.readToEnd() {
                                output.append(rest, isError: true)
                            }
                            continuation.resume(returning: process.terminationStatus)
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        standardOutput.fileHandleForReading.readabilityHandler = nil
                        standardError.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(
                            throwing: PrivilegedCommandError.launchFailed(
                                message: error.localizedDescription
                            )
                        )
                    }
                }
            } onCancel: {
                // Takes the password dialog down with the process that raised it.
                if process.isRunning { process.terminate() }
            }
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        if Task.isCancelled { throw PrivilegedCommandError.cancelled }
        return CommandResult(
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            exitCode: exitCode,
            duration: start.duration(to: clock.now),
            invocation: "osascript"
        )
    }
}

nonisolated private final class PrivilegedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var outputData = Data()
    private var errorData = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return }
        let retained = data.prefix(max(0, limit - outputData.count - errorData.count))
        if isError { errorData.append(retained) } else { outputData.append(retained) }
    }

    var standardOutput: String { lock.withLock { String(decoding: outputData, as: UTF8.self) } }
    var standardError: String { lock.withLock { String(decoding: errorData, as: UTF8.self) } }
}
