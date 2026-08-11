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
        let imageService = RunContainerImageService()
        let appModel = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerRunner: runner,
            imageService: imageService
        )
        let form = RunContainerModel()
        form.image = "alpine:3.21"
        form.name = "web"

        let outcome = await form.run(using: appModel)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertNil(form.errorMessage)
        XCTAssertTrue(form.progress.contains("pulling layer"))
        XCTAssertTrue(form.progress.contains("Process exited with status 0."))
        XCTAssertEqual(appModel.selectedContainerID, "web")
        let refreshCount = await lister.callCount
        let imageRefreshCount = await imageService.listCallCount
        let expectedConfiguration = try? RunConfiguration(image: "alpine:3.21", name: "web")
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(imageRefreshCount, 1)
        XCTAssertEqual(runner.configurations, [expectedConfiguration].compactMap { $0 })
    }

    func testFailedRunPreservesDraftAndExposesActionableError() async {
        let runner = StubContainerRunner(
            events: [.standardError("pull failed token=progress-secret\n")],
            error: .nonZeroExit(
                invocation: "container run alpine:3.21",
                exitCode: 9,
                standardError: "registry unavailable token=error-secret"
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

        let outcome = await form.run(using: appModel)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(form.image, "alpine:3.21")
        XCTAssertEqual(form.name, "keep-this")
        XCTAssertEqual(form.environment.first?.value, "debug")
        XCTAssertTrue(form.progress.contains("pull failed"))
        XCTAssertTrue(form.progress.contains("token=<redacted>"))
        XCTAssertFalse(form.progress.contains("progress-secret"))
        XCTAssertTrue(form.errorMessage?.contains("registry unavailable") == true)
        XCTAssertTrue(form.errorMessage?.contains("token=<redacted>") == true)
        XCTAssertFalse(form.errorMessage?.contains("error-secret") == true)
        let refreshCount = await lister.callCount
        XCTAssertEqual(refreshCount, 0)
    }

    func testCancellingRunTerminatesStreamAndRefreshesAuthoritativeState() async {
        let runner = CancellableContainerRunner()
        let lister = RunContainerLister(containers: [])
        let appModel = AppModel(
            setup: SetupModel(),
            containerLister: lister,
            containerRunner: runner
        )
        let form = RunContainerModel(image: "alpine:3.21")
        let task = Task { await form.run(using: appModel) }

        while !form.isRunning {
            await Task.yield()
        }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(form.isRunning)
        XCTAssertNil(form.errorMessage)
        XCTAssertTrue(runner.wasTerminated)
        let refreshCount = await lister.callCount
        XCTAssertEqual(refreshCount, 1)
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

nonisolated private final class CancellableContainerRunner: ContainerRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    var wasTerminated: Bool {
        lock.withLock { terminated }
    }

    func streamRun(
        _ configuration: RunConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.terminated = true
                }
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

private actor RunContainerImageService: ImageManaging {
    private(set) var listCallCount = 0

    func listImages() -> [ImageSummary] {
        listCallCount += 1
        return []
    }

    func inspectImage(reference: String) throws -> ImageInspection {
        let rawJSON = #"{"reference":"\#(reference)"}"#
        let dto = try JSONDecoder().decode(ImageDTO.self, from: Data(rawJSON.utf8))
        return ImageInspection(dto: dto, fallbackReference: reference, rawJSON: rawJSON)!
    }

    nonisolated func pullImage(
        reference: String
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func deleteImage(reference: String) {}
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
