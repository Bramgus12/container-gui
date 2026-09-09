import Foundation
import XCTest
@testable import CargoDeck

final class MachineTerminalTests: XCTestCase {

    // MARK: - UTF-8 across read boundaries

    /// Reads off a pseudo-terminal land on arbitrary byte boundaries. Decoding
    /// each read independently turns any character split across one into U+FFFD,
    /// which a terminal shows the moment anything draws a box or prints an
    /// accent.
    func testIncompleteTrailingSequencesAreDetected() {
        // "é" is two bytes; a buffer ending on its leader is one byte short.
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: [0xC3]), 1)
        // "€" is three bytes: leader alone, then leader plus one continuation.
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: [0xE2]), 1)
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: [0xE2, 0x82]), 2)
        // "😀" is four bytes.
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: [0xF0, 0x9F, 0x98]), 3)
    }

    func testCompleteBuffersAreNotHeldBack() {
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: []), 0)
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: Array("hello".utf8)), 0)
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: Array("héllo".utf8)), 0)
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: Array("box │ drawing".utf8)), 0)
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: Array("😀".utf8)), 0)
        // An escape sequence is pure ASCII and must never be deferred.
        XCTAssertEqual(
            PseudoTerminalSession.incompleteSuffixLength(of: Array("\u{1B}[31m".utf8)),
            0
        )
    }

    /// Genuinely malformed bytes are the terminal's business to display, not
    /// something to hold forever waiting for a completion that never comes.
    func testMalformedBytesAreNotDeferred() {
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: [0xFF]), 0)
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: [0x80]), 0)
        XCTAssertEqual(PseudoTerminalSession.incompleteSuffixLength(of: [0x80, 0x80, 0x80]), 0)
    }

    /// Splitting a string at every possible byte offset and reassembling the
    /// two decodes must reproduce it exactly — that is the property the read
    /// loop depends on.
    func testEverySplitPointReassemblesExactly() {
        let original = "héllo ▏box│ 😀 端末 ünïcödé"
        let bytes = Array(original.utf8)

        for split in 0...bytes.count {
            let head = Array(bytes[..<split])
            let tail = Array(bytes[split...])

            let carried = PseudoTerminalSession.incompleteSuffixLength(of: head)
            let emitted = String(decoding: head[..<(head.count - carried)], as: UTF8.self)
            let remainder = Array(head[(head.count - carried)...]) + tail
            let rest = String(decoding: remainder, as: UTF8.self)

            XCTAssertEqual(
                emitted + rest,
                original,
                "Splitting after \(split) bytes did not round-trip."
            )
        }
    }

    // MARK: - Logs

    /// A machine created with `--no-boot` has never written a log file, and the
    /// CLI reports that as a failure. Nothing is wrong — there is just nothing
    /// to read — so it must reach the empty state rather than an error banner.
    /// The real message is reproduced verbatim from CLI 1.3.0, including the
    /// curly apostrophe and the fact that it names `stdio.log` even when
    /// `--boot` was requested.
    func testAMissingLogFileIsNotTreatedAsAFailure() {
        let real = CLIError.nonZeroExit(
            invocation: "container machine logs --boot -n 3 gui-demo",
            exitCode: 1,
            standardError: "Error: failed to get logs for container machine "
                + "gui-demo (cause: internalError: failed to open container "
                + "machine logs: Error Domain=NSCocoaErrorDomain Code=4 "
                + "The file “stdio.log” doesn’t exist.)"
        )
        XCTAssertTrue(MachineLogsModel.describesAMissingLogFile(real))

        XCTAssertTrue(MachineLogsModel.describesAMissingLogFile(
            CLIError.launchFailed(message: "No such file or directory")
        ))

        // A real failure still has to surface.
        XCTAssertFalse(MachineLogsModel.describesAMissingLogFile(
            CLIError.nonZeroExit(
                invocation: "container machine logs dev",
                exitCode: 1,
                standardError: "Error: no such container machine 'dev'"
            )
        ))
        XCTAssertFalse(MachineLogsModel.describesAMissingLogFile(CLIError.timedOut))
    }

    // MARK: - Run model

    @MainActor
    func testBlankCommandIsALoginShell() {
        let model = MachineRunModel(
            machineID: "dev-box",
            isRunning: true,
            service: RunServiceStub()
        )

        XCTAssertTrue(model.isLoginShell)
        XCTAssertFalse(model.willBootFirst)
        XCTAssertEqual(model.configuration?.command, [])
        XCTAssertTrue(model.commandPreview.contains("machine run"))
    }

    /// A stopped machine boots on the way in, and the first boot also creates
    /// the user — the sheet warns before the wait, not after.
    @MainActor
    func testAStoppedMachineIsFlaggedAsBootingFirst() {
        let model = MachineRunModel(
            machineID: "dev-box",
            isRunning: false,
            service: RunServiceStub()
        )
        XCTAssertTrue(model.willBootFirst)
    }

    @MainActor
    func testCommandParsingHonoursQuotes() {
        let model = MachineRunModel(
            machineID: "dev-box",
            isRunning: true,
            service: RunServiceStub()
        )

        model.command = "cat /proc/cpuinfo"
        XCTAssertEqual(model.configuration?.command, ["cat", "/proc/cpuinfo"])

        model.command = "ls -la /var/log"
        XCTAssertEqual(model.configuration?.command, ["ls", "-la", "/var/log"])

        model.command = #"echo "hello there" done"#
        XCTAssertEqual(model.configuration?.command, ["echo", "hello there", "done"])

        model.command = "ls '/path with spaces'"
        XCTAssertEqual(model.configuration?.command, ["ls", "/path with spaces"])

        model.command = "   nproc   "
        XCTAssertEqual(model.configuration?.command, ["nproc"])
        XCTAssertFalse(model.isLoginShell)
    }

    @MainActor
    func testRootAndAnExplicitUserAreMutuallyExclusive() {
        let model = MachineRunModel(
            machineID: "dev-box",
            isRunning: true,
            service: RunServiceStub()
        )

        model.runsAsRoot = true
        model.user = "bram"
        XCTAssertNotNil(model.userError)
        XCTAssertNil(model.configuration, "The CLI cannot be given both.")

        model.runsAsRoot = false
        XCTAssertNil(model.userError)
        XCTAssertNotNil(model.configuration)
    }

    @MainActor
    func testStartFailureIsSurfacedRatherThanThrown() {
        let service = RunServiceStub()
        service.failsToAttach = true
        let model = MachineRunModel(
            machineID: "dev-box",
            isRunning: true,
            service: service
        )

        model.start()

        XCTAssertNil(model.session)
        XCTAssertNotNil(model.startFailure)
    }

    @MainActor
    func testEnvironmentVariablesReachTheCommand() {
        let model = MachineRunModel(
            machineID: "dev-box",
            isRunning: true,
            service: RunServiceStub()
        )
        model.addEnvironmentVariable()
        model.environment[0].key = "RUST_LOG"
        model.environment[0].value = "debug"

        XCTAssertEqual(
            model.configuration?.environment.first?.argument,
            "RUST_LOG=debug"
        )
        XCTAssertTrue(model.commandPreview.contains("RUST_LOG=debug"))

        // A half-typed row is ignored rather than failing the whole command.
        model.addEnvironmentVariable()
        XCTAssertEqual(model.configuration?.environment.count, 1)
    }
}

private final class RunServiceStub: MachineManaging, @unchecked Sendable {
    var failsToAttach = false

    func listMachines() async throws -> [MachineSummary] { [] }

    func inspectMachine(name: String) async throws -> MachineInspection {
        throw CLIError.invalidOutput(description: "not used")
    }

    func createMachine(_ configuration: MachineCreateConfiguration) async throws -> String { "" }
    func applyBootConfiguration(_ configuration: MachineSetConfiguration) async throws {}
    func setDefaultMachine(name: String) async throws {}
    func stopMachine(name: String) async throws {}
    func deleteMachine(name: String) async throws {}

    nonisolated func streamLogs(
        _ options: MachineLogOptions
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func attachRun(
        _ configuration: MachineRunConfiguration,
        terminalSize: TerminalSize
    ) throws -> any InteractiveProcessSession {
        throw CLIError.launchFailed(message: "This container CLI does not support interactive sessions.")
    }
}
