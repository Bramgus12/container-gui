import Foundation
import XCTest
@testable import Container_GUI

final class CLITypesTests: XCTestCase {
    func testCommandResultReportsSuccessOnlyForZeroExit() {
        let success = CommandResult(
            standardOutput: "ok",
            standardError: "",
            exitCode: 0,
            duration: .milliseconds(12),
            invocation: "/usr/local/bin/container list"
        )
        let failure = CommandResult(
            standardOutput: "",
            standardError: "failed",
            exitCode: 1,
            duration: .zero,
            invocation: "/usr/local/bin/container list"
        )

        XCTAssertTrue(success.succeeded)
        XCTAssertFalse(failure.succeeded)
    }

    func testProcessEventsAndErrorsRetainTypedInformation() {
        XCTAssertEqual(ProcessEvent.standardOutput("hello"), .standardOutput("hello"))
        XCTAssertEqual(ProcessEvent.standardError("warning"), .standardError("warning"))
        XCTAssertEqual(ProcessEvent.terminated(exitCode: 9), .terminated(exitCode: 9))

        let error = CLIError.nonZeroExit(
            invocation: "container start web",
            exitCode: 7,
            standardError: "service unavailable"
        )
        XCTAssertEqual(
            error.errorDescription,
            "Container exited with status 7: service unavailable"
        )
    }

    func testProtocolSupportsRunAndStreamingWithoutARealCLI() async throws {
        let cli: any ContainerCLI = FakeCLI()
        let result = try await cli.run(.systemStatus)
        XCTAssertEqual(result.standardOutput, "{}")

        var events: [ProcessEvent] = []
        for try await event in cli.stream(.systemLogs(follow: true, last: nil)) {
            events.append(event)
        }
        XCTAssertEqual(events, [.standardOutput("line\n"), .terminated(exitCode: 0)])
    }
}

private struct FakeCLI: ContainerCLI {
    func run(_ command: ContainerCommand) async throws -> CommandResult {
        CommandResult(
            standardOutput: "{}",
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: command.arguments.joined(separator: " ")
        )
    }

    func stream(_ command: ContainerCommand) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.standardOutput("line\n"))
            continuation.yield(.terminated(exitCode: 0))
            continuation.finish()
        }
    }
}
