import Foundation
import XCTest
@testable import Container_GUI

@MainActor
final class AppModelTests: XCTestCase {
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
