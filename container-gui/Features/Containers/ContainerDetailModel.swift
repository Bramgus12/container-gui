import Foundation
import Observation

nonisolated struct ContainerInspection: Equatable, Sendable {
    let details: ContainerDetails
    let formattedJSON: String
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

actor CLIContainerDiagnosticsService: ContainerDiagnosing {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func inspect(containerID: String) async throws -> ContainerInspection {
        let identifier = try ContainerIdentifier(validating: containerID)
        let result = try await cli.run(.inspectContainer(id: identifier))
        let data = Data(result.standardOutput.utf8)

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let formattedData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
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
                formattedJSON: String(decoding: formattedData, as: UTF8.self)
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
            let logTail = try LogTail(lines: tail)
            return cli.stream(.logs(id: identifier, follow: follow, tail: logTail))
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
}

enum ContainerDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case logs = "Logs"
    case inspect = "Inspect"
    case stats = "Stats"

    var id: Self { self }
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
    var selectedTab: ContainerDetailTab = .overview {
        didSet { updateVisibleWork() }
    }
    var followsLogs = true
    var autoscrollsLogs = true

    private(set) var inspectionState: ContainerInspectionState = .loading
    private(set) var logText = ""
    private(set) var logRevision = 0
    private(set) var isLogPaused = false
    private(set) var isLogStreaming = false
    private(set) var logError: String?
    private(set) var stats: ContainerStats?
    private(set) var statsError: String?
    private(set) var isStatsLoading = false

    private let service: any ContainerDiagnosing
    private let maximumLogLines: Int
    private let maximumLogBytes: Int
    private let statsInterval: Duration
    private var isVisible = false
    private var pendingLogText = ""
    private var logTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    init(
        containerID: String,
        service: any ContainerDiagnosing,
        maximumLogLines: Int = 5_000,
        maximumLogBytes: Int = 1_024 * 1_024,
        statsInterval: Duration = .seconds(3)
    ) {
        self.containerID = containerID
        self.service = service
        self.maximumLogLines = max(1, maximumLogLines)
        self.maximumLogBytes = max(1, maximumLogBytes)
        self.statsInterval = statsInterval
    }

    func appear() async {
        isVisible = true
        updateVisibleWork()
        await loadInspection()
    }

    func disappear() {
        isVisible = false
        cancelLogs()
        cancelStats()
    }

    func reloadInspection() async {
        inspectionState = .loading
        await loadInspection()
    }

    func setFollowLogs(_ follows: Bool) {
        guard followsLogs != follows else { return }
        followsLogs = follows
        if isVisible, selectedTab == .logs {
            startLogs()
        }
    }

    func toggleLogPause() {
        isLogPaused.toggle()
        guard !isLogPaused, !pendingLogText.isEmpty else { return }
        appendToVisibleLog(pendingLogText)
        pendingLogText = ""
    }

    func clearLogs() {
        logText = ""
        pendingLogText = ""
        logRevision += 1
    }

    private func loadInspection() async {
        do {
            inspectionState = .loaded(try await service.inspect(containerID: containerID))
        } catch is CancellationError {
            return
        } catch CLIError.cancelled {
            return
        } catch {
            inspectionState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    private func updateVisibleWork() {
        guard isVisible else { return }

        if selectedTab == .logs {
            startLogs()
        } else {
            cancelLogs()
        }

        if selectedTab == .stats {
            startStats()
        } else {
            cancelStats()
        }
    }

    private func startLogs() {
        cancelLogs()
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
                self.logError = DiagnosticSanitizer.sanitize(error.localizedDescription)
            }
            if !Task.isCancelled {
                self.isLogStreaming = false
            }
        }
    }

    private func cancelLogs() {
        logTask?.cancel()
        logTask = nil
        isLogStreaming = false
    }

    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        if isLogPaused {
            pendingLogText = boundedLog(pendingLogText + text)
        } else {
            appendToVisibleLog(text)
        }
    }

    private func appendToVisibleLog(_ text: String) {
        logText = boundedLog(logText + text)
        logRevision += 1
    }

    private func boundedLog(_ text: String) -> String {
        var result = text
        let data = Data(result.utf8)
        if data.count > maximumLogBytes {
            result = String(decoding: data.suffix(maximumLogBytes), as: UTF8.self)
        }

        let hasTrailingNewline = result.hasSuffix("\n")
        var lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        if hasTrailingNewline, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if lines.count > maximumLogLines {
            result = lines.suffix(maximumLogLines).joined(separator: "\n")
            if hasTrailingNewline {
                result.append("\n")
            }
        }
        return result
    }

    private func startStats() {
        cancelStats()
        statsError = nil
        statsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.isStatsLoading = self.stats == nil
                do {
                    self.stats = try await self.service.stats(containerID: self.containerID)
                    self.statsError = nil
                } catch is CancellationError {
                    break
                } catch CLIError.cancelled {
                    break
                } catch {
                    self.statsError = DiagnosticSanitizer.sanitize(error.localizedDescription)
                }
                self.isStatsLoading = false

                do {
                    try await Task.sleep(for: self.statsInterval)
                } catch {
                    break
                }
            }
            self.isStatsLoading = false
        }
    }

    private func cancelStats() {
        statsTask?.cancel()
        statsTask = nil
        isStatsLoading = false
    }
}
