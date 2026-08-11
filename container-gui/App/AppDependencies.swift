import Foundation

@MainActor
enum AppDependencies {
    static func makeAppModel(
        processInfo: ProcessInfo = .processInfo
    ) -> AppModel {
        #if DEBUG || UI_TESTING
        let scenario = UITestPreflightScenario(arguments: processInfo.arguments)
            ?? (isHostedXCTest(environment: processInfo.environment) ? .ready : nil)
        if let scenario {
            let setup = SetupModel(
                preflight: UITestPreflightService(scenario: scenario),
                diagnosticsCopier: SystemDiagnosticsCopier()
            )
            return AppModel(
                setup: setup,
                cliFactory: UITestContainerCLIFactory()
            )
        }
        #endif
        return AppModel()
    }

    #if DEBUG || UI_TESTING
    private static func isHostedXCTest(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }
    #endif
}

#if DEBUG || UI_TESTING
nonisolated private enum UITestPreflightScenario: String, Sendable {
    case missing
    case stopped
    case failed
    case ready
    case lifecycle

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
        case .ready, .lifecycle:
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

nonisolated private struct UITestContainerCLIFactory: ContainerCLIMaking {
    private let cli = UITestContainerCLI()

    func makeCLI(executableURL: URL) -> any ContainerCLI {
        cli
    }
}

private actor UITestContainerCLI: ContainerCLI {
    private struct FixtureContainer: Sendable {
        var id: String
        var image: String
        var state: String
    }

    private var containers = [
        FixtureContainer(id: "demo-stopped", image: "alpine:3.21", state: "stopped"),
    ]

    func run(_ command: ContainerCommand) async throws -> CommandResult {
        let output: String
        switch command {
        case .listContainers:
            output = containerListJSON
        case .inspectContainer(let id):
            output = inspectJSON(for: id.rawValue)
        case .start(let id):
            update(id: id.rawValue, state: "running")
            output = ""
        case .stop(let id, _):
            update(id: id.rawValue, state: "stopped")
            output = ""
        case .delete(let id, _):
            containers.removeAll { $0.id == id.rawValue }
            output = ""
        case .systemVersion:
            output = """
            [{"appName":"container","version":"1.0.0"},{"appName":"container-apiserver","version":"1.0.0"}]
            """
        case .systemStatus:
            output = #"{"status":"ready","healthy":true,"version":"1.0.0"}"#
        case .systemDiskUsage:
            output = #"[{"type":"images","totalCount":1,"activeCount":1,"sizeBytes":1024,"reclaimableBytes":0}]"#
        case .systemLogs:
            output = (1...40)
                .map { "UI test service log line \($0)." }
                .joined(separator: "\n")
        case .listImages:
            output = "[]"
        case .inspectImage:
            output = "{}"
        case .systemStart, .systemStop, .pullImage, .deleteImage, .run, .logs, .stats:
            output = ""
        }
        return CommandResult(
            standardOutput: output,
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: "ui-test-container \(command.arguments.joined(separator: " "))"
        )
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch command {
                case .run(let configuration):
                    let id = configuration.name?.rawValue ?? "ui-test-container"
                    await addContainer(
                        id: id,
                        image: configuration.image.rawValue
                    )
                    continuation.yield(.standardOutput("\(id)\n"))
                    continuation.yield(.terminated(exitCode: 0))
                    continuation.finish()
                case .logs:
                    continuation.yield(.standardOutput(
                        "first UI test log line\n\n"
                    ))
                    continuation.yield(.standardOutput(
                        "A deliberately long UI test log line that should wrap inside the inspector without creating a horizontal scrollbar or an extra logical line number.\n"
                    ))
                    continuation.yield(.standardError("final UI test log line\n"))
                    continuation.yield(.terminated(exitCode: 0))
                    continuation.finish()
                default:
                    continuation.yield(.terminated(exitCode: 0))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var containerListJSON: String {
        let rows = containers.map { container in
            """
            {"id":"\(container.id)","configuration":{"id":"\(container.id)","image":"\(container.image)","platform":{"os":"linux","architecture":"arm64"}},"status":{"state":"\(container.state)"}}
            """
        }
        return "[\(rows.joined(separator: ","))]"
    }

    private func inspectJSON(for id: String) -> String {
        guard let container = containers.first(where: { $0.id == id }) else {
            return "{}"
        }
        return """
        {"id":"\(container.id)","configuration":{"id":"\(container.id)","image":"\(container.image)","platform":{"os":"linux","architecture":"arm64"}},"status":{"state":"\(container.state)"}}
        """
    }

    private func update(id: String, state: String) {
        guard let index = containers.firstIndex(where: { $0.id == id }) else { return }
        containers[index].state = state
    }

    private func addContainer(id: String, image: String) {
        containers.removeAll { $0.id == id }
        containers.append(FixtureContainer(id: id, image: image, state: "running"))
    }
}
#endif
