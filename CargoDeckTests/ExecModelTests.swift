import Foundation
import XCTest
@testable import CargoDeck

@MainActor
final class ExecModelTests: XCTestCase {
    func testDraftBuildsTheCommandWithEveryOptionBeforeTheIdentifier() throws {
        let model = ExecModel(containerID: "web")
        model.command = "ls"
        model.arguments = [CommandArgumentDraft(value: "-la"), CommandArgumentDraft(value: "/app")]
        model.environment = [EnvironmentVariableDraft(key: "MODE", value: "test")]
        model.user = "root"
        model.workingDirectory = "/app"

        let configuration = try XCTUnwrap(model.configuration)
        let identifier = try ContainerIdentifier(validating: "web")

        XCTAssertEqual(
            ContainerCommand.exec(id: identifier, configuration: configuration).arguments,
            [
                "exec",
                "--env", "MODE=test",
                "--user", "root",
                "--workdir", "/app",
                "web",
                "ls", "-la", "/app",
            ]
        )
    }

    func testBlankArgumentsAndVariablesAreDroppedRatherThanSentEmpty() throws {
        let model = ExecModel(containerID: "web")
        model.command = "  env  "
        model.arguments = [
            CommandArgumentDraft(value: "  "),
            CommandArgumentDraft(value: " -0 "),
        ]
        model.environment = [
            EnvironmentVariableDraft(key: "  ", value: "ignored"),
            EnvironmentVariableDraft(key: " MODE ", value: "test"),
        ]

        let configuration = try XCTUnwrap(model.configuration)

        XCTAssertEqual(configuration.command, ["env", "-0"])
        XCTAssertEqual(configuration.environment.map(\.argument), ["MODE=test"])
    }

    func testPreviewFallsBackUntilAnExecutableIsGiven() {
        let model = ExecModel(containerID: "web")

        XCTAssertEqual(model.commandPreview, "container exec")
        XCTAssertFalse(model.canRun)

        model.command = "ls"

        XCTAssertTrue(model.canRun)
        XCTAssertTrue(model.commandPreview.hasPrefix("container exec "))
        XCTAssertTrue(model.commandPreview.hasSuffix(" web ls"))
    }

    func testAnExecutableThatWouldParseAsAnOptionIsRejected() {
        let model = ExecModel(containerID: "web")
        model.command = "--help"

        XCTAssertNotNil(model.commandError)
        XCTAssertNil(model.configuration)
        XCTAssertFalse(model.canRun)
    }

    func testUserAndWorkingDirectoryAreValidatedAgainstTheirOwnFields() {
        let model = ExecModel(containerID: "web")
        model.command = "ls"
        model.user = "root; echo hi"
        model.workingDirectory = "relative/path"

        XCTAssertEqual(model.userError?.contains("user"), true)
        XCTAssertEqual(model.workingDirectoryError?.contains("working directory"), true)
        XCTAssertNil(model.configuration)
    }

    /// Empty optional fields are unfinished, not wrong.
    func testEmptyOptionalFieldsShowNoError() {
        let model = ExecModel(containerID: "web")
        model.command = "ls"

        XCTAssertNil(model.userError)
        XCTAssertNil(model.workingDirectoryError)
        XCTAssertNotNil(model.configuration)
    }

    func testRunCollectsBothStreamsAndTheExitStatus() async {
        let appModel = AppModel(
            setup: SetupModel(),
            lifecycleService: ExecStubLifecycle(
                standardOutput: "total 0\n",
                standardError: "a warning\n"
            )
        )
        let model = ExecModel(containerID: "web")
        model.command = "ls"

        let ran = await model.run(using: appModel)

        XCTAssertTrue(ran)
        XCTAssertTrue(model.output.contains("total 0"))
        XCTAssertTrue(model.output.contains("a warning"))
        XCTAssertTrue(model.output.contains("Process exited with status 0."))
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isRunning)
    }

    func testANonZeroExitIsReportedWithoutLosingWhatWasPrinted() async {
        let appModel = AppModel(
            setup: SetupModel(),
            lifecycleService: ExecStubLifecycle(
                standardError: "no such file\n",
                exitCode: 2
            )
        )
        let model = ExecModel(containerID: "web")
        model.command = "cat"
        model.arguments = [CommandArgumentDraft(value: "/nope")]

        let ran = await model.run(using: appModel)

        XCTAssertFalse(ran)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.output.contains("no such file"))
        XCTAssertTrue(model.output.contains("Process exited with status 2."))
    }

    func testRunningAgainReplacesTheOutputOfThePreviousRun() async {
        let appModel = AppModel(
            setup: SetupModel(),
            lifecycleService: ExecStubLifecycle(standardOutput: "second\n")
        )
        let model = ExecModel(containerID: "web")
        model.command = "echo"

        _ = await model.run(using: appModel)
        _ = await model.run(using: appModel)

        XCTAssertEqual(
            model.output.components(separatedBy: "second").count - 1,
            1,
            "The previous run's output must be cleared, not appended to."
        )
    }
}

private actor ExecStubLifecycle: ContainerLifecycleManaging {
    private let standardOutput: String
    private let standardError: String
    private let exitCode: Int32

    init(standardOutput: String = "", standardError: String = "", exitCode: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    func createContainer(_ configuration: RunConfiguration) async throws -> String { "created" }

    func copy(_ operation: CopyOperation) async throws {}

    nonisolated func exportContainer(
        id: String,
        to output: String
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func pruneContainers() async throws -> ContainerPruneResult {
        ContainerPruneResult(removedContainerIDs: [])
    }

    nonisolated func exec(
        containerID: String,
        configuration: ExecConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let out = await self.standardOutput
                let error = await self.standardError
                if !out.isEmpty { continuation.yield(.standardOutput(out)) }
                if !error.isEmpty { continuation.yield(.standardError(error)) }
                continuation.yield(.terminated(exitCode: await self.exitCode))
                continuation.finish()
            }
        }
    }

    nonisolated func attachExec(
        containerID: String,
        configuration: ExecConfiguration,
        terminalSize: TerminalSize?
    ) throws -> any InteractiveProcessSession {
        throw CLIError.launchFailed(message: "Not supported by the stub.")
    }
}
