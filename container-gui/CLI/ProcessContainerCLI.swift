import Foundation

actor ProcessContainerCLI: ContainerCLI {
    static let defaultOutputLimit = 8 * 1_024 * 1_024

    private let executableURL: URL
    private let environment: [String: String]
    private let outputLimit: Int
    private let timeout: Duration?

    init(
        executableURL: URL,
        environment: [String: String] = ProcessContainerCLI.defaultEnvironment(),
        outputLimit: Int = ProcessContainerCLI.defaultOutputLimit,
        timeout: Duration? = .seconds(60)
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.outputLimit = max(1, outputLimit)
        self.timeout = timeout
    }

    func run(_ command: ContainerCommand) async throws -> CommandResult {
        do {
            try validateExecutable()

            let request = ProcessRequest(
                executableURL: executableURL,
                arguments: command.arguments,
                environment: environment,
                outputLimit: outputLimit,
                invocation: Self.displayInvocation(
                    executableURL: executableURL,
                    arguments: command.arguments
                )
            )

            let result: CommandResult
            if let timeout {
                result = try await run(request, timeout: timeout)
            } else {
                result = try await Self.execute(request)
            }

            guard result.succeeded else {
                throw CLIError.nonZeroExit(
                    invocation: result.invocation,
                    exitCode: result.exitCode,
                    standardError: result.standardError,
                    standardOutput: result.standardOutput
                )
            }
            return result
        } catch is CancellationError {
            throw CLIError.cancelled
        }
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await self.makeRequest(for: command)
                    let exitCode = try await Self.executeStreaming(
                        request,
                        continuation: continuation
                    )
                    try Task.checkCancellation()
                    continuation.yield(.terminated(exitCode: exitCode))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CLIError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func makeRequest(for command: ContainerCommand) throws -> ProcessRequest {
        try validateExecutable()
        return ProcessRequest(
            executableURL: executableURL,
            arguments: command.arguments,
            environment: environment,
            outputLimit: outputLimit,
            invocation: Self.displayInvocation(
                executableURL: executableURL,
                arguments: command.arguments
            )
        )
    }

    private static func executeStreaming(
        _ request: ProcessRequest,
        continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation
    ) async throws -> Int32 {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let session = ProcessSession(process: process)
        let drainQueue = DispatchQueue(label: "ProcessContainerCLI.streaming-pipe-drain")

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            drainQueue.async {
                continuation.yield(.standardOutput(String(decoding: data, as: UTF8.self)))
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            drainQueue.async {
                continuation.yield(.standardError(String(decoding: data, as: UTF8.self)))
            }
        }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { processContinuation in
                    process.terminationHandler = { process in
                        standardOutput.fileHandleForReading.readabilityHandler = nil
                        standardError.fileHandleForReading.readabilityHandler = nil

                        drainQueue.async {
                            if let remaining = try? standardOutput.fileHandleForReading.readToEnd(),
                               !remaining.isEmpty {
                                continuation.yield(
                                    .standardOutput(String(decoding: remaining, as: UTF8.self))
                                )
                            }
                            if let remaining = try? standardError.fileHandleForReading.readToEnd(),
                               !remaining.isEmpty {
                                continuation.yield(
                                    .standardError(String(decoding: remaining, as: UTF8.self))
                                )
                            }
                            processContinuation.resume(returning: process.terminationStatus)
                        }
                    }

                    do {
                        try session.launch()
                    } catch {
                        standardOutput.fileHandleForReading.readabilityHandler = nil
                        standardError.fileHandleForReading.readabilityHandler = nil
                        processContinuation.resume(
                            throwing: CLIError.launchFailed(message: error.localizedDescription)
                        )
                    }
                }
            } onCancel: {
                session.cancel()
            }
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    private func run(
        _ request: ProcessRequest,
        timeout: Duration
    ) async throws -> CommandResult {
        try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                try await Self.execute(request)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CLIError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CLIError.cancelled
            }
            return result
        }
    }

    private func validateExecutable() throws {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            throw CLIError.executableIsNotAbsolute(executableURL)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: executableURL.path,
            isDirectory: &isDirectory
        ) else {
            throw CLIError.executableNotFound(executableURL)
        }
        guard !isDirectory.boolValue else {
            throw CLIError.executableIsNotAFile(executableURL)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CLIError.executableIsNotExecutable(executableURL)
        }
    }

    private static func execute(_ request: ProcessRequest) async throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let output = BoundedProcessOutput(limit: request.outputLimit)
        let session = ProcessSession(process: process)
        let drainQueue = DispatchQueue(label: "ProcessContainerCLI.pipe-drain")
        let clock = ContinuousClock()
        let start = clock.now

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            drainQueue.async {
                if output.append(data, to: .standardOutput) {
                    session.cancel()
                }
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            drainQueue.async {
                if output.append(data, to: .standardError) {
                    session.cancel()
                }
            }
        }

        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { process in
                        standardOutput.fileHandleForReading.readabilityHandler = nil
                        standardError.fileHandleForReading.readabilityHandler = nil

                        drainQueue.async {
                            if let remaining = try? standardOutput.fileHandleForReading.readToEnd() {
                                _ = output.append(remaining, to: .standardOutput)
                            }
                            if let remaining = try? standardError.fileHandleForReading.readToEnd() {
                                _ = output.append(remaining, to: .standardError)
                            }
                            continuation.resume(returning: process.terminationStatus)
                        }
                    }

                    do {
                        try session.launch()
                    } catch {
                        standardOutput.fileHandleForReading.readabilityHandler = nil
                        standardError.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(
                            throwing: CLIError.launchFailed(message: error.localizedDescription)
                        )
                    }
                }
            } onCancel: {
                session.cancel()
            }
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if output.exceededLimit {
            throw CLIError.outputLimitExceeded(limit: request.outputLimit)
        }

        return CommandResult(
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            exitCode: exitCode,
            duration: start.duration(to: clock.now),
            invocation: request.invocation
        )
    }

    static func defaultEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var result = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": inherited["LC_ALL"] ?? "en_US.UTF-8",
        ]
        for key in ["HOME", "SSH_AUTH_SOCK"] {
            if let value = inherited[key], !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    static func displayInvocation(
        executableURL: URL,
        arguments: [String]
    ) -> String {
        displayInvocation(executable: executableURL.path, arguments: arguments)
    }

    static func displayInvocation(
        executable: String,
        arguments: [String]
    ) -> String {
        let sanitized = sanitizedArguments(arguments)
        return ([executable] + sanitized)
            .map(displayArgument)
            .joined(separator: " ")
    }

    private static func sanitizedArguments(_ arguments: [String]) -> [String] {
        var result = arguments
        var index = 0

        while index < result.count {
            guard result[index] == "--env", index + 1 < result.count else {
                index += 1
                continue
            }

            let assignment = result[index + 1]
            if let separator = assignment.firstIndex(of: "=") {
                let key = String(assignment[..<separator])
                if isSensitiveEnvironmentKey(key) {
                    result[index + 1] = "\(key)=<redacted>"
                }
            }
            index += 2
        }
        return result
    }

    private static func isSensitiveEnvironmentKey(_ key: String) -> Bool {
        let normalized = key.uppercased()
        return ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "PRIVATE_KEY", "CREDENTIAL", "AUTH"]
            .contains { normalized.contains($0) }
    }

    private static func displayArgument(_ argument: String) -> String {
        let safe = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "@%_+=:,./-")
        )
        if !argument.isEmpty,
           argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

nonisolated private struct ProcessRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let outputLimit: Int
    let invocation: String
}

nonisolated private final class ProcessSession: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancellationRequested = false

    init(process: Process) {
        self.process = process
    }

    func launch() throws {
        lock.lock()
        defer { lock.unlock() }

        if cancellationRequested {
            throw CancellationError()
        }
        try process.run()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let isRunning = process.isRunning
        if isRunning {
            process.terminate()
        }
        lock.unlock()
    }
}

nonisolated private final class BoundedProcessOutput: @unchecked Sendable {
    enum Stream {
        case standardOutput
        case standardError
    }

    private let lock = NSLock()
    private let limit: Int
    private var retainedBytes = 0
    private var outputData = Data()
    private var errorData = Data()
    private var didExceedLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    @discardableResult
    func append(_ data: Data, to stream: Stream) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !data.isEmpty else { return didExceedLimit }
        let available = max(0, limit - retainedBytes)
        let retained = data.prefix(available)
        retainedBytes += retained.count

        switch stream {
        case .standardOutput:
            outputData.append(retained)
        case .standardError:
            errorData.append(retained)
        }
        if retained.count < data.count {
            didExceedLimit = true
        }
        return didExceedLimit
    }

    var exceededLimit: Bool {
        lock.withLock { didExceedLimit }
    }

    var standardOutput: String {
        lock.withLock { String(decoding: outputData, as: UTF8.self) }
    }

    var standardError: String {
        lock.withLock { String(decoding: errorData, as: UTF8.self) }
    }
}
