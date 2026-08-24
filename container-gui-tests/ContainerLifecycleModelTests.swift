import Foundation
import XCTest
@testable import Container_GUI

/// Covers the `AppModel` side of the lifecycle commands: the reservation that
/// keeps pruning and per-container work from overlapping, and the way streamed
/// operations report a non-zero exit.
@MainActor
final class ContainerLifecycleModelTests: XCTestCase {

    // MARK: - Kill

    func testKillIsOfferedOnlyForContainersThatAreRunning() {
        XCTAssertTrue(ContainerMutation.kill(signal: .term).isAllowed(for: .running))
        XCTAssertTrue(ContainerMutation.kill(signal: .term).isAllowed(for: .paused))
        XCTAssertFalse(ContainerMutation.kill(signal: .term).isAllowed(for: .stopped))
        XCTAssertFalse(ContainerMutation.kill(signal: .term).isAllowed(for: .created))
        XCTAssertFalse(ContainerMutation.kill(signal: .kill).isAllowed(for: .unknown("future")))
    }

    func testKillReservesTheContainerAndSendsTheChosenSignal() async throws {
        let lister = CountingLister(json: containerJSON(id: "web", state: "running"))
        let mutator = RecordingMutator(delay: .milliseconds(80))
        let model = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerMutator: mutator
        )
        await model.refreshContainers()

        let kill = Task { await model.perform(.kill(signal: .quit), on: "web") }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.mutationInProgress(for: "web"), .kill(signal: .quit))
        XCTAssertFalse(model.canPerform(.stop, on: model.containers[0]))

        await kill.value

        let mutations = await mutator.mutations
        XCTAssertEqual(mutations, [.init(mutation: .kill(signal: .quit), containerID: "web")])
        XCTAssertNil(model.mutationInProgress(for: "web"))
    }

    // MARK: - Prune

    func testPruneReportsRemovedContainersAndRefreshes() async {
        let lister = CountingLister(json: containerJSON(id: "web", state: "stopped"))
        let lifecycle = LifecycleStub(pruned: ["old-1", "old-2"])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            lifecycleService: lifecycle
        )
        await model.refreshContainers()

        await model.pruneContainers()

        let refreshCount = await lister.callCount
        XCTAssertEqual(model.lastPruneResult?.removedContainerIDs, ["old-1", "old-2"])
        XCTAssertNil(model.operationFailure)
        XCTAssertEqual(refreshCount, 2)
    }

    func testPruneIsOfferedOnlyWhenAStoppedContainerExists() async {
        let lifecycle = LifecycleStub()
        let running = AppModel(
            setup: SetupModel(),
            containerLister: StaticLister(json: containerJSON(id: "web", state: "running")),
            lifecycleService: lifecycle
        )
        await running.refreshContainers()
        XCTAssertFalse(running.canPruneContainers)

        let stopped = AppModel(
            setup: SetupModel(),
            containerLister: StaticLister(json: containerJSON(id: "web", state: "stopped")),
            lifecycleService: lifecycle
        )
        await stopped.refreshContainers()
        XCTAssertTrue(stopped.canPruneContainers)
    }

    /// Pruning deletes containers the app did not name, so it must not run
    /// beside an operation that is already changing one of them.
    func testPruneIsBlockedWhileAContainerMutationIsInFlight() async throws {
        let model = AppModel(
            setup: SetupModel(),
            containerLister: CountingLister(json: mixedContainersJSON()),
            containerMutator: RecordingMutator(delay: .milliseconds(120)),
            lifecycleService: LifecycleStub(pruned: ["old"])
        )
        await model.refreshContainers()
        XCTAssertTrue(model.canPruneContainers, "Precondition: pruning is on offer.")

        let stop = Task { await model.perform(.stop, on: "web") }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(model.canPruneContainers)
        await model.pruneContainers()
        XCTAssertNil(model.lastPruneResult, "Pruning should not have started.")

        await stop.value
        XCTAssertTrue(model.canPruneContainers, "The reservation must be released.")
    }

    func testContainerMutationsAreBlockedWhilePruneIsInFlight() async throws {
        let lifecycle = LifecycleStub(pruned: ["old"], pruneDelay: .milliseconds(120))
        let mutator = RecordingMutator()
        let model = AppModel(
            setup: SetupModel(),
            containerLister: CountingLister(json: mixedContainersJSON()),
            containerMutator: mutator,
            lifecycleService: lifecycle
        )
        await model.refreshContainers()
        let running = try XCTUnwrap(model.containers.first { $0.id == "web" })
        XCTAssertTrue(model.canPerform(.stop, on: running), "Precondition: stop is on offer.")

        let prune = Task { await model.pruneContainers() }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(model.canPerform(.stop, on: running))
        await model.perform(.stop, on: "web")
        let mutations = await mutator.mutations
        XCTAssertTrue(mutations.isEmpty, "The stop should not have reached the CLI.")

        await prune.value
        XCTAssertTrue(model.canPerform(.stop, on: running))
    }

    func testPruneFailureIsSurfacedAndStillRefreshes() async {
        let lister = CountingLister(json: containerJSON(id: "web", state: "stopped"))
        let lifecycle = LifecycleStub(
            pruneError: CLIError.nonZeroExit(
                invocation: "container prune",
                exitCode: 1,
                standardError: "the daemon is not running"
            )
        )
        let model = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            lifecycleService: lifecycle
        )
        await model.refreshContainers()

        await model.pruneContainers()

        let refreshCount = await lister.callCount
        XCTAssertNil(model.lastPruneResult)
        XCTAssertEqual(model.operationFailure?.operation, "Prune containers")
        XCTAssertEqual(
            model.operationFailure?.message.contains("the daemon is not running"),
            true
        )
        XCTAssertEqual(refreshCount, 2, "A failed prune may still have removed something.")

        model.dismissOperationFailure()
        XCTAssertNil(model.operationFailure)
    }

    func testPruneTreatsCancellationAsAnIntentionalStopRatherThanAFailure() async {
        let model = AppModel(
            setup: SetupModel(),
            containerLister: StaticLister(json: containerJSON(id: "web", state: "stopped")),
            lifecycleService: LifecycleStub(pruneError: CLIError.cancelled)
        )
        await model.refreshContainers()

        await model.pruneContainers()

        XCTAssertNil(model.operationFailure)
        XCTAssertNil(model.lastPruneResult)
        XCTAssertTrue(model.canPruneContainers, "The reservation must be released.")
    }

    // MARK: - Create

    func testCreateSelectsTheContainerItReportsBackFromTheCLI() async throws {
        let lifecycle = LifecycleStub(createdIdentifier: "web")
        let model = AppModel(
            setup: SetupModel(),
            containerLister: StaticLister(json: containerJSON(id: "web", state: "created")),
            lifecycleService: lifecycle
        )
        let configuration = try RunConfiguration(image: "alpine:3.22", name: "web")

        let identifier = try await model.createContainer(configuration)

        XCTAssertEqual(identifier, "web")
        XCTAssertEqual(model.selectedContainerID, "web")
        let created = await lifecycle.createdConfigurations
        XCTAssertEqual(created, [configuration])
    }

    /// A container that the CLI creates but that the very next listing does not
    /// report yet must not clear whatever the user had selected.
    func testCreateLeavesTheSelectionAloneWhenTheNewContainerIsNotListedYet() async throws {
        let model = AppModel(
            setup: SetupModel(),
            containerLister: StaticLister(json: containerJSON(id: "web", state: "running")),
            lifecycleService: LifecycleStub(createdIdentifier: "not-listed-yet")
        )
        await model.refreshContainers()
        model.selectedContainerID = "web"

        let identifier = try await model.createContainer(
            try RunConfiguration(image: "alpine:3.22")
        )

        XCTAssertEqual(identifier, "not-listed-yet")
        XCTAssertEqual(model.selectedContainerID, "web")
    }

    func testCreateWithoutAReadyExecutableReportsALaunchFailure() async throws {
        let model = AppModel(setup: SetupModel())

        do {
            _ = try await model.createContainer(try RunConfiguration(image: "alpine:3.22"))
            XCTFail("Expected a launch failure.")
        } catch let error as CLIError {
            guard case .launchFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Streamed operations

    func testExportForwardsOutputAndRaisesANonZeroExit() async throws {
        let lifecycle = LifecycleStub(
            streamedOutput: "writing layer\n",
            streamedExitCode: 2
        )
        let model = AppModel(setup: SetupModel(), lifecycleService: lifecycle)

        var events: [ProcessEvent] = []
        do {
            try await model.exportContainer(id: "web", to: "/tmp/web.tar") { events.append($0) }
            XCTFail("Expected a non-zero exit to be raised.")
        } catch let error as CLIError {
            guard case .nonZeroExit(let invocation, let exitCode, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(invocation, "export")
            XCTAssertEqual(exitCode, 2)
        }

        // The caller still sees everything the command printed, including the
        // terminating event, so a progress view can show why it stopped.
        XCTAssertEqual(events.first, .standardOutput("writing layer\n"))
        XCTAssertEqual(events.last, .terminated(exitCode: 2))
    }

    func testExecForwardsEveryEventOnSuccess() async throws {
        let lifecycle = LifecycleStub(streamedOutput: "hello\n")
        let model = AppModel(setup: SetupModel(), lifecycleService: lifecycle)
        let configuration = try ExecConfiguration(command: ["echo", "hello"])

        var output = ""
        try await model.execCommand(containerID: "web", configuration: configuration) { event in
            if case .standardOutput(let text) = event { output.append(text) }
        }

        XCTAssertEqual(output, "hello\n")
        let executed = await lifecycle.executedCommands
        XCTAssertEqual(executed, [["echo", "hello"]])
    }

    func testCopyFailureIsRecordedAndRethrown() async throws {
        let lifecycle = LifecycleStub(
            copyError: CLIError.nonZeroExit(
                invocation: "container copy",
                exitCode: 1,
                standardError: "no such file"
            )
        )
        let model = AppModel(setup: SetupModel(), lifecycleService: lifecycle)
        let operation = try CopyOperation(
            source: try .container(id: "web", path: "/etc/hosts"),
            destination: try .host(path: "/tmp/hosts")
        )

        do {
            try await model.copyFiles(operation)
            XCTFail("Expected the copy to fail.")
        } catch let error as CLIError {
            guard case .nonZeroExit = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

// MARK: - Stubs

private actor LifecycleStub: ContainerLifecycleManaging {
    private let pruned: [String]
    private let pruneDelay: Duration?
    private let pruneError: (any Error & Sendable)?
    private let createdIdentifier: String
    private let copyError: (any Error & Sendable)?
    private let streamedOutput: String
    private let streamedExitCode: Int32

    private(set) var createdConfigurations: [RunConfiguration] = []
    private(set) var executedCommands: [[String]] = []

    init(
        pruned: [String] = [],
        pruneDelay: Duration? = nil,
        pruneError: (any Error & Sendable)? = nil,
        createdIdentifier: String = "created",
        copyError: (any Error & Sendable)? = nil,
        streamedOutput: String = "",
        streamedExitCode: Int32 = 0
    ) {
        self.pruned = pruned
        self.pruneDelay = pruneDelay
        self.pruneError = pruneError
        self.createdIdentifier = createdIdentifier
        self.copyError = copyError
        self.streamedOutput = streamedOutput
        self.streamedExitCode = streamedExitCode
    }

    func createContainer(_ configuration: RunConfiguration) async throws -> String {
        createdConfigurations.append(configuration)
        return createdIdentifier
    }

    func copy(_ operation: CopyOperation) async throws {
        if let copyError { throw copyError }
    }

    nonisolated func exportContainer(
        id: String,
        to output: String
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        stream(recording: nil)
    }

    func pruneContainers() async throws -> ContainerPruneResult {
        if let pruneDelay {
            try await Task.sleep(for: pruneDelay)
        }
        if let pruneError { throw pruneError }
        return ContainerPruneResult(removedContainerIDs: pruned)
    }

    nonisolated func exec(
        containerID: String,
        configuration: ExecConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        stream(recording: configuration.command)
    }

    nonisolated func attachExec(
        containerID: String,
        configuration: ExecConfiguration,
        terminalSize: TerminalSize?
    ) throws -> any InteractiveProcessSession {
        throw CLIError.launchFailed(message: "Not supported by the stub.")
    }

    private nonisolated func stream(
        recording command: [String]?
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if let command {
                    await self.record(command)
                }
                let output = await self.streamedOutput
                if !output.isEmpty {
                    continuation.yield(.standardOutput(output))
                }
                continuation.yield(.terminated(exitCode: await self.streamedExitCode))
                continuation.finish()
            }
        }
    }

    private func record(_ command: [String]) {
        executedCommands.append(command)
    }
}

private actor RecordingMutator: ContainerMutating {
    struct Invocation: Equatable, Sendable {
        let mutation: ContainerMutation
        let containerID: String
    }

    private let delay: Duration?
    private(set) var mutations: [Invocation] = []

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    func mutate(_ mutation: ContainerMutation, containerID: String) async throws {
        mutations.append(.init(mutation: mutation, containerID: containerID))
        if let delay {
            try await Task.sleep(for: delay)
        }
    }
}

private struct StaticLister: ContainerListing {
    let json: String

    func listContainers() async throws -> [ContainerSummary] {
        try JSONDecoder()
            .decode([ContainerDTO].self, from: Data(json.utf8))
            .compactMap(ContainerSummary.init(dto:))
    }
}

private actor CountingLister: ContainerListing {
    let json: String
    private(set) var callCount = 0

    init(json: String) {
        self.json = json
    }

    func listContainers() async throws -> [ContainerSummary] {
        callCount += 1
        return try JSONDecoder()
            .decode([ContainerDTO].self, from: Data(json.utf8))
            .compactMap(ContainerSummary.init(dto:))
    }
}

private func mixedContainersJSON() -> String {
    """
    [
      {
        "configuration": {
          "id": "web",
          "image": "example/app:latest",
          "platform": { "architecture": "arm64" }
        },
        "status": { "status": "running" }
      },
      {
        "configuration": {
          "id": "old",
          "image": "example/app:latest",
          "platform": { "architecture": "arm64" }
        },
        "status": { "status": "stopped" }
      }
    ]
    """
}

private func containerJSON(id: String, state: String) -> String {
    """
    [{
      "configuration": {
        "id": "\(id)",
        "image": "example/app:latest",
        "platform": { "architecture": "arm64" }
      },
      "status": { "status": "\(state)" }
    }]
    """
}
