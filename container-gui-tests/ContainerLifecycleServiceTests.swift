import Foundation
import XCTest
@testable import Container_GUI

final class ContainerLifecycleServiceTests: XCTestCase {
    func testCreateStreamsTheCommandAndReturnsTheIdentifier() async throws {
        let cli = LifecycleCLIStub(standardOutput: "web-1\n")
        let service = CLIContainerLifecycleService(cli: cli)
        let configuration = try RunConfiguration(image: "alpine:3.22", name: "web-1")

        let identifier = try await service.createContainer(configuration)

        XCTAssertEqual(identifier, "web-1")
        // Creating can pull an image, which outlives the 60-second timeout that
        // `run(_:)` applies, so it must take the streaming path.
        let streamed = await cli.streamedCommands
        let ran = await cli.ranCommands
        XCTAssertEqual(streamed, [.create(configuration)])
        XCTAssertTrue(ran.isEmpty)
    }

    func testCreateReportsMissingIdentifierAsInvalidOutput() async throws {
        let cli = LifecycleCLIStub(standardOutput: "Creating…\n")
        let service = CLIContainerLifecycleService(cli: cli)
        let configuration = try RunConfiguration(image: "alpine:3.22")

        do {
            _ = try await service.createContainer(configuration)
            XCTFail("Expected an invalid-output error.")
        } catch let error as CLIError {
            guard case .invalidOutput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCreateSurfacesANonZeroExit() async throws {
        let cli = LifecycleCLIStub(standardError: "no such image\n", exitCode: 1)
        let service = CLIContainerLifecycleService(cli: cli)
        let configuration = try RunConfiguration(image: "alpine:3.22")

        do {
            _ = try await service.createContainer(configuration)
            XCTFail("Expected a non-zero exit error.")
        } catch let error as CLIError {
            guard case .nonZeroExit(_, let exitCode, let standardError, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(standardError, "no such image\n")
        }
    }

    func testCopyStreamsAndSurfacesFailures() async throws {
        let operation = try CopyOperation(
            source: .container(id: "web", path: "/srv/report.txt"),
            destination: .host(path: "/tmp/report.txt")
        )
        let successful = LifecycleCLIStub()
        try await CLIContainerLifecycleService(cli: successful).copy(operation)
        let streamed = await successful.streamedCommands
        XCTAssertEqual(streamed, [.copy(operation)])

        let failing = LifecycleCLIStub(standardError: "no such file\n", exitCode: 2)
        do {
            try await CLIContainerLifecycleService(cli: failing).copy(operation)
            XCTFail("Expected a non-zero exit error.")
        } catch let error as CLIError {
            guard case .nonZeroExit(_, let exitCode, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exitCode, 2)
        }
    }

    func testPruneCollectsRemovedIdentifiers() async throws {
        let cli = LifecycleCLIStub(standardOutput: "web-1\napi-2\n")
        let service = CLIContainerLifecycleService(cli: cli)

        let result = try await service.pruneContainers()

        XCTAssertEqual(result.removedContainerIDs, ["web-1", "api-2"])
        let streamed = await cli.streamedCommands
        XCTAssertEqual(streamed, [.pruneContainers])
    }

    func testPruneOutputParsingIgnoresProseAndBlankLines() {
        let output = """
        Deleted containers:
        web-1

        api 2
        api-2
        Total reclaimed space: 1.2 GB
        """

        XCTAssertEqual(
            CLIContainerLifecycleService.prunedContainerIDs(from: output),
            ["web-1", "api-2"]
        )
    }

    func testExportForwardsEventsFromTheStream() async throws {
        let cli = LifecycleCLIStub(standardError: "exporting…\n")
        let service = CLIContainerLifecycleService(cli: cli)

        var events: [ProcessEvent] = []
        for try await event in service.exportContainer(id: "web", to: "/tmp/web.tar") {
            events.append(event)
        }

        XCTAssertEqual(events, [.standardError("exporting…\n"), .terminated(exitCode: 0)])
        let streamed = await cli.streamedCommands
        let expectedPath = try LocalPath(validating: "/tmp/web.tar", field: "Export path")
        XCTAssertEqual(
            streamed,
            [.exportContainer(id: try ContainerIdentifier(validating: "web"), output: expectedPath)]
        )
    }

    func testExportRejectsARelativeDestinationBeforeLaunching() async {
        let cli = LifecycleCLIStub()
        let service = CLIContainerLifecycleService(cli: cli)

        do {
            for try await _ in service.exportContainer(id: "web", to: "web.tar") {
                XCTFail("The stream should fail before producing events.")
            }
            XCTFail("Expected a validation error.")
        } catch {
            XCTAssertEqual(
                error as? CommandValidationError,
                .invalid(field: "Export path", value: "web.tar")
            )
        }
        let streamed = await cli.streamedCommands
        XCTAssertTrue(streamed.isEmpty)
    }

    func testExecStreamsOutput() async throws {
        let cli = LifecycleCLIStub(standardOutput: "hello\n")
        let service = CLIContainerLifecycleService(cli: cli)
        let configuration = try ExecConfiguration(command: ["echo", "hello"])

        var output = ""
        for try await event in service.exec(containerID: "web", configuration: configuration) {
            if case .standardOutput(let text) = event { output.append(text) }
        }

        XCTAssertEqual(output, "hello\n")
    }

    func testAttachExecIsRefusedByCLIsThatCannotHoldStandardInputOpen() async throws {
        let service = CLIContainerLifecycleService(cli: LifecycleCLIStub())
        let configuration = try ExecConfiguration(command: ["sh"], interactive: true, tty: true)

        XCTAssertThrowsError(
            try service.attachExec(
                containerID: "web",
                configuration: configuration,
                terminalSize: .default
            )
        ) { error in
            guard case .launchFailed = error as? CLIError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAttachExecValidatesTheContainerIdentifier() throws {
        let service = CLIContainerLifecycleService(cli: LifecycleCLIStub())
        let configuration = try ExecConfiguration(command: ["sh"])

        XCTAssertThrowsError(
            try service.attachExec(
                containerID: "bad id",
                configuration: configuration,
                terminalSize: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? CommandValidationError,
                .invalid(field: "Container identifier", value: "bad id")
            )
        }
    }
}

private actor LifecycleCLIStub: ContainerCLI {
    private let standardOutput: String
    private let standardError: String
    private let exitCode: Int32
    private(set) var ranCommands: [ContainerCommand] = []
    private(set) var streamedCommands: [ContainerCommand] = []

    init(standardOutput: String = "", standardError: String = "", exitCode: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    func run(_ command: ContainerCommand) async throws -> CommandResult {
        ranCommands.append(command)
        return CommandResult(
            standardOutput: standardOutput,
            standardError: standardError,
            exitCode: exitCode,
            duration: .zero,
            invocation: "container \(command.arguments.joined(separator: " "))"
        )
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(command)
                if !self.standardOutput.isEmpty {
                    continuation.yield(.standardOutput(self.standardOutput))
                }
                if !self.standardError.isEmpty {
                    continuation.yield(.standardError(self.standardError))
                }
                continuation.yield(.terminated(exitCode: self.exitCode))
                continuation.finish()
            }
        }
    }

    private func record(_ command: ContainerCommand) {
        streamedCommands.append(command)
    }
}
