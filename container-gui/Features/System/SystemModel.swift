import Foundation
import Observation

nonisolated struct SystemSnapshot: Equatable, Sendable {
    let versions: SystemVersion
    let status: SystemStatus
    let diskUsage: SystemDiskUsage
}

nonisolated protocol SystemManaging: Sendable {
    func loadSnapshot() async throws -> SystemSnapshot
    func loadRecentLogs() async throws -> String
    func startService() async throws
    func stopService() async throws
}

nonisolated struct OperationFailureRecord: Equatable, Sendable {
    let date: Date
    let operation: String
    let summary: String
    let invocation: String?
    let exitCode: Int32?

    init(operation: String, error: Error, date: Date = Date()) {
        self.date = date
        self.operation = DiagnosticSanitizer.sanitize(operation)
        self.summary = DiagnosticSanitizer.sanitize(error.localizedDescription)
        if case .nonZeroExit(let invocation, let exitCode, _) = error as? CLIError {
            self.invocation = DiagnosticSanitizer.sanitize(invocation)
            self.exitCode = exitCode
        } else {
            invocation = nil
            exitCode = nil
        }
    }
}

@MainActor
final class OperationFailureLog {
    private let limit: Int
    private(set) var records: [OperationFailureRecord] = []

    init(limit: Int = 20) {
        self.limit = max(1, limit)
    }

    func record(operation: String, error: Error) {
        guard !(error is CancellationError), error as? CLIError != .cancelled else {
            return
        }
        records.append(OperationFailureRecord(operation: operation, error: error))
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
    }
}

actor CLISystemService: SystemManaging {
    static let maximumLogLines = 2_000
    static let maximumLogBytes = 256 * 1_024

    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func loadSnapshot() async throws -> SystemSnapshot {
        async let versionResult = cli.run(.systemVersion)
        async let statusResult = cli.run(.systemStatus)
        async let diskResult = cli.run(.systemDiskUsage)

        do {
            let (versionCommand, statusCommand, diskCommand) = try await (
                versionResult,
                statusResult,
                diskResult
            )
            let decoder = JSONDecoder()
            let components = try decoder.decode(
                [SystemVersionDTO].self,
                from: Data(versionCommand.standardOutput.utf8)
            )
            let statusDTO = try decoder.decode(
                SystemStatusDTO.self,
                from: Data(statusCommand.standardOutput.utf8)
            )
            guard statusDTO.healthy != nil || statusDTO.status != nil else {
                throw CLIError.invalidOutput(
                    description: "The system status response contained no status."
                )
            }
            let usage = try SystemDiskUsage.decode(
                from: Data(diskCommand.standardOutput.utf8)
            )
            return SystemSnapshot(
                versions: SystemVersion(components: components),
                status: SystemStatus(dto: statusDTO),
                diskUsage: usage
            )
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidOutput(
                description: "System information could not be decoded: \(error.localizedDescription)"
            )
        }
    }

    func loadRecentLogs() async throws -> String {
        let period = try SystemLogPeriod(value: 15, unit: .minutes)
        let result = try await cli.run(.systemLogs(follow: false, last: period))
        return Self.boundedSanitizedLogs(result.standardOutput)
    }

    func startService() async throws {
        _ = try await cli.run(.systemStart)
    }

    func stopService() async throws {
        _ = try await cli.run(.systemStop)
    }

    nonisolated static func boundedSanitizedLogs(_ value: String) -> String {
        let sanitized = DiagnosticSanitizer.sanitize(value)
        let lines = sanitized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var retained = Array(lines.suffix(maximumLogLines))
        var result = retained.joined(separator: "\n")

        while result.utf8.count > maximumLogBytes, retained.count > 1 {
            retained.removeFirst()
            result = retained.joined(separator: "\n")
        }
        if result.utf8.count > maximumLogBytes {
            let bytes = Array(result.utf8.suffix(maximumLogBytes))
            result = String(decoding: bytes, as: UTF8.self)
        }
        return result
    }
}

enum SystemLoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum SystemServiceOperation: String, Equatable, Sendable {
    case start = "Starting service"
    case stop = "Stopping service"

    var localizedDescription: LocalizedStringResource {
        switch self {
        case .start: "Starting service"
        case .stop: "Stopping service"
        }
    }
}

@MainActor
@Observable
final class SystemModel {
    private(set) var versions: SystemVersion
    private(set) var status: SystemStatus
    private(set) var diskUsage: SystemDiskUsage?
    private(set) var logs = ""
    private(set) var snapshotState: SystemLoadingState = .idle
    private(set) var logsState: SystemLoadingState = .idle
    private(set) var serviceOperation: SystemServiceOperation?
    private(set) var actionError: String?
    private(set) var didCopyDiagnostics = false

    private let service: any SystemManaging
    private let failureLog: OperationFailureLog
    private let diagnosticsCopier: any DiagnosticsCopying
    private let executableURL: URL
    private var refreshGeneration = 0

    init(
        context: PreflightContext,
        service: any SystemManaging,
        failureLog: OperationFailureLog,
        diagnosticsCopier: (any DiagnosticsCopying)? = nil
    ) {
        versions = context.versions
        status = context.status
        executableURL = context.executableURL
        self.service = service
        self.failureLog = failureLog
        self.diagnosticsCopier = diagnosticsCopier ?? SystemDiagnosticsCopier()
    }

    var isWorking: Bool {
        snapshotState == .loading || logsState == .loading || serviceOperation != nil
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        snapshotState = .loading
        logsState = .loading
        actionError = nil
        didCopyDiagnostics = false

        async let snapshotResult: Result<SystemSnapshot, Error> = captureResult {
            try await self.service.loadSnapshot()
        }
        async let logsResult: Result<String, Error> = captureResult {
            try await self.service.loadRecentLogs()
        }

        let (snapshot, recentLogs) = await (snapshotResult, logsResult)
        guard generation == refreshGeneration else { return }

        switch snapshot {
        case .success(let value):
            versions = value.versions
            status = value.status
            diskUsage = value.diskUsage
            snapshotState = .loaded
        case .failure(let error):
            if isCancellation(error) {
                snapshotState = diskUsage == nil ? .idle : .loaded
            } else {
                failureLog.record(operation: "Refresh system information", error: error)
                snapshotState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
            }
        }

        switch recentLogs {
        case .success(let value):
            logs = value
            logsState = .loaded
        case .failure(let error):
            if isCancellation(error) {
                logsState = logs.isEmpty ? .idle : .loaded
            } else {
                failureLog.record(operation: "Load service logs", error: error)
                logsState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
            }
        }
    }

    func perform(_ operation: SystemServiceOperation) async {
        guard serviceOperation == nil else { return }
        actionError = nil
        didCopyDiagnostics = false
        serviceOperation = operation
        defer { serviceOperation = nil }

        do {
            switch operation {
            case .start:
                try await service.startService()
            case .stop:
                try await service.stopService()
                status = SystemStatus(dto: SystemStatusDTO(
                    status: "stopped",
                    healthy: false,
                    version: status.version,
                    message: "The service is stopped."
                ))
            }
            await refresh()
        } catch {
            guard !isCancellation(error) else { return }
            failureLog.record(operation: operation.rawValue, error: error)
            actionError = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    var diagnosticsText: String {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = info?["CFBundleVersion"] as? String ?? "unknown"
        var lines = [
            "Container GUI diagnostics",
            "App version: \(appVersion) (\(appBuild))",
            "OS: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(PlatformSnapshot.current.architecture)",
            "Executable: \(executableURL.path)",
            "Service health: \(status.isRunning ? "running" : "stopped")",
            "CLI version: \(versions.cli?.version ?? "unavailable")",
            "Server version: \(versions.server?.version ?? status.version ?? "unavailable")",
        ]

        if failureLog.records.isEmpty {
            lines.append("Recent operation failures: none")
        } else {
            lines.append("Recent operation failures:")
            let formatter = ISO8601DateFormatter()
            for record in failureLog.records {
                lines.append("- \(formatter.string(from: record.date)) — \(record.operation): \(record.summary)")
                if let invocation = record.invocation {
                    lines.append("  Command: \(invocation)")
                }
                if let exitCode = record.exitCode {
                    lines.append("  Exit code: \(exitCode)")
                }
            }
        }
        return DiagnosticSanitizer.sanitize(lines.joined(separator: "\n"))
    }

    func copyDiagnostics() {
        diagnosticsCopier.copy(diagnosticsText)
        didCopyDiagnostics = true
    }

    func dismissActionError() {
        actionError = nil
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || error as? CLIError == .cancelled
    }
}

nonisolated private func captureResult<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}
