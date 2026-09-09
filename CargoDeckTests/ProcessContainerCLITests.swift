import Foundation
import XCTest
@testable import CargoDeck

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

    // MARK: - Standard input

    /// The sentinel is deliberately awkward: spaces, quotes, a leading dash and
    /// non-ASCII all have to survive as data rather than being re-read as
    /// arguments or mangled in transit.
    private static let sentinelPassword = #"-not-a-flag 'quoted" pa$$ wörd"#

    private func loginCommand() throws -> ContainerCommand {
        .loginRegistry(
            configuration: try RegistryLoginConfiguration(
                server: "registry.example.test",
                username: "ci-user",
                scheme: .https
            )
        )
    }

    func testStandardInputReachesTheChildFollowedByEndOfFile() async throws {
        let cli = makeCLI(scenario: "stdin-echo")
        var payload = Data(Self.sentinelPassword.utf8)
        payload.append(0x0A)

        let result = try await cli.run(try loginCommand(), standardInput: payload)

        // The fixture's `cat` only returns on EOF, so reaching a zero exit with
        // the full payload echoed proves both delivery and the closed pipe.
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.standardOutput.contains("stdin:" + Self.sentinelPassword),
            result.standardOutput
        )
    }

    func testStandardInputIsDataRatherThanAnArgument() async throws {
        let cli = makeCLI(scenario: "stdin-echo")
        var payload = Data(Self.sentinelPassword.utf8)
        payload.append(0x0A)

        let result = try await cli.run(try loginCommand(), standardInput: payload)

        let arguments = result.standardOutput
            .split(separator: "\n")
            .first { $0.hasPrefix("args:") }
            .map(String.init) ?? ""
        XCTAssertTrue(arguments.contains("--password-stdin"), arguments)
        XCTAssertFalse(
            arguments.contains(Self.sentinelPassword),
            "The password must never reach the child's argument vector."
        )
    }

    func testInvocationNeverCarriesTheStandardInputPayload() async throws {
        let cli = makeCLI(scenario: "stdin-echo")
        var payload = Data(Self.sentinelPassword.utf8)
        payload.append(0x0A)

        let result = try await cli.run(try loginCommand(), standardInput: payload)

        XCTAssertFalse(result.invocation.contains(Self.sentinelPassword), result.invocation)
        XCTAssertTrue(result.invocation.contains("--password-stdin"), result.invocation)
    }

    func testFailedLoginErrorNeverCarriesTheStandardInputPayload() async throws {
        let cli = makeCLI(scenario: "stdin-failure")
        var payload = Data(Self.sentinelPassword.utf8)
        payload.append(0x0A)

        do {
            _ = try await cli.run(try loginCommand(), standardInput: payload)
            XCTFail("Expected a nonzero exit")
        } catch let error as CLIError {
            guard case .nonZeroExit(let invocation, let exitCode, let standardError, _) = error else {
                return XCTFail("Unexpected CLI error: \(error)")
            }
            XCTAssertEqual(exitCode, 13)
            XCTAssertFalse(invocation.contains(Self.sentinelPassword), invocation)
            XCTAssertFalse(standardError.contains(Self.sentinelPassword), standardError)
            XCTAssertFalse(
                (error.errorDescription ?? "").contains(Self.sentinelPassword),
                "The localized description must not carry the secret either."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutTerminatesAChildThatReadStandardInput() async throws {
        let cli = makeCLI(scenario: "stdin-hang", timeout: .milliseconds(200))
        var payload = Data(Self.sentinelPassword.utf8)
        payload.append(0x0A)

        do {
            _ = try await cli.run(try loginCommand(), standardInput: payload)
            XCTFail("Expected a timeout")
        } catch let error as CLIError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationTerminatesAChildThatReadStandardInput() async throws {
        let cli = makeCLI(scenario: "stdin-hang", timeout: nil)
        var payload = Data(Self.sentinelPassword.utf8)
        payload.append(0x0A)
        let command = try loginCommand()
        let task = Task {
            try await cli.run(command, standardInput: payload)
        }

        try? await Task.sleep(for: .milliseconds(150))
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

    func testStubsRefuseAStandardInputPayloadRatherThanDroppingIt() async {
        // The protocol default must not silently run the command without the
        // payload — a login that quietly lost its password would look like a
        // wrong-credentials failure.
        let cli: any ContainerCLI = StandardInputUnawareCLI()

        do {
            _ = try await cli.run(.listRegistries, standardInput: Data("secret".utf8))
            XCTFail("Expected the default implementation to refuse a payload")
        } catch let error as CLIError {
            guard case .launchFailed(let message) = error else {
                return XCTFail("Unexpected CLI error: \(error)")
            }
            XCTAssertTrue(message.contains("standard input"), message)
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

private struct StandardInputUnawareCLI: ContainerCLI {
    func run(_ command: ContainerCommand) async throws -> CommandResult {
        CommandResult(
            standardOutput: "",
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: "stub"
        )
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
