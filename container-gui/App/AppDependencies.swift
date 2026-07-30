import Foundation

@MainActor
enum AppDependencies {
    static func makeAppModel(
        processInfo: ProcessInfo = .processInfo
    ) -> AppModel {
        #if DEBUG
        if let scenario = UITestPreflightScenario(arguments: processInfo.arguments) {
            return AppModel(
                setup: SetupModel(
                    preflight: UITestPreflightService(scenario: scenario),
                    diagnosticsCopier: SystemDiagnosticsCopier()
                )
            )
        }
        #endif
        return AppModel()
    }
}

#if DEBUG
nonisolated private enum UITestPreflightScenario: String, Sendable {
    case missing
    case stopped
    case failed
    case ready

    init?(arguments: [String]) {
        guard let flagIndex = arguments.firstIndex(of: "--ui-test-preflight"),
              arguments.indices.contains(flagIndex + 1)
        else {
            return nil
        }
        self.init(rawValue: arguments[flagIndex + 1])
    }

    var readiness: PreflightReadiness {
        switch self {
        case .missing:
            .missingCLI(customExecutableURL: nil)
        case .stopped:
            .serviceStopped(Self.context(isRunning: false))
        case .failed:
            .failure(
                executableURL: URL(fileURLWithPath: "/test/container"),
                diagnostic: PreflightDiagnostic(error: CLIError.nonZeroExit(
                    invocation: "/test/container system status --format json",
                    exitCode: 17,
                    standardError: "service unavailable"
                ))
            )
        case .ready:
            .ready(Self.context(isRunning: true))
        }
    }

    private static func context(isRunning: Bool) -> PreflightContext {
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
                version: "1.0.0",
                message: isRunning ? nil : "Service is stopped"
            ))
        )
    }
}

private actor UITestPreflightService: PreflightServicing {
    private var scenario: UITestPreflightScenario

    init(scenario: UITestPreflightScenario) {
        self.scenario = scenario
    }

    func check() -> PreflightReadiness {
        scenario.readiness
    }

    func retry() -> PreflightReadiness {
        scenario.readiness
    }

    func selectCustomExecutable(_ url: URL) -> PreflightReadiness {
        scenario.readiness
    }

    func resetCustomExecutable() -> PreflightReadiness {
        scenario.readiness
    }

    func startService() -> PreflightReadiness {
        if scenario == .stopped {
            scenario = .ready
        }
        return scenario.readiness
    }
}
#endif
