import Foundation
import XCTest
@testable import Container_GUI

@MainActor
final class RunContainerModelTests: XCTestCase {
    func testDraftBuildsTypedConfigurationAndValidatesInline() throws {
        let model = RunContainerModel()
        model.image = " alpine:3.21 "
        model.name = "web"
        model.cpuLimit = "1.5"
        model.memoryLimit = "256M"
        model.ports = [
            PortMappingDraft(hostPort: "8080", containerPort: "80"),
        ]
        model.environment = [
            EnvironmentVariableDraft(key: "GREETING", value: "hello world"),
        ]
        model.command = "echo"
        model.arguments = [CommandArgumentDraft(value: "--help")]

        let configuration = try XCTUnwrap(model.configuration)

        XCTAssertNil(model.imageError)
        XCTAssertNil(model.nameError)
        XCTAssertNil(model.portError(for: model.ports[0]))
        XCTAssertEqual(
            ContainerCommand.run(configuration).arguments,
            [
                "run", "--progress", "plain", "--detach",
                "--name", "web",
                "--cpus", "1.5",
                "--memory", "256M",
                "--publish", "8080:80",
                "--env", "GREETING=hello world",
                "alpine:3.21", "echo", "--help",
            ]
        )

        model.ports[0].hostPort = "not-a-port"
        XCTAssertNotNil(model.portError(for: model.ports[0]))
        XCTAssertNil(model.configuration)
        XCTAssertFalse(model.canRun)
    }

    func testPreviewSafelyQuotesArgumentsAndRedactsSensitiveEnvironmentValues() {
        let model = RunContainerModel()
        model.image = "example/app:latest"
        model.environment = [
            EnvironmentVariableDraft(key: "API_TOKEN", value: "do not display"),
            EnvironmentVariableDraft(key: "GREETING", value: "hello world"),
        ]

        XCTAssertTrue(model.commandPreview.hasPrefix("container run "))
        XCTAssertTrue(model.commandPreview.contains("API_TOKEN=<redacted>"))
        XCTAssertFalse(model.commandPreview.contains("do not display"))
        XCTAssertTrue(model.commandPreview.contains("'GREETING=hello world'"))
    }

    func testSuccessfulRunShowsProgressRefreshesAndSelectsNamedContainer() async {
        let runner = StubContainerRunner(events: [
            .standardError("pulling layer\n"),
            .standardOutput("web\n"),
            .terminated(exitCode: 0),
        ])
        let lister = RunContainerLister(
            containers: [makeSummary(id: "web", state: "running")]
        )
        let appModel = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerRunner: runner
        )
        let form = RunContainerModel()
        form.image = "alpine:3.21"
        form.name = "web"

        let succeeded = await form.run(using: appModel)

        XCTAssertTrue(succeeded)
        XCTAssertNil(form.errorMessage)
        XCTAssertTrue(form.progress.contains("pulling layer"))
        XCTAssertTrue(form.progress.contains("Process exited with status 0."))
        XCTAssertEqual(appModel.selectedContainerID, "web")
        let refreshCount = await lister.callCount
        let expectedConfiguration = try? RunConfiguration(image: "alpine:3.21", name: "web")
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(runner.configurations, [expectedConfiguration].compactMap { $0 })
    }

    func testFailedRunPreservesDraftAndExposesActionableError() async {
        let runner = StubContainerRunner(
            events: [.standardError("pull failed\n")],
            error: .nonZeroExit(
                invocation: "container run alpine:3.21",
                exitCode: 9,
                standardError: "registry unavailable"
            )
        )
        let lister = RunContainerLister(containers: [])
        let appModel = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerRunner: runner
        )
        let form = RunContainerModel()
        form.image = "alpine:3.21"
        form.name = "keep-this"
        form.environment = [EnvironmentVariableDraft(key: "MODE", value: "debug")]

        let succeeded = await form.run(using: appModel)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(form.image, "alpine:3.21")
        XCTAssertEqual(form.name, "keep-this")
        XCTAssertEqual(form.environment.first?.value, "debug")
        XCTAssertTrue(form.progress.contains("pull failed"))
        XCTAssertTrue(form.errorMessage?.contains("registry unavailable") == true)
        let refreshCount = await lister.callCount
        XCTAssertEqual(refreshCount, 0)
    }
}

nonisolated private final class StubContainerRunner: ContainerRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [ProcessEvent]
    private let error: CLIError?
    private var recordedConfigurations: [RunConfiguration] = []

    init(events: [ProcessEvent], error: CLIError? = nil) {
        self.events = events
        self.error = error
    }

    var configurations: [RunConfiguration] {
        lock.withLock { recordedConfigurations }
    }

    func streamRun(
        _ configuration: RunConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        lock.withLock {
            recordedConfigurations.append(configuration)
        }
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}

private actor RunContainerLister: ContainerListing {
    private let containers: [ContainerSummary]
    private(set) var callCount = 0

    init(containers: [ContainerSummary]) {
        self.containers = containers
    }

    func listContainers() -> [ContainerSummary] {
        callCount += 1
        return containers
    }
}

private func makeSummary(id: String, state: String) -> ContainerSummary {
    let json = """
    {
      "configuration": {
        "id": "\(id)",
        "image": "example/app:latest",
        "platform": { "architecture": "arm64" }
      },
      "status": { "status": "\(state)" }
    }
    """
    let dto = try! JSONDecoder().decode(ContainerDTO.self, from: Data(json.utf8))
    return ContainerSummary(dto: dto)!
}
