import Foundation
import XCTest
@testable import Container_GUI

final class ProcessContainerCLITests: XCTestCase {
    func testCapturesStandardOutputStandardErrorAndDuration() async throws {
        let cli = makeCLI(scenario: "success")

        let result = try await cli.run(.systemStatus)

        XCTAssertEqual(
            result.standardOutput,
            "fixture stdout: system status --format json\n"
        )
        XCTAssertEqual(result.standardError, "fixture stderr\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(result.duration, .zero)
        XCTAssertTrue(result.invocation.contains("system status --format json"))
    }

    func testMapsNonzeroExitToTypedError() async {
        let cli = makeCLI(
            scenario: "failure",
            additionalEnvironment: ["FAKE_CONTAINER_EXIT_CODE": "37"]
        )

        do {
            _ = try await cli.run(.systemStatus)
            XCTFail("Expected a nonzero-exit error")
        } catch let error as CLIError {
            guard case .nonZeroExit(
                let invocation,
                let exitCode,
                let standardError,
                let standardOutput
            ) = error else {
                return XCTFail("Unexpected CLI error: \(error)")
            }
            XCTAssertEqual(exitCode, 37)
            XCTAssertEqual(standardError, "simulated failure\n")
            XCTAssertEqual(standardOutput, "simulated failure output\n")
            XCTAssertTrue(invocation.contains("system status --format json"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationTerminatesTheChild() async {
        let cli = makeCLI(scenario: "delay", timeout: nil)
        let task = Task {
            try await cli.run(.systemStatus)
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as CLIError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutTerminatesTheChild() async {
        let cli = makeCLI(scenario: "delay", timeout: .milliseconds(100))

        do {
            _ = try await cli.run(.systemStatus)
            XCTFail("Expected a timeout")
        } catch let error as CLIError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLargeSimultaneousOutputDoesNotDeadlock() async throws {
        let cli = makeCLI(
            scenario: "large",
            outputLimit: 2 * 1_024 * 1_024,
            timeout: .seconds(10)
        )

        let result = try await cli.run(.systemStatus)

        XCTAssertTrue(result.standardOutput.contains("stdout-19999"))
        XCTAssertTrue(result.standardError.contains("stderr-19999"))
    }

    func testOutputLimitTerminatesTheChildAndReturnsTypedError() async {
        let cli = makeCLI(scenario: "large", outputLimit: 1_024)

        do {
            _ = try await cli.run(.systemStatus)
            XCTFail("Expected an output-limit error")
        } catch let error as CLIError {
            XCTAssertEqual(error, .outputLimitExceeded(limit: 1_024))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidUTF8UsesReplacementCharacters() async throws {
        let result = try await makeCLI(scenario: "invalid-utf8").run(.systemStatus)

        XCTAssertTrue(result.standardOutput.contains("\u{FFFD}valid"))
    }

    func testStreamYieldsOutputBeforeTheProcessTerminates() async throws {
        let cli = makeCLI(scenario: "stream", timeout: nil)
        let clock = ContinuousClock()
        let start = clock.now
        var iterator = cli.stream(.systemStatus).makeAsyncIterator()

        let first = try await iterator.next()

        XCTAssertEqual(first, .standardOutput("first\n"))
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(900))
    }

    func testCancellingStreamConsumerTerminatesTheChild() async throws {
        let cli = makeCLI(scenario: "delay", timeout: nil)
        let consumer = Task {
            for try await _ in cli.stream(.systemStatus) {}
        }

        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()

        do {
            try await consumer.value
        } catch let error as CLIError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // AsyncThrowingStream may surface task cancellation directly.
        }
    }

    func testInvocationQuotesArgumentsAndRedactsSensitiveEnvironmentValues() async throws {
        let secret = try EnvironmentVariable(key: "API_TOKEN", value: "don't show this")
        let visible = try EnvironmentVariable(key: "GREETING", value: "hello world")
        let configuration = try RunConfiguration(
            image: "example/app:latest",
            environment: [secret, visible]
        )

        let result = try await makeCLI(scenario: "success").run(.run(configuration))

        XCTAssertFalse(result.invocation.contains("don't show this"))
        XCTAssertTrue(result.invocation.contains("'API_TOKEN=<redacted>'"))
        XCTAssertTrue(result.invocation.contains("'GREETING=hello world'"))
    }

    func testRejectsMissingDirectoryAndNonExecutableURLs() async throws {
        let missingURL = fixtureURL.deletingLastPathComponent()
            .appendingPathComponent("missing-fixture")
        let missing = ProcessContainerCLI(executableURL: missingURL)
        let directory = ProcessContainerCLI(
            executableURL: fixtureURL.deletingLastPathComponent()
        )
        let nonExecutableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("text".utf8).write(to: nonExecutableURL)
        defer { try? FileManager.default.removeItem(at: nonExecutableURL) }
        let nonExecutable = ProcessContainerCLI(executableURL: nonExecutableURL)

        await assertCLIError(.executableNotFound(missingURL)) {
            try await missing.run(.systemStatus)
        }
        await assertCLIError(.executableIsNotAFile(fixtureURL.deletingLastPathComponent())) {
            try await directory.run(.systemStatus)
        }
        await assertCLIError(.executableIsNotExecutable(nonExecutableURL)) {
            try await nonExecutable.run(.systemStatus)
        }
    }

    func testRejectsNonFileURL() async {
        let url = URL(string: "https://example.com/container")!
        let cli = ProcessContainerCLI(executableURL: url)

        await assertCLIError(.executableIsNotAbsolute(url)) {
            try await cli.run(.systemStatus)
        }
    }

    func testMapsProcessLaunchFailureToTypedError() async throws {
        let invalidExecutableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not an executable format".utf8).write(to: invalidExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: invalidExecutableURL.path
        )
        defer { try? FileManager.default.removeItem(at: invalidExecutableURL) }
        let cli = ProcessContainerCLI(executableURL: invalidExecutableURL)

        do {
            _ = try await cli.run(.systemStatus)
            XCTFail("Expected a launch failure")
        } catch let error as CLIError {
            guard case .launchFailed(let message) = error else {
                return XCTFail("Unexpected CLI error: \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-container")
    }

    private func makeCLI(
        scenario: String,
        outputLimit: Int = ProcessContainerCLI.defaultOutputLimit,
        timeout: Duration? = .seconds(5),
        additionalEnvironment: [String: String] = [:]
    ) -> ProcessContainerCLI {
        ProcessContainerCLI(
            executableURL: fixtureURL,
            environment: additionalEnvironment.merging(
                ["FAKE_CONTAINER_SCENARIO": scenario],
                uniquingKeysWith: { existing, _ in existing }
            ),
            outputLimit: outputLimit,
            timeout: timeout
        )
    }

    private func assertCLIError(
        _ expected: CLIError,
        operation: () async throws -> CommandResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as CLIError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
