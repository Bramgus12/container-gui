import Foundation
import XCTest
@testable import Container_GUI

/// These exercise the process plumbing directly against small system binaries,
/// because the behaviour under test — a real terminal, real standard input — is
/// exactly what a stubbed CLI cannot reproduce.
final class InteractiveProcessSessionTests: XCTestCase {
    private func request(
        _ executable: String,
        _ arguments: [String],
        terminalSize: TerminalSize? = nil
    ) -> InteractiveSessionRequest {
        InteractiveSessionRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            terminalSize: terminalSize
        )
    }

    private func collect(
        _ session: any InteractiveProcessSession
    ) async throws -> (output: String, errorOutput: String, exitCode: Int32?) {
        var output = ""
        var errorOutput = ""
        var exitCode: Int32?
        for try await event in session.events {
            switch event {
            case .standardOutput(let text): output.append(text)
            case .standardError(let text): errorOutput.append(text)
            case .terminated(let code): exitCode = code
            }
        }
        return (output, errorOutput, exitCode)
    }

    // MARK: - Pseudo-terminal

    func testPseudoTerminalRunsACommandAndReportsItsExitCode() async throws {
        let session = try PseudoTerminalSession(
            request: request("/bin/echo", ["terminal ready"]),
            size: .default
        )

        let result = try await collect(session)

        XCTAssertTrue(result.output.contains("terminal ready"), "got \(result.output)")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPseudoTerminalMergesStandardErrorIntoTheTerminal() async throws {
        let session = try PseudoTerminalSession(
            request: request("/bin/sh", ["-c", "echo out; echo err 1>&2"]),
            size: .default
        )

        let result = try await collect(session)

        // A terminal has one stream, so both land in standard output.
        XCTAssertTrue(result.output.contains("out"), "got \(result.output)")
        XCTAssertTrue(result.output.contains("err"), "got \(result.output)")
        XCTAssertEqual(result.errorOutput, "")
    }

    func testPseudoTerminalGivesTheChildARealTerminalOfTheRequestedSize() async throws {
        let size = try TerminalSize(columns: 120, rows: 40)
        let session = try PseudoTerminalSession(
            request: request("/bin/sh", ["-c", "test -t 0 && stty size"]),
            size: size
        )

        let result = try await collect(session)

        XCTAssertTrue(result.output.contains("40 120"), "got \(result.output)")
        XCTAssertEqual(result.exitCode, 0)
    }

    /// The terminal settings openpty applies are lost if the device is allowed
    /// to close before the child opens it. Nothing else in the suite notices:
    /// output still arrives, but echo comes back on and every keystroke the user
    /// types would appear twice.
    func testPseudoTerminalKeepsTheTerminalInRawMode() async throws {
        let session = try PseudoTerminalSession(
            request: request("/bin/sh", ["-c", "stty -a"]),
            size: .default
        )

        let result = try await collect(session)

        XCTAssertTrue(result.output.contains("-echo"), "got \(result.output)")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPseudoTerminalForwardsTypedInputToTheChild() async throws {
        let session = try PseudoTerminalSession(
            request: request("/bin/sh", ["-c", "read line; echo \"got:$line\""]),
            size: .default
        )

        session.send("hello\n")
        let result = try await collect(session)

        XCTAssertTrue(result.output.contains("got:hello"), "got \(result.output)")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPseudoTerminalResizeReachesTheChild() async throws {
        // The shell re-reads the window size when it receives SIGWINCH. The
        // sleep runs in the background and is waited on, because a trap must not
        // run while the shell is blocked waiting for a foreground command.
        let session = try PseudoTerminalSession(
            request: request(
                "/bin/sh",
                ["-c", "trap 'stty size; exit 0' WINCH; sleep 5 & wait"]
            ),
            size: .default
        )

        // Give the trap time to be installed before resizing.
        try await Task.sleep(for: .milliseconds(300))
        session.resize(to: try TerminalSize(columns: 100, rows: 30))

        let result = try await collect(session)

        XCTAssertTrue(result.output.contains("30 100"), "got \(result.output)")
    }

    func testTerminatingAPseudoTerminalSessionEndsTheStream() async throws {
        let session = try PseudoTerminalSession(
            request: request("/bin/sh", ["-c", "sleep 30"]),
            size: .default
        )

        Task {
            try await Task.sleep(for: .milliseconds(200))
            session.terminate()
        }
        let result = try await collect(session)

        XCTAssertNotNil(result.exitCode)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testPseudoTerminalReportsALaunchFailure() {
        XCTAssertThrowsError(
            try PseudoTerminalSession(
                request: request("/nonexistent/binary", []),
                size: .default
            )
        ) { error in
            guard case .launchFailed = error as? CLIError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Pipes

    func testPipeSessionKeepsStandardInputOpenUntilEndOfFile() async throws {
        let session = try PipeInteractiveSession(request: request("/bin/cat", []))

        session.send("first\n")
        session.send("second\n")
        session.sendEndOfFile()
        let result = try await collect(session)

        XCTAssertEqual(result.output, "first\nsecond\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPipeSessionKeepsStandardErrorSeparate() async throws {
        let session = try PipeInteractiveSession(
            request: request("/bin/sh", ["-c", "echo out; echo err 1>&2"])
        )

        let result = try await collect(session)

        XCTAssertEqual(result.output, "out\n")
        XCTAssertEqual(result.errorOutput, "err\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPipeSessionChildHasNoTerminal() async throws {
        let session = try PipeInteractiveSession(
            request: request("/bin/sh", ["-c", "test -t 0; echo tty=$?"])
        )

        let result = try await collect(session)

        XCTAssertEqual(result.output, "tty=1\n")
    }

    func testPipeSessionReportsALaunchFailure() {
        XCTAssertThrowsError(
            try PipeInteractiveSession(request: request("/nonexistent/binary", []))
        ) { error in
            guard case .launchFailed = error as? CLIError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Terminal size

    func testTerminalSizeRejectsNonPositiveAndOversizedDimensions() {
        XCTAssertThrowsError(try TerminalSize(columns: 0, rows: 24))
        XCTAssertThrowsError(try TerminalSize(columns: 80, rows: 0))
        XCTAssertThrowsError(try TerminalSize(columns: -1, rows: 24))
        XCTAssertThrowsError(try TerminalSize(columns: 80, rows: 100_000))
        XCTAssertEqual(TerminalSize.default.columns, 80)
        XCTAssertEqual(TerminalSize.default.rows, 24)
    }
}
