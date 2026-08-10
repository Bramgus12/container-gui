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

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .logs: "Logs"
        case .inspect: "Inspect"
        case .stats: "Stats"
        }
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
    var selectedTab: ContainerDetailTab = .overview {
        didSet { updateVisibleWork() }
    }
    var followsLogs = true {
        didSet {
            guard followsLogs != oldValue, isVisible, selectedTab == .logs else { return }
            startLogs()
        }
    }

    private(set) var inspectionState: ContainerInspectionState = .loading
    private(set) var logSnapshot = ContainerLogSnapshot.empty
    private(set) var isLogPaused = false
    private(set) var isLogStreaming = false
    private(set) var logError: String?
    private(set) var stats: ContainerStats?
    private(set) var statsError: String?
    private(set) var isStatsLoading = false

    private let service: any ContainerDiagnosing
    private let statsInterval: Duration
    private var isVisible = false
    private var liveLogBuffer: ContainerLogBuffer
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
        self.liveLogBuffer = ContainerLogBuffer(
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
        logSnapshot = liveLogBuffer.snapshot
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
