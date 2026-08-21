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
                cliFactory: UITestContainerCLIFactory(scenario: scenario)
            )
        }
        #endif
        return AppModel()
    }

    static func makeUpdateModel(
        processInfo: ProcessInfo = .processInfo
    ) -> UpdateModel {
        #if DEBUG || UI_TESTING
        let isUITest = UITestPreflightScenario(arguments: processInfo.arguments) != nil
            || isHostedXCTest(environment: processInfo.environment)
        if isUITest {
            // Tests never reach the network.
            return UpdateModel(
                service: UITestUpdateService(),
                preferences: InMemoryUpdatePreferences(),
                installCommandCopier: NoopDiagnosticsCopier()
            )
        }
        #endif
        return UpdateModel(service: GitHubUpdateService())
    }

    #if DEBUG || UI_TESTING
    private static func isHostedXCTest(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }
    #endif
}

#if DEBUG || UI_TESTING
/// Reports the running build as current so UI tests never show an update
/// banner and never make a network request.
nonisolated private struct UITestUpdateService: UpdateChecking {
    func latestRelease() throws -> AppRelease {
        AppRelease(
            version: AppVersion.semantic() ?? SemanticVersion(major: 0, minor: 0, patch: 0),
            tag: "v\(AppVersion.current)",
            name: "Container GUI \(AppVersion.current)",
            notes: "",
            pageURL: AppDistribution.releasesURL,
            publishedAt: nil
        )
    }
}

private actor InMemoryUpdatePreferences: UpdatePreferencesStoring {
    private var automatic = true
    private var lastCheck: Date?
    private var skipped: SemanticVersion?

    func automaticChecksEnabled() -> Bool { automatic }
    func setAutomaticChecksEnabled(_ enabled: Bool) { automatic = enabled }
    func lastCheckDate() -> Date? { lastCheck }
    func setLastCheckDate(_ date: Date) { lastCheck = date }
    func skippedVersion() -> SemanticVersion? { skipped }
    func setSkippedVersion(_ version: SemanticVersion?) { skipped = version }
}

@MainActor
private struct NoopDiagnosticsCopier: DiagnosticsCopying {
    func copy(_ value: String) {}
}

nonisolated private enum UITestPreflightScenario: String, Sendable {
    case missing
    case stopped
    case failed
    case ready
    case lifecycle
    case imageCleanup
    case cancelRun
    case networkLegacy
    case networkCurrent

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
        case .networkLegacy:
            .ready(Self.context(isRunning: true, cliVersion: "0.12.0"))
        case .ready, .lifecycle, .imageCleanup, .cancelRun, .networkCurrent:
            .ready(Self.context(isRunning: true))
        }
    }

    private static func context(
        isRunning: Bool,
        cliVersion: String = "1.0.0"
    ) -> PreflightContext {
        PreflightContext(
            executableURL: URL(fileURLWithPath: "/test/container"),
            versions: SystemVersion(components: [
                SystemVersionDTO(
                    appName: "container",
                    version: cliVersion,
                    buildType: nil,
                    commit: nil
                ),
            ]),
            status: SystemStatus(dto: SystemStatusDTO(
                status: isRunning ? "ready" : "stopped",
                healthy: isRunning,
                version: cliVersion,
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
    private let cli: UITestContainerCLI

    init(scenario: UITestPreflightScenario) {
        cli = UITestContainerCLI(scenario: scenario)
    }

    func makeCLI(executableURL: URL) -> any ContainerCLI {
        cli
    }
}

private actor UITestContainerCLI: ContainerCLI {
    private struct FixtureContainer: Sendable {
        var id: String
        var image: String
        var imageDigest: String? = nil
        var state: String
    }

    private struct FixtureNetwork: Sendable {
        var name: String
        var mode: String
        var ipv4Subnet: String?
        var ipv6Subnet: String?
        var plugin: String
        var isBuiltIn: Bool
    }

    private struct FixtureVolume: Sendable {
        var name: String
        var sizeInBytes: UInt64
    }

    private let scenario: UITestPreflightScenario
    private var containers: [FixtureContainer]
    private var images = ["ghcr.io/example/demo:1.0"]
    private var networks = [
        FixtureNetwork(
            name: "default",
            mode: "nat",
            ipv4Subnet: "192.168.64.0/24",
            ipv6Subnet: nil,
            plugin: "container-network-vmnet",
            isBuiltIn: true
        ),
        FixtureNetwork(
            name: "ui-test-network",
            mode: "internal",
            ipv4Subnet: "10.42.0.0/24",
            ipv6Subnet: "fd42::/64",
            plugin: "container-network-vmnet",
            isBuiltIn: false
        ),
    ]
    private var volumes = [FixtureVolume(name: "ui-test-volume", sizeInBytes: 10_485_760)]
    private var builderState: String?

    init(scenario: UITestPreflightScenario) {
        self.scenario = scenario
        containers = [
            FixtureContainer(
                id: "demo-stopped",
                image: "alpine:3.21",
                imageDigest: "sha256:alpine",
                state: "stopped"
            ),
        ]
        if scenario == .imageCleanup {
            containers.append(FixtureContainer(
                id: "image-dependent",
                image: "ghcr.io/example/demo:1.0",
                imageDigest: "sha256:demo-index",
                state: "running"
            ))
        }
    }

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
        case .systemDNSList:
            output = #"["cont"]"#
        case .systemProperties:
            output = #"{"dns":{"domain":"cont"}}"#
        case .systemLogs:
            output = (1...40)
                .map { "UI test service log line \($0)." }
                .joined(separator: "\n")
        case .listImages:
            output = imageListJSON
        case .inspectImage:
            output = """
            [{"configuration":{"name":"ghcr.io/example/demo:1.0","creationDate":"2026-06-16T00:00:15Z","descriptor":{"digest":"sha256:demo-index","size":9218,"mediaType":"application/vnd.oci.image.index.v1+json"}},"variants":[{"digest":"sha256:demo-manifest","size":4184689,"platform":{"os":"linux","architecture":"arm64","variant":"v8"},"config":{"created":"2026-06-15T22:00:00Z","author":"UI Test","architecture":"arm64","os":"linux","config":{"User":"1000:1000","Env":["TOKEN=image-secret","MODE=test"],"Entrypoint":["/bin/demo"],"Cmd":["serve"],"WorkingDir":"/app","Labels":{"org.example.fixture":"true"},"StopSignal":"SIGTERM"},"rootfs":{"type":"layers","diff_ids":["sha256:demo-layer"]},"history":[{"created_by":"COPY demo /bin/demo","empty_layer":false}]}}]}]
            """
        case .deleteImage(let reference):
            let imageReference = reference.rawValue == "sha256:demo-index"
                ? "ghcr.io/example/demo:1.0"
                : reference.rawValue
            if containers.contains(where: { $0.image == imageReference }) {
                throw CLIError.nonZeroExit(
                    invocation: "ui-test-container image delete \(reference.rawValue)",
                    exitCode: 1,
                    standardError: "image is in use"
                )
            }
            images.removeAll { $0 == imageReference }
            output = ""
        case .pruneImages:
            images.removeAll()
            output = ""
        case .listNetworks:
            output = networkListJSON
        case .inspectNetwork(let name):
            output = networkInspectionJSON(name: name.rawValue)
        case .createNetwork(let configuration):
            networks.append(FixtureNetwork(
                name: configuration.name.rawValue,
                mode: configuration.mode.rawValue,
                ipv4Subnet: configuration.ipv4Subnet?.rawValue,
                ipv6Subnet: configuration.ipv6Subnet?.rawValue,
                plugin: configuration.plugin ?? NetworkCreateConfiguration.defaultPlugin,
                isBuiltIn: false
            ))
            output = ""
        case .deleteNetwork(let name):
            networks.removeAll { $0.name == name.rawValue && !$0.isBuiltIn }
            output = ""
        case .pruneNetworks:
            let deleted = networks.filter { !$0.isBuiltIn }.map(\.name)
            networks.removeAll { !$0.isBuiltIn }
            output = deleted.joined(separator: "\n")
        case .listVolumes:
            output = volumeListJSON
        case .inspectVolume(let name):
            output = volumeInspectionJSON(name: name.rawValue)
        case .createVolume(let configuration):
            volumes.append(FixtureVolume(
                name: configuration.name.rawValue,
                sizeInBytes: 10_485_760
            ))
            output = ""
        case .deleteVolume(let name):
            volumes.removeAll { $0.name == name.rawValue }
            output = ""
        case .pruneVolumes:
            let deleted = volumes.map(\.name)
            volumes.removeAll()
            output = "Reclaimed 10,5 MB in disk space\n" + deleted.joined(separator: "\n")
        case .builderStatus:
            if let builderState {
                output = #"[{"id":"buildkit","configuration":{"image":{"reference":"ghcr.io/apple/container-builder-shim/builder:1.0.0"}},"status":{"state":"\#(builderState)","address":"192.168.64.2"}}]"#
            } else {
                output = "[]"
            }
        case .builderStart:
            builderState = "running"
            output = ""
        case .builderStop:
            builderState = "stopped"
            output = ""
        case .builderDelete:
            builderState = nil
            output = ""
        case .logs:
            output = """
            first UI test log line

            A deliberately long UI test log line that should wrap inside the inspector without creating a horizontal scrollbar or an extra logical line number.
            final UI test log line
            """
        case .systemStart, .systemStop, .pullImage, .build, .run, .stats:
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
                    if scenario == .cancelRun {
                        continuation.yield(.standardError("Starting cancellable run…\n"))
                        do {
                            try await Task.sleep(for: .seconds(30))
                        } catch {
                            continuation.finish(throwing: CLIError.cancelled)
                            return
                        }
                    }
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
                case .build(let configuration):
                    continuation.yield(.standardError("Building image…\n"))
                    await addImage(configuration.tag.rawValue)
                    continuation.yield(.standardOutput("\(configuration.tag.rawValue)\n"))
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
            let digest = container.imageDigest.map { #", "digest":"\#($0)""# } ?? ""
            return """
            {"id":"\(container.id)","configuration":{"id":"\(container.id)","image":{"reference":"\(container.image)"\(digest)},"platform":{"os":"linux","architecture":"arm64"}},"status":{"state":"\(container.state)"}}
            """
        }
        return "[\(rows.joined(separator: ","))]"
    }

    private var imageListJSON: String {
        let rows = images.map { reference in
            """
            {"name":"\(reference)","descriptor":{"digest":"sha256:demo-index","size":9218,"mediaType":"application/vnd.oci.image.index.v1+json"},"createdAt":"2026-06-16T00:00:15Z","platform":{"os":"linux","architecture":"arm64"}}
            """
        }
        return "[\(rows.joined(separator: ","))]"
    }

    private var networkListJSON: String {
        "[\(networks.map(networkJSON).joined(separator: ","))]"
    }

    private var volumeListJSON: String {
        "[\(volumes.map(volumeJSON).joined(separator: ","))]"
    }

    private func volumeInspectionJSON(name: String) -> String {
        guard let volume = volumes.first(where: { $0.name == name }) else { return "[]" }
        return "[\(volumeJSON(volume))]"
    }

    private func volumeJSON(_ volume: FixtureVolume) -> String {
        """
        {"id":"\(volume.name)","configuration":{"creationDate":"2026-08-12T19:42:52Z","driver":"local","format":"ext4","labels":{"org.example.fixture":"true"},"name":"\(volume.name)","options":{"size":"10M"},"sizeInBytes":\(volume.sizeInBytes),"source":"/test/volumes/\(volume.name)/volume.img"}}
        """
    }

    private func networkInspectionJSON(name: String) -> String {
        guard let network = networks.first(where: { $0.name == name }) else { return "[]" }
        return networkJSON(network)
    }

    private func networkJSON(_ network: FixtureNetwork) -> String {
        var status: [String] = []
        if let ipv4Subnet = network.ipv4Subnet {
            status.append(#""ipv4Subnet":"\#(ipv4Subnet)""#)
            status.append(#""ipv4Gateway":"192.168.64.1""#)
        }
        if let ipv6Subnet = network.ipv6Subnet {
            status.append(#""ipv6Subnet":"\#(ipv6Subnet)""#)
        }
        let labels = network.isBuiltIn
            ? #"{"com.apple.container.resource.role":"builtin"}"#
            : #"{"org.example.fixture":"true"}"#
        return """
        {"id":"\(network.name)","configuration":{"name":"\(network.name)","mode":"\(network.mode)","creationDate":"2026-06-16T00:00:15.123Z","labels":\(labels),"plugin":"\(network.plugin)","options":{"fixture":"enabled"}},"status":{\(status.joined(separator: ","))}}
        """
    }

    private func inspectJSON(for id: String) -> String {
        guard let container = containers.first(where: { $0.id == id }) else {
            return "{}"
        }
        return """
        {"id":"\(container.id)","configuration":{"id":"\(container.id)","image":{"reference":"\(container.image)","digest":"sha256:demo"},"platform":{"os":"linux","architecture":"arm64"},"creationDate":"2026-06-16T00:00:15Z","initProcess":{"executable":"/bin/demo","arguments":["serve"],"environment":["API_TOKEN=container-secret","MODE=test"],"workingDirectory":"/app","terminal":false},"resources":{"cpus":2,"memoryInBytes":1073741824},"labels":{"org.example.fixture":"true"},"readOnly":true,"capDrop":["CAP_SYS_ADMIN"]},"status":{"state":"\(container.state)","startedDate":"2026-06-16T00:01:00Z"}}
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

    private func addImage(_ reference: String) {
        if !images.contains(reference) { images.append(reference) }
    }
}
#endif
