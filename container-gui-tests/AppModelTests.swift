import Foundation
import XCTest
@testable import Container_GUI

@MainActor
final class AppModelTests: XCTestCase {
    func testHostedXCTestAppUsesMockCLIWithoutUITestArguments() async {
        let model = AppDependencies.makeAppModel()

        await model.setup.checkIfNeeded()
        guard case .ready(let context) = model.setup.readiness else {
            return XCTFail("Hosted XCTest should use the ready mock preflight.")
        }
        await model.activate(context)

        XCTAssertEqual(model.containers.map(\.id), ["demo-stopped"])
    }

    func testListServiceRunsAuthoritativeCommandAndDecodesSummaries() async throws {
        let cli = ContainerCLIStub(output: makeContainerJSON(id: "web", state: "running"))
        let service = CLIContainerListService(cli: cli)

        let containers = try await service.listContainers()

        let commands = await cli.commands
        XCTAssertEqual(commands, [.listContainers(includeStopped: true)])
        XCTAssertEqual(containers.map(\.id), ["web"])
        XCTAssertEqual(containers.first?.state, .running)
    }

    func testNewerRefreshWinsWhenOlderRequestFinishesLast() async throws {
        let lister = SequencedContainerLister(responses: [
            .init(delay: .milliseconds(150), id: "older"),
            .init(delay: .milliseconds(10), id: "newer"),
        ])
        let model = AppModel(setup: SetupModel(), containerLister: lister)

        let olderRefresh = Task { await model.refreshContainers() }
        try await Task.sleep(for: .milliseconds(20))
        let newerRefresh = Task { await model.refreshContainers() }
        await newerRefresh.value
        await olderRefresh.value

        XCTAssertEqual(model.containers.map(\.id), ["newer"])
        XCTAssertEqual(model.containerListState, .loaded)
    }

    func testSearchAndStateFiltersCompose() async {
        let lister = StaticContainerLister(json: """
        [
          {
            "configuration": {
              "id": "frontend",
              "image": "example/web:latest",
              "platform": { "architecture": "arm64" }
            },
            "status": { "status": "running" }
          },
          {
            "configuration": {
              "id": "database",
              "image": "postgres:17",
              "platform": { "architecture": "arm64" }
            },
            "status": { "status": "stopped" }
          }
        ]
        """)
        let model = AppModel(setup: SetupModel(), containerLister: lister)
        await model.refreshContainers()

        model.containerFilter = .running
        model.searchText = "web"
        XCTAssertEqual(model.filteredContainers.map(\.id), ["frontend"])

        model.searchText = "postgres"
        XCTAssertTrue(model.filteredContainers.isEmpty)

        model.containerFilter = .stopped
        XCTAssertEqual(model.filteredContainers.map(\.id), ["database"])
    }

    func testMutationServiceMapsLifecycleActionsToCLICommands() async throws {
        let cli = ContainerCLIStub(output: "")
        let service = CLIContainerMutationService(cli: cli)

        try await service.mutate(.start, containerID: "web")
        try await service.mutate(.stop, containerID: "web")
        try await service.mutate(.delete(force: false), containerID: "web")
        try await service.mutate(.delete(force: true), containerID: "web")

        let commands = await cli.commands
        let id = try ContainerIdentifier(validating: "web")
        XCTAssertEqual(commands, [
            .start(id: id),
            .stop(id: id, timeout: nil),
            .delete(id: id, force: false),
            .delete(id: id, force: true),
        ])
    }

    func testSuccessfulMutationTracksBusyContainerAndRefreshes() async throws {
        let lister = CountingContainerLister(json: makeContainerJSON(id: "web", state: "stopped"))
        let mutator = ControllableContainerMutator(delay: .milliseconds(80))
        let model = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerMutator: mutator
        )
        await model.refreshContainers()

        let mutation = Task { await model.perform(.start, on: "web") }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.mutationInProgress(for: "web"), .start)
        XCTAssertFalse(model.canPerform(.start, on: model.containers[0]))

        await mutation.value

        let mutations = await mutator.mutations
        let refreshCount = await lister.callCount
        XCTAssertNil(model.mutationInProgress(for: "web"))
        XCTAssertNil(model.mutationFailure)
        XCTAssertEqual(mutations, [.init(mutation: .start, containerID: "web")])
        XCTAssertEqual(refreshCount, 2)
    }

    func testDoubleClickDoesNotStartConflictingMutation() async throws {
        let lister = CountingContainerLister(json: makeContainerJSON(id: "web", state: "running"))
        let mutator = ControllableContainerMutator(delay: .milliseconds(80))
        let model = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerMutator: mutator
        )
        await model.refreshContainers()

        let first = Task { await model.perform(.stop, on: "web") }
        try await Task.sleep(for: .milliseconds(20))
        await model.perform(.stop, on: "web")
        await first.value

        let mutationCount = await mutator.mutations.count
        let refreshCount = await lister.callCount
        XCTAssertEqual(mutationCount, 1)
        XCTAssertEqual(refreshCount, 2)
    }

    func testMutationFailureSurfacesStderrAndStillRefreshes() async {
        let lister = CountingContainerLister(json: makeContainerJSON(id: "web", state: "stopped"))
        let error = CLIError.nonZeroExit(
            invocation: "container start web",
            exitCode: 17,
            standardError: "service unavailable token=mutation-secret"
        )
        let mutator = ControllableContainerMutator(error: error)
        let model = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerMutator: mutator
        )
        await model.refreshContainers()

        await model.perform(.start, on: "web")

        let refreshCount = await lister.callCount
        XCTAssertEqual(model.mutationFailure?.containerID, "web")
        XCTAssertEqual(model.mutationFailure?.mutation, .start)
        XCTAssertTrue(model.mutationFailure?.message.contains("service unavailable") == true)
        XCTAssertTrue(model.mutationFailure?.message.contains("token=<redacted>") == true)
        XCTAssertFalse(model.mutationFailure?.message.contains("mutation-secret") == true)
        XCTAssertEqual(refreshCount, 2)
    }

    func testCancellationClearsBusyStateWithoutShowingFailureAndRefreshes() async {
        let lister = CountingContainerLister(json: makeContainerJSON(id: "web", state: "stopped"))
        let mutator = ControllableContainerMutator(error: CancellationError())
        let model = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerMutator: mutator
        )
        await model.refreshContainers()

        await model.perform(.start, on: "web")

        let refreshCount = await lister.callCount
        XCTAssertNil(model.mutationInProgress(for: "web"))
        XCTAssertNil(model.mutationFailure)
        XCTAssertEqual(refreshCount, 2)
    }

    func testStaleOrUnsupportedStateDoesNotRunMutation() async {
        let lister = CountingContainerLister(json: makeContainerJSON(id: "web", state: "running"))
        let mutator = ControllableContainerMutator()
        let model = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerMutator: mutator
        )
        await model.refreshContainers()

        await model.perform(.start, on: "web")

        let mutations = await mutator.mutations
        let refreshCount = await lister.callCount
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertEqual(
            model.mutationFailure?.message,
            "The container state changed. Refresh the list and try again."
        )
        XCTAssertEqual(refreshCount, 1)
    }

    func testLifecycleActionsAreEnabledConservativelyByState() {
        XCTAssertTrue(ContainerMutation.start.isAllowed(for: .created))
        XCTAssertTrue(ContainerMutation.start.isAllowed(for: .stopped))
        XCTAssertFalse(ContainerMutation.start.isAllowed(for: .running))
        XCTAssertTrue(ContainerMutation.stop.isAllowed(for: .running))
        XCTAssertTrue(ContainerMutation.stop.isAllowed(for: .paused))
        XCTAssertFalse(ContainerMutation.stop.isAllowed(for: .stopped))
        XCTAssertTrue(ContainerMutation.delete(force: false).isAllowed(for: .stopped))
        XCTAssertFalse(ContainerMutation.delete(force: false).isAllowed(for: .running))
        XCTAssertTrue(ContainerMutation.delete(force: true).isAllowed(for: .running))
        XCTAssertFalse(ContainerMutation.delete(force: true).isAllowed(for: .unknown("future")))
    }

}

private actor ContainerCLIStub: ContainerCLI {
    private let output: String
    private(set) var commands: [ContainerCommand] = []

    init(output: String) {
        self.output = output
    }

    func run(_ command: ContainerCommand) async throws -> CommandResult {
        commands.append(command)
        return CommandResult(
            standardOutput: output,
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: "container list --all --format json"
        )
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor SequencedContainerLister: ContainerListing {
    struct Response: Sendable {
        let delay: Duration
        let id: String
    }

    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func listContainers() async throws -> [ContainerSummary] {
        let response = responses.removeFirst()
        try await Task.sleep(for: response.delay)
        return try JSONDecoder()
            .decode([ContainerDTO].self, from: Data(makeContainerJSON(
                id: response.id,
                state: "running"
            ).utf8))
            .compactMap(ContainerSummary.init(dto:))
    }
}

private func makeContainerJSON(id: String, state: String) -> String {
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

private struct StaticContainerLister: ContainerListing {
    let json: String

    func listContainers() async throws -> [ContainerSummary] {
        try JSONDecoder()
            .decode([ContainerDTO].self, from: Data(json.utf8))
            .compactMap(ContainerSummary.init(dto:))
    }
}

private actor CountingContainerLister: ContainerListing {
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

private actor ControllableContainerMutator: ContainerMutating {
    struct Invocation: Equatable, Sendable {
        let mutation: ContainerMutation
        let containerID: String
    }

    private let delay: Duration?
    private let error: (any Error & Sendable)?
    private(set) var mutations: [Invocation] = []

    init(
        delay: Duration? = nil,
        error: (any Error & Sendable)? = nil
    ) {
        self.delay = delay
        self.error = error
    }

    func mutate(_ mutation: ContainerMutation, containerID: String) async throws {
        mutations.append(.init(mutation: mutation, containerID: containerID))
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error {
            throw error
        }
    }
}
