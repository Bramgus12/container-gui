import Foundation
import XCTest
@testable import Container_GUI

@MainActor
final class SetupModelTests: XCTestCase {
    func testInitialCheckPublishesMissingStateAndOnlyRunsOnce() async {
        let preflight = SetupPreflightStub(states: [.missingCLI(customExecutableURL: nil)])
        let model = SetupModel(
            preflight: preflight,
            diagnosticsCopier: DiagnosticsCopierSpy()
        )

        await model.checkIfNeeded()
        await model.checkIfNeeded()

        let checkCount = await preflight.checkCount
        XCTAssertEqual(model.readiness, .missingCLI(customExecutableURL: nil))
        XCTAssertEqual(checkCount, 1)
        XCTAssertFalse(model.isWorking)
    }

    func testStartServiceTransitionsFromStoppedToReady() async {
        let stopped = setupContext(isRunning: false)
        let ready = setupContext(isRunning: true)
        let preflight = SetupPreflightStub(
            states: [.serviceStopped(stopped)],
            startState: .ready(ready)
        )
        let model = SetupModel(
            preflight: preflight,
            diagnosticsCopier: DiagnosticsCopierSpy()
        )

        await model.checkIfNeeded()
        await model.startService()

        let startCount = await preflight.startCount
        XCTAssertEqual(model.readiness, .ready(ready))
        XCTAssertEqual(startCount, 1)
    }

    func testFailureDiagnosticsAreSanitizedAndCopied() async {
        let diagnostic = PreflightDiagnostic(error: CLIError.nonZeroExit(
            invocation: "/test/container system status --format json",
            exitCode: 23,
            standardError: "token=super-secret service unavailable"
        ))
        let copier = DiagnosticsCopierSpy()
        let model = SetupModel(
            preflight: SetupPreflightStub(states: [
                .failure(
                    executableURL: URL(fileURLWithPath: "/test/container"),
                    diagnostic: diagnostic
                ),
            ]),
            diagnosticsCopier: copier
        )

        await model.checkIfNeeded()
        model.copyDiagnostics()

        let copied = copier.value
        XCTAssertTrue(copied?.contains("Exit code: 23") == true)
        XCTAssertTrue(copied?.contains("token=<redacted>") == true)
        XCTAssertFalse(copied?.contains("super-secret") == true)
        XCTAssertTrue(model.didCopyDiagnostics)
    }

    private func setupContext(isRunning: Bool) -> PreflightContext {
        PreflightContext(
            executableURL: URL(fileURLWithPath: "/test/container"),
            versions: SystemVersion(components: [
                SystemVersionDTO(
                    appName: "container",
                    version: "1.0.0",
                    buildType: nil,
                    commit: nil
                ),
            ]),
            status: SystemStatus(dto: SystemStatusDTO(
                status: isRunning ? "ready" : "stopped",
                healthy: isRunning,
                version: nil,
                message: nil
            ))
        )
    }
}

private actor SetupPreflightStub: PreflightServicing {
    private var states: [PreflightReadiness]
    private let startState: PreflightReadiness?
    private(set) var checkCount = 0
    private(set) var startCount = 0

    init(
        states: [PreflightReadiness],
        startState: PreflightReadiness? = nil
    ) {
        self.states = states
        self.startState = startState
    }

    func check() -> PreflightReadiness {
        checkCount += 1
        return states.removeFirst()
    }

    func retry() -> PreflightReadiness {
        states.first ?? startState ?? .checking
    }

    func selectCustomExecutable(_ url: URL) -> PreflightReadiness {
        states.first ?? startState ?? .checking
    }

    func resetCustomExecutable() -> PreflightReadiness {
        states.first ?? startState ?? .checking
    }

    func startService() -> PreflightReadiness {
        startCount += 1
        return startState ?? .checking
    }
}

@MainActor
private final class DiagnosticsCopierSpy: DiagnosticsCopying {
    private(set) var value: String?

    func copy(_ value: String) {
        self.value = value
    }
}
