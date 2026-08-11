import Foundation
import XCTest
@testable import Container_GUI

@MainActor
final class ContainerDetailModelTests: XCTestCase {
    func testInspectionServiceDecodesObjectPreservesRawJSONAndRunsTypedCommand() async throws {
        let output = """
        {
          "future": true,
          "configuration": {
            "id": "web",
            "image": "alpine:3.21",
            "resources": { "cpus": 2, "memoryInBytes": 1048576 }
          },
          "status": { "status": "running" }
        }
        """
        let cli = DetailCLIStub(output: output)
        let service = CLIContainerDiagnosticsService(cli: cli)

        let inspection = try await service.inspect(containerID: "web")

        XCTAssertEqual(inspection.details.id, "web")
        XCTAssertEqual(inspection.details.resources?.cpus, 2)
        XCTAssertTrue(inspection.rawJSON.contains("\"future\": true"))
        let commands = await cli.commands
        XCTAssertEqual(commands, [.inspectContainer(id: try ContainerIdentifier(validating: "web"))])
    }

    func testStatsServiceDecodesArrayAndSelectsRequestedContainer() async throws {
        let cli = DetailCLIStub(output: """
        [
          { "id": "other", "numProcesses": 1 },
          { "id": "web", "numProcesses": 7, "memoryUsageBytes": 4096 }
        ]
        """)
        let service = CLIContainerDiagnosticsService(cli: cli)

        let stats = try await service.stats(containerID: "web")

        XCTAssertEqual(stats.id, "web")
        XCTAssertEqual(stats.processCount, 7)
        XCTAssertEqual(stats.memoryUsageBytes, 4_096)
    }

    func testLogsAreBoundedAndPauseBuffersUntilResume() async throws {
        let service = DiagnosticsStub()
        let model = ContainerDetailModel(
            containerID: "web",
            service: service,
            maximumLogLines: 3,
            maximumLogBytes: 1_024
        )
        model.selectedTab = .logs
        await model.appear()

        service.yieldLog(.standardOutput("one\ntwo\nthree\nfour\n"))
        try await eventually { model.logSnapshot.text == "two\nthree\nfour\n" }
        XCTAssertEqual(model.logSnapshot.firstLogicalLineNumber, 2)

        model.toggleLogPause()
        service.yieldLog(.standardOutput("five\n"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.logSnapshot.text, "two\nthree\nfour\n")

        model.toggleLogPause()
        XCTAssertEqual(model.logSnapshot.text, "three\nfour\nfive\n")
        XCTAssertEqual(model.logSnapshot.firstLogicalLineNumber, 3)
        model.disappear()
        XCTAssertTrue(service.logStreamWasCancelled)
    }

    func testClearPreservesNumberingWithinAStream() async throws {
        let service = DiagnosticsStub()
        let model = ContainerDetailModel(containerID: "web", service: service)
        model.selectedTab = .logs
        await model.appear()

        service.yieldLog(.standardOutput("one\ntwo\n"))
        try await eventually { model.logSnapshot.text == "one\ntwo\n" }
        model.clearLogs()

        XCTAssertEqual(model.logSnapshot, LogSnapshot(
            text: "",
            firstLogicalLineNumber: 3
        ))
        service.yieldLog(.standardOutput("three"))
        try await eventually { model.logSnapshot.text == "three" }
        XCTAssertEqual(model.logSnapshot.firstLogicalLineNumber, 3)
        model.disappear()
    }

    func testRestartReplacesFetchedTailAndStartsNumberingAtOne() async throws {
        let service = DiagnosticsStub()
        let model = ContainerDetailModel(containerID: "web", service: service)
        model.selectedTab = .logs
        await model.appear()

        service.yieldLog(.standardOutput("old tail\n"))
        try await eventually { model.logSnapshot.text == "old tail\n" }

        model.followsLogs = false
        XCTAssertEqual(model.logSnapshot, .empty)
        service.yieldLog(.standardOutput("replacement tail\n"))

        try await eventually { model.logSnapshot.text == "replacement tail\n" }
        XCTAssertEqual(model.logSnapshot.firstLogicalLineNumber, 1)
        XCTAssertFalse(model.logSnapshot.text.contains("old tail"))
        XCTAssertEqual(service.logStreamCallCount, 2)
        model.disappear()
    }

    func testStatsPollOnlyWhileStatsTabIsVisible() async throws {
        let service = DiagnosticsStub()
        let model = ContainerDetailModel(
            containerID: "web",
            service: service,
            statsInterval: .milliseconds(20)
        )
        model.selectedTab = .stats

        await model.appear()
        try await eventually { service.statsCallCount >= 2 }

        model.selectedTab = .overview
        let countAfterLeavingStats = service.statsCallCount
        try await Task.sleep(for: .milliseconds(70))

        XCTAssertEqual(service.statsCallCount, countAfterLeavingStats)
        model.disappear()
    }

    func testNewerInspectionWinsWhenOlderRequestFinishesLast() async throws {
        let service = SequencedInspectionService(responses: [
            .init(delay: .milliseconds(120), id: "older"),
            .init(delay: .milliseconds(10), id: "newer"),
        ])
        let model = ContainerDetailModel(containerID: "web", service: service)

        let olderLoad = Task { await model.appear() }
        try await Task.sleep(for: .milliseconds(20))
        let newerLoad = Task { await model.reloadInspection() }
        await newerLoad.value
        await olderLoad.value

        guard case .loaded(let inspection) = model.inspectionState else {
            return XCTFail("Expected the latest inspection to be loaded.")
        }
        XCTAssertEqual(inspection.details.id, "newer")
        model.disappear()
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private actor SequencedInspectionService: ContainerDiagnosing {
    struct Response: Sendable {
        let delay: Duration
        let id: String
    }

    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func inspect(containerID: String) async throws -> ContainerInspection {
        let response = responses.removeFirst()
        try await Task.sleep(for: response.delay)
        let data = Data(
            """
            {
              "configuration": { "id": "\(response.id)", "image": "alpine:3.21" },
              "status": { "status": "running" }
            }
            """.utf8
        )
        let dto = try JSONDecoder().decode(ContainerDTO.self, from: data)
        guard let details = ContainerDetails(dto: dto) else {
            throw CLIError.invalidOutput(description: "Missing fixture container identifier.")
        }
        return ContainerInspection(
            details: details,
            rawJSON: String(decoding: data, as: UTF8.self)
        )
    }

    nonisolated func streamLogs(
        containerID: String,
        follow: Bool,
        tail: Int
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stats(containerID: String) async throws -> ContainerStats {
        throw CLIError.invalidOutput(description: "Stats are not used by this test.")
    }
}

private actor DetailCLIStub: ContainerCLI {
    let output: String
    private(set) var commands: [ContainerCommand] = []

    init(output: String) {
        self.output = output
    }

    func run(_ command: ContainerCommand) -> CommandResult {
        commands.append(command)
        return CommandResult(
            standardOutput: output,
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: "container"
        )
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class DiagnosticsStub: ContainerDiagnosing, @unchecked Sendable {
    private let lock = NSLock()
    private var logContinuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation?
    private var recordedStatsCallCount = 0
    private var recordedLogStreamWasCancelled = false
    private var recordedLogStreamCallCount = 0

    var statsCallCount: Int {
        lock.withLock { recordedStatsCallCount }
    }

    var logStreamWasCancelled: Bool {
        lock.withLock { recordedLogStreamWasCancelled }
    }

    var logStreamCallCount: Int {
        lock.withLock { recordedLogStreamCallCount }
    }

    func inspect(containerID: String) async throws -> ContainerInspection {
        let data = Data("""
        {
          "configuration": { "id": "\(containerID)", "image": "alpine:3.21" },
          "status": { "status": "running" }
        }
        """.utf8)
        let dto = try JSONDecoder().decode(ContainerDTO.self, from: data)
        return ContainerInspection(
            details: ContainerDetails(dto: dto)!,
            rawJSON: String(decoding: data, as: UTF8.self)
        )
    }

    func streamLogs(
        containerID: String,
        follow: Bool,
        tail: Int
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                recordedLogStreamCallCount += 1
                logContinuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.recordedLogStreamWasCancelled = true
                }
            }
        }
    }

    func stats(containerID: String) async throws -> ContainerStats {
        lock.withLock {
            recordedStatsCallCount += 1
        }
        return ContainerStats(dto: ContainerStatsDTO(
            id: containerID,
            memoryUsageBytes: 1_024,
            memoryLimitBytes: 2_048,
            cpuUsageUsec: 3_000,
            networkRxBytes: 4,
            networkTxBytes: 5,
            blockReadBytes: 6,
            blockWriteBytes: 7,
            numProcesses: 2
        ))
    }

    func yieldLog(_ event: ProcessEvent) {
        lock.withLock { logContinuation }?.yield(event)
    }
}
