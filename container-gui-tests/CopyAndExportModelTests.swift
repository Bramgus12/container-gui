import Foundation
import XCTest
@testable import Container_GUI

@MainActor
final class CopyAndExportModelTests: XCTestCase {

    // MARK: - Copy

    func testDirectionDecidesWhichSideIsTheContainer() {
        let model = CopyFilesModel(containerID: "web")
        model.containerPath = "/etc/hosts"
        model.hostPath = "/Users/me/hosts"

        XCTAssertEqual(
            model.operation?.arguments,
            ["copy", "web:/etc/hosts", "/Users/me/hosts"]
        )

        model.direction = .intoContainer

        XCTAssertEqual(
            model.operation?.arguments,
            ["copy", "/Users/me/hosts", "web:/etc/hosts"]
        )
    }

    func testPreviewFallsBackBeforeBothPathsAreGiven() {
        let model = CopyFilesModel(containerID: "web")

        XCTAssertEqual(model.commandPreview, "container copy")
        XCTAssertFalse(model.canCopy)

        model.containerPath = "/etc/hosts"
        XCTAssertFalse(model.canCopy, "One path is not enough.")

        model.hostPath = "/Users/me/hosts"
        XCTAssertTrue(model.canCopy)
        XCTAssertTrue(model.commandPreview.hasPrefix("container copy "))
    }

    func testRelativePathsAreReportedAgainstTheFieldThatHoldsThem() {
        let model = CopyFilesModel(containerID: "web")
        model.containerPath = "etc/hosts"
        model.hostPath = "hosts"

        XCTAssertEqual(model.containerPathError?.contains("container path"), true)
        XCTAssertEqual(model.hostPathError?.contains("host path"), true)
        XCTAssertNil(model.operation)
    }

    /// An empty field is simply unfinished, not wrong, so it shows no error.
    func testEmptyPathsAreNotReportedAsErrors() {
        let model = CopyFilesModel(containerID: "web")

        XCTAssertNil(model.containerPathError)
        XCTAssertNil(model.hostPathError)
    }

    func testSurroundingWhitespaceIsTrimmedFromBothPaths() {
        let model = CopyFilesModel(containerID: "web")
        model.containerPath = "  /etc/hosts  "
        model.hostPath = "\t/Users/me/hosts\n"

        XCTAssertEqual(
            model.operation?.arguments,
            ["copy", "web:/etc/hosts", "/Users/me/hosts"]
        )
    }

    func testCopyFailureKeepsTheSheetOpenAndShowsTheReason() async {
        let appModel = AppModel(
            setup: SetupModel(),
            lifecycleService: StubLifecycle(
                copyError: CLIError.nonZeroExit(
                    invocation: "container copy",
                    exitCode: 1,
                    standardError: "no such file"
                )
            )
        )
        let model = CopyFilesModel(containerID: "web")
        model.containerPath = "/nope"
        model.hostPath = "/Users/me/nope"

        let copied = await model.copy(using: appModel)

        XCTAssertFalse(copied)
        XCTAssertEqual(model.errorMessage?.contains("no such file"), true)
        XCTAssertFalse(model.isCopying)
    }

    func testSuccessfulCopyReportsTheOperationItSent() async {
        let lifecycle = StubLifecycle()
        let appModel = AppModel(setup: SetupModel(), lifecycleService: lifecycle)
        let model = CopyFilesModel(containerID: "web")
        model.containerPath = "/etc/hosts"
        model.hostPath = "/Users/me/hosts"

        let copied = await model.copy(using: appModel)

        XCTAssertTrue(copied)
        XCTAssertNil(model.errorMessage)
        let operations = await lifecycle.copiedOperations
        XCTAssertEqual(operations.map(\.arguments), [["copy", "web:/etc/hosts", "/Users/me/hosts"]])
    }

    // MARK: - Export

    func testExportPreviewsTheCommandItWillRun() {
        let model = ExportContainerModel(
            containerID: "web",
            destination: "/Users/me/web.tar",
            containerWasRunning: false
        )

        XCTAssertEqual(
            model.commandPreview,
            "container export --output /Users/me/web.tar web"
        )
    }

    func testExportStreamsProgressAndOffersTheArchiveWhenItFinishes() async {
        let appModel = AppModel(
            setup: SetupModel(),
            lifecycleService: StubLifecycle(streamedOutput: "writing layer\n")
        )
        let model = ExportContainerModel(
            containerID: "web",
            destination: "/Users/me/web.tar",
            containerWasRunning: true
        )

        let exported = await model.export(using: appModel)

        XCTAssertTrue(exported)
        XCTAssertTrue(model.didFinish)
        XCTAssertTrue(model.progress.contains("writing layer"))
        XCTAssertTrue(model.progress.contains("Process exited with status 0."))
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isExporting)
    }

    func testExportFailureIsReportedAndTheArchiveIsNotOffered() async {
        let appModel = AppModel(
            setup: SetupModel(),
            lifecycleService: StubLifecycle(streamedExitCode: 1)
        )
        let model = ExportContainerModel(
            containerID: "web",
            destination: "/Users/me/web.tar",
            containerWasRunning: false
        )

        let exported = await model.export(using: appModel)

        XCTAssertFalse(exported)
        XCTAssertFalse(model.didFinish, "A failed export has no archive to reveal.")
        XCTAssertNotNil(model.errorMessage)
    }
}

private actor StubLifecycle: ContainerLifecycleManaging {
    private let copyError: (any Error & Sendable)?
    private let streamedOutput: String
    private let streamedExitCode: Int32
    private(set) var copiedOperations: [CopyOperation] = []

    init(
        copyError: (any Error & Sendable)? = nil,
        streamedOutput: String = "",
        streamedExitCode: Int32 = 0
    ) {
        self.copyError = copyError
        self.streamedOutput = streamedOutput
        self.streamedExitCode = streamedExitCode
    }

    func createContainer(_ configuration: RunConfiguration) async throws -> String { "created" }

    func copy(_ operation: CopyOperation) async throws {
        copiedOperations.append(operation)
        if let copyError { throw copyError }
    }

    nonisolated func exportContainer(
        id: String,
        to output: String
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let text = await self.streamedOutput
                if !text.isEmpty {
                    continuation.yield(.standardOutput(text))
                }
                continuation.yield(.terminated(exitCode: await self.streamedExitCode))
                continuation.finish()
            }
        }
    }

    func pruneContainers() async throws -> ContainerPruneResult {
        ContainerPruneResult(removedContainerIDs: [])
    }

    nonisolated func exec(
        containerID: String,
        configuration: ExecConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func attachExec(
        containerID: String,
        configuration: ExecConfiguration,
        terminalSize: TerminalSize?
    ) throws -> any InteractiveProcessSession {
        throw CLIError.launchFailed(message: "Not supported by the stub.")
    }
}
