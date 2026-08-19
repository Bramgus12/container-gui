import Foundation
import Observation

nonisolated struct ContainerInspection: Equatable, Sendable {
    let details: ContainerDetails
    let rawJSON: String
}

nonisolated protocol ContainerDiagnosing: Sendable {
    func inspect(containerID: String) async throws -> ContainerInspection
    func streamLogs(
        containerID: String,
        follow: Bool,
        tail: Int
    ) -> AsyncThrowingStream<ProcessEvent, Error>
    func stats(containerID: String) async throws -> ContainerStats
}

actor CLIContainerDiagnosticsService: ContainerDiagnosing, ContainerStatsListing {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func inspect(containerID: String) async throws -> ContainerInspection {
        let identifier = try ContainerIdentifier(validating: containerID)
        let result = try await cli.run(.inspectContainer(id: identifier))
        let data = Data(result.standardOutput.utf8)

        do {
            let dto: ContainerDTO
            if let decoded = try? JSONDecoder().decode(ContainerDTO.self, from: data) {
                dto = decoded
            } else {
                let decoded = try JSONDecoder().decode([ContainerDTO].self, from: data)
                guard let first = decoded.first else {
                    throw CLIError.invalidOutput(
                        description: "Container inspection returned an empty array."
                    )
                }
                dto = first
            }
            guard let details = ContainerDetails(dto: dto) else {
                throw CLIError.invalidOutput(
                    description: "Container inspection did not contain an identifier."
                )
            }
            return ContainerInspection(
                details: details,
                rawJSON: result.standardOutput
            )
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidOutput(
                description: "Container inspection could not be decoded as JSON: \(error.localizedDescription)"
            )
        }
    }

    nonisolated func streamLogs(
        containerID: String,
        follow: Bool,
        tail: Int
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        do {
            let identifier = try ContainerIdentifier(validating: containerID)
            let cli = self.cli
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        var reconciler = ContainerLogSnapshotReconciler(tail: tail)

                        while !Task.isCancelled {
                            // Apple container's --follow implementation converts every
                            // partial file-system read into a printed line. Reading a
                            // complete snapshot preserves the real newline boundaries.
                            let result = try await cli.run(
                                .logs(id: identifier, follow: false, tail: nil)
                            )
                            if let appended = reconciler.consume(result.standardOutput),
                               !appended.isEmpty {
                                continuation.yield(.standardOutput(appended))
                            }

                            guard follow else { break }
                            try await Task.sleep(for: .milliseconds(500))
                        }

                        if !Task.isCancelled {
                            continuation.yield(.terminated(exitCode: 0))
                            continuation.finish()
                        }
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
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }

    func stats(containerID: String) async throws -> ContainerStats {
        let identifier = try ContainerIdentifier(validating: containerID)
        let result = try await cli.run(.stats(ids: [identifier]))
        let data = Data(result.standardOutput.utf8)

        do {
            let dtos: [ContainerStatsDTO]
            if let decoded = try? JSONDecoder().decode([ContainerStatsDTO].self, from: data) {
                dtos = decoded
            } else {
                dtos = [try JSONDecoder().decode(ContainerStatsDTO.self, from: data)]
            }
            guard let dto = dtos.first(where: { $0.id == containerID }) ?? dtos.first else {
                throw CLIError.invalidOutput(description: "Container stats returned no entries.")
            }
            return ContainerStats(dto: dto)
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidOutput(
                description: "Container stats could not be decoded as JSON: \(error.localizedDescription)"
            )
        }
    }

    func allStats() async throws -> [String: ContainerStats] {
        let result = try await cli.run(.stats(ids: []))
        let data = Data(result.standardOutput.utf8)

        do {
            let dtos: [ContainerStatsDTO]
            if let decoded = try? JSONDecoder().decode([ContainerStatsDTO].self, from: data) {
                dtos = decoded
            } else {
                dtos = [try JSONDecoder().decode(ContainerStatsDTO.self, from: data)]
            }
            return Dictionary(
                uniqueKeysWithValues: dtos.map { dto in
                    let stats = ContainerStats(dto: dto)
                    return (stats.id, stats)
                }
            )
        } catch {
            throw CLIError.invalidOutput(
                description: "Container stats could not be decoded as JSON: \(error.localizedDescription)"
            )
        }
    }
}

/// Turns complete log-file snapshots into an append-only stream while retaining
/// the requested number of initial lines. Complete snapshots are required because
/// `container logs --follow` currently treats partial reads as complete lines.
nonisolated struct ContainerLogSnapshotReconciler: Sendable {
    private let tail: Int
    private var previous = ""
    private var isInitialSnapshot = true

    init(tail: Int) {
        self.tail = max(0, tail)
    }

    mutating func consume(_ snapshot: String) -> String? {
        let snapshot = Self.removingCLIPrintTerminator(from: snapshot)
        defer {
            previous = snapshot
            isInitialSnapshot = false
        }

        if isInitialSnapshot {
            return Self.suffix(of: snapshot, lineLimit: tail)
        }
        guard snapshot != previous else { return nil }
        if snapshot.hasPrefix(previous) {
            return String(snapshot.dropFirst(previous.count))
        }

        // The log file can be replaced or truncated when a container restarts.
        // Start a fresh session rather than trying to splice unrelated bytes.
        return Self.suffix(of: snapshot, lineLimit: tail)
    }

    private static func removingCLIPrintTerminator(from text: String) -> String {
        guard text.last == "\n" else { return text }
        var result = String(text.dropLast())
        if result.last == "\r" {
            result.removeLast()
        }
        return result
    }

    private static func suffix(of text: String, lineLimit: Int) -> String {
        guard lineLimit > 0, !text.isEmpty else { return "" }

        var newlineCount = 0
        var boundary = text.startIndex
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            if text[index] == "\n" {
                if index == text.index(before: text.endIndex), newlineCount == 0 {
                    continue
                }
                newlineCount += 1
                if newlineCount == lineLimit {
                    boundary = text.index(after: index)
                    return String(text[boundary...])
                }
            }
        }
        return text
    }
}

enum ContainerInspectionState: Equatable {
    case loading
    case loaded(ContainerInspection)
    case failed(String)
}

@MainActor
@Observable
final class ContainerDetailModel {
    let containerID: String
    var logFilter: LogFilter = .all {
        didSet { publishLiveLogSnapshot() }
    }
    var logSearchText = "" {
        didSet { publishLiveLogSnapshot() }
    }
    var followsLogs = true {
        didSet {
            guard followsLogs != oldValue, isVisible else { return }
            startLogs()
        }
    }

    private(set) var inspectionState: ContainerInspectionState = .loading
    private(set) var logSnapshot = LogSnapshot.empty
    private(set) var isLogPaused = false
    private(set) var isLogStreaming = false
    private(set) var logError: String?
    private(set) var logCounts = LogCounts(all: 0, warnings: 0, errors: 0)
    private(set) var stats: ContainerStats?
    private(set) var statsError: String?
    private(set) var isStatsLoading = false

    private let service: any ContainerDiagnosing
    private let statsInterval: Duration
    private var isVisible = false
    private var liveLogBuffer: LogBuffer
    private var logStreamSession = 0
    private var logTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var inspectionGeneration = 0
    private var logGeneration = 0
    private var statsGeneration = 0

    init(
        containerID: String,
        service: any ContainerDiagnosing,
        maximumLogLines: Int = 5_000,
        maximumLogBytes: Int = 1_024 * 1_024,
        statsInterval: Duration = .seconds(3)
    ) {
        self.containerID = containerID
        self.service = service
        self.statsInterval = statsInterval
        self.liveLogBuffer = LogBuffer(
            maximumLines: max(1, maximumLogLines),
            maximumBytes: max(1, maximumLogBytes)
        )
    }

    func appear() async {
        isVisible = true
        updateVisibleWork()
        await loadInspection()
    }

    func disappear() {
        isVisible = false
        inspectionGeneration += 1
        cancelLogs()
        cancelStats()
    }

    func reloadInspection() async {
        inspectionState = .loading
        await loadInspection()
    }

    func toggleLogPause() {
        isLogPaused.toggle()
        if !isLogPaused {
            publishLiveLogSnapshot()
        }
    }

    func clearLogs() {
        liveLogBuffer.clear()
        publishLiveLogSnapshot()
    }

    private func loadInspection() async {
        inspectionGeneration += 1
        let generation = inspectionGeneration
        do {
            let inspection = try await service.inspect(containerID: containerID)
            guard generation == inspectionGeneration else { return }
            inspectionState = .loaded(inspection)
        } catch is CancellationError {
            return
        } catch CLIError.cancelled {
            return
        } catch {
            guard generation == inspectionGeneration else { return }
            inspectionState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    private func updateVisibleWork() {
        guard isVisible else { return }
        startLogs()
        startStats()
    }

    private func startLogs() {
        cancelLogs()
        let generation = logGeneration
        logStreamSession += 1
        let session = logStreamSession
        liveLogBuffer.startNewSession()
        if !isLogPaused {
            publishLiveLogSnapshot()
        }
        logError = nil
        isLogStreaming = true
        let stream = service.streamLogs(
            containerID: containerID,
            follow: followsLogs,
            tail: 500
        )

        logTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    guard generation == self.logGeneration,
                          session == self.logStreamSession
                    else { return }
                    switch event {
                    case .standardOutput(let text), .standardError(let text):
                        self.appendLog(text)
                    case .terminated(let exitCode) where exitCode != 0:
                        self.logError = "Logs exited with status \(exitCode)."
                    case .terminated:
                        break
                    }
                }
            } catch is CancellationError {
                // Leaving the tab or changing selection intentionally stops the process.
            } catch CLIError.cancelled {
                // ProcessContainerCLI normalizes stream cancellation.
            } catch {
                if generation == self.logGeneration, session == self.logStreamSession {
                    self.logError = DiagnosticSanitizer.sanitize(error.localizedDescription)
                }
            }
            if !Task.isCancelled,
               generation == self.logGeneration,
               session == self.logStreamSession {
                self.isLogStreaming = false
            }
        }
    }

    private func cancelLogs() {
        logGeneration += 1
        logTask?.cancel()
        logTask = nil
        isLogStreaming = false
    }

    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        liveLogBuffer.append(text)
        if !isLogPaused {
            publishLiveLogSnapshot()
        }
    }

    private func publishLiveLogSnapshot() {
        logCounts = liveLogBuffer.counts
        logSnapshot = liveLogBuffer.snapshot(filter: logFilter, matching: logSearchText)
    }

    private func startStats() {
        cancelStats()
        let generation = statsGeneration
        statsError = nil
        statsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.isStatsLoading = self.stats == nil
                do {
                    let stats = try await self.service.stats(containerID: self.containerID)
                    guard generation == self.statsGeneration else { return }
                    self.stats = stats
                    self.statsError = nil
                } catch is CancellationError {
                    break
                } catch CLIError.cancelled {
                    break
                } catch {
                    guard generation == self.statsGeneration else { return }
                    self.statsError = DiagnosticSanitizer.sanitize(error.localizedDescription)
                }
                self.isStatsLoading = false

                do {
                    try await Task.sleep(for: self.statsInterval)
                } catch {
                    break
                }
            }
            if generation == self.statsGeneration {
                self.isStatsLoading = false
            }
        }
    }

    private func cancelStats() {
        statsGeneration += 1
        statsTask?.cancel()
        statsTask = nil
        isStatsLoading = false
    }
}
