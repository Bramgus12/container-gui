import Foundation
import XCTest
@testable import Container_GUI

final class SystemManagementServiceTests: XCTestCase {
    func testDiskUsageDecodesArrayAndKeyedShapesTolerantly() throws {
        let array = try SystemDiskUsage.decode(from: Data("""
        [
          {
            "type": "images",
            "total_count": 4,
            "active": "2",
            "size_bytes": 8192,
            "reclaimable_size": "1024",
            "future": true
          }
        ]
        """.utf8))
        XCTAssertEqual(array.resources.first?.type, "images")
        XCTAssertEqual(array.resources.first?.totalCount, 4)
        XCTAssertEqual(array.resources.first?.activeCount, 2)
        XCTAssertEqual(array.resources.first?.sizeBytes, 8_192)
        XCTAssertEqual(array.resources.first?.reclaimableBytes, 1_024)

        let keyed = try SystemDiskUsage.decode(from: Data("""
        {
          "containers": {
            "count": 3,
            "activeCount": 1,
            "size": 4096,
            "reclaimable": 2048
          }
        }
        """.utf8))
        XCTAssertEqual(keyed.resources.first?.type, "containers")
        XCTAssertEqual(keyed.resources.first?.totalCount, 3)
    }

    func testPropertiesGroupSectionsInReadingOrderAndFormatScalars() throws {
        let properties = try SystemProperties.decode(
            from: Data(systemPropertiesFixture.utf8)
        )

        XCTAssertEqual(
            properties.sections.map(\.name),
            [
                "machine",
                "container",
                "build",
                "kernel",
                "vminit",
                "registry",
                "network",
                "dns",
                "future",
            ]
        )
        XCTAssertEqual(properties.sections.first?.displayName, "Machine")
        XCTAssertEqual(properties.sections.last?.displayName, "Future")
        XCTAssertEqual(properties.value(section: "machine", key: "cpus"), "5")
        XCTAssertEqual(properties.value(section: "machine", key: "homeMount"), "rw")
        XCTAssertEqual(properties.dnsDomain, "cont")
        // Booleans arrive as numbers, and whole numbers must stay whole.
        XCTAssertEqual(properties.value(section: "machine", key: "virtualization"), "false")
        XCTAssertEqual(properties.value(section: "build", key: "rosetta"), "true")
        XCTAssertEqual(properties.value(section: "build", key: "cpus"), "2")
        // An empty section is kept rather than dropped, so the pane can show
        // that the CLI has one and that nothing is set in it.
        XCTAssertEqual(properties.sections.first { $0.name == "network" }?.values, [:])
        // Shapes a later CLI could introduce still reach the pane.
        XCTAssertEqual(properties.value(section: "future", key: "nested.key"), "value")
        XCTAssertEqual(properties.value(section: "future", key: "list"), "one, two")
    }

    func testPropertiesRejectPayloadsThatAreNotObjects() {
        XCTAssertThrowsError(try SystemProperties.decode(from: Data("[]".utf8))) { error in
            guard case .invalidOutput = error as? CLIError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try SystemProperties.decode(from: Data("truncated".utf8)))
    }

    func testSystemServiceReadsPropertiesAndKeepsTheSnapshotWhenTheyFail() async throws {
        let service = CLISystemService(cli: SystemCLIStub(
            version: #"[{"appName":"container","version":"1.0.0"}]"#,
            status: #"{"status":"ready","healthy":true}"#,
            diskUsage: #"[{"type":"images","totalCount":2,"sizeBytes":42}]"#,
            logs: "",
            properties: systemPropertiesFixture
        ))

        let snapshot = try await service.loadSnapshot()

        XCTAssertEqual(
            snapshot.properties?.value(section: "registry", key: "domain"),
            "docker.io"
        )

        // Properties are supplementary: a CLI that cannot list them must still
        // leave the rest of the System pane with something to show.
        let degradedCLI = SystemCLIStub(
            version: #"[{"appName":"container","version":"1.0.0"}]"#,
            status: #"{"status":"ready","healthy":true}"#,
            diskUsage: #"[{"type":"images","totalCount":2,"sizeBytes":42}]"#,
            logs: "",
            properties: "this is not the JSON you are looking for"
        )
        let degraded = try await CLISystemService(cli: degradedCLI).loadSnapshot()

        XCTAssertNil(degraded.properties)
        XCTAssertTrue(degraded.status.isRunning)
        XCTAssertEqual(degraded.diskUsage.resources.first?.sizeBytes, 42)
        let commands = await degradedCLI.commands
        XCTAssertTrue(commands.contains(.systemProperties))
    }

    func testSystemServiceRunsReadCommandsAndBoundsSanitizesLogs() async throws {
        let longLogs = (0..<2_100)
            .map { "line \($0) MY_SECRET_PASSWORD=not-safe" }
            .joined(separator: "\n")
        let cli = SystemCLIStub(
            version: """
                [{"appName":"container","version":"1.0.0"},
                 {"appName":"container-apiserver","version":"1.0.1"}]
                """,
            status: #"{"status":"ready","healthy":true}"#,
            diskUsage: #"[{"type":"images","totalCount":2,"sizeBytes":42}]"#,
            logs: longLogs
        )
        let service = CLISystemService(cli: cli)

        let snapshot = try await service.loadSnapshot()
        let logs = try await service.loadRecentLogs()

        XCTAssertEqual(snapshot.versions.cli?.version, "1.0.0")
        XCTAssertTrue(snapshot.status.isRunning)
        XCTAssertEqual(snapshot.diskUsage.resources.first?.sizeBytes, 42)
        XCTAssertLessThanOrEqual(logs.split(separator: "\n").count, 2_000)
        XCTAssertLessThanOrEqual(logs.utf8.count, CLISystemService.maximumLogBytes)
        XCTAssertFalse(logs.contains("not-safe"))
        XCTAssertTrue(logs.contains("<redacted>"))

        let commands = await cli.commands
        XCTAssertTrue(commands.contains(.systemVersion))
        XCTAssertTrue(commands.contains(.systemStatus))
        XCTAssertTrue(commands.contains(.systemDiskUsage))
        let period = try SystemLogPeriod(value: 15, unit: .minutes)
        XCTAssertTrue(commands.contains(.systemLogs(follow: false, last: period)))
    }

    func testReclaimComposesImageAndVolumePrune() async throws {
        let cli = SystemCLIStub(version: "[]", status: "{}", diskUsage: "[]", logs: "")
        let service = CLISystemService(cli: cli)

        try await service.reclaimUnusedResources()

        let commands = await cli.commands
        XCTAssertEqual(commands, [.pruneImages(all: true), .pruneVolumes])
    }

    func testSanitizerRedactsJSONBearerURLAndPrivateKeyValues() {
        let value = """
        {"access_token":"json-secret"}
        AUTH_TOKEN=assignment-secret
        Authorization: Bearer bearer-secret
        https://user:password@example.com/v2
        -----BEGIN PRIVATE KEY-----
        secret material
        -----END PRIVATE KEY-----
        """
        let sanitized = DiagnosticSanitizer.sanitize(value)

        for secret in [
            "json-secret",
            "assignment-secret",
            "bearer-secret",
            "user:password",
            "secret material",
        ] {
            XCTAssertFalse(sanitized.contains(secret))
        }
    }
}

@MainActor
final class SystemModelTests: XCTestCase {
    func testRefreshPublishesHealthDiskUsageAndLogs() async {
        let service = SystemServiceStub()
        let model = SystemModel(
            context: makeSystemContext(),
            service: service,
            failureLog: OperationFailureLog(),
            diagnosticsCopier: DiagnosticsCopierSpy()
        )

        await model.refresh()

        XCTAssertEqual(model.snapshotState, .loaded)
        XCTAssertEqual(model.logsState, .loaded)
        XCTAssertEqual(model.diskUsage?.resources.first?.type, "images")
        XCTAssertEqual(model.logs, "recent service message")
        XCTAssertEqual(model.properties?.value(section: "machine", key: "memory"), "9gb")
    }

    func testDiagnosticsCarryTheServiceConfiguration() async {
        let model = SystemModel(
            context: makeSystemContext(),
            service: SystemServiceStub(),
            failureLog: OperationFailureLog(),
            diagnosticsCopier: DiagnosticsCopierSpy()
        )

        await model.refresh()

        XCTAssertTrue(model.diagnosticsText.contains("machine.memory = 9gb"))
        XCTAssertTrue(model.diagnosticsText.contains("machine.cpus = 5"))
    }

    func testStopIsRecordedByServiceAndUpdatesHealth() async {
        let service = SystemServiceStub()
        let model = SystemModel(
            context: makeSystemContext(),
            service: service,
            failureLog: OperationFailureLog(),
            diagnosticsCopier: DiagnosticsCopierSpy()
        )

        await model.perform(.stop)

        let stopCount = await service.stopCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(model.status.isRunning)
        XCTAssertNil(model.actionError)
    }

    func testRestartStopsThenStartsAndLeavesTheServiceRunning() async {
        let service = SystemServiceStub()
        let model = SystemModel(
            context: makeSystemContext(),
            service: service,
            failureLog: OperationFailureLog(),
            diagnosticsCopier: DiagnosticsCopierSpy()
        )

        await model.perform(.restart)

        let calls = await service.calls
        XCTAssertEqual(calls, ["stop", "start"])
        XCTAssertTrue(model.status.isRunning)
        XCTAssertNil(model.actionError)
        XCTAssertNil(model.serviceOperation)
    }

    func testRestartingAStoppedServiceOnlyStartsIt() async {
        let service = SystemServiceStub(running: false)
        let model = SystemModel(
            context: makeSystemContext(isRunning: false),
            service: service,
            failureLog: OperationFailureLog(),
            diagnosticsCopier: DiagnosticsCopierSpy()
        )

        await model.perform(.restart)

        let calls = await service.calls
        XCTAssertEqual(calls, ["start"])
        XCTAssertTrue(model.status.isRunning)
    }

    func testDiagnosticsRedactFailureAndIncludeExitCodeWithoutEnvironment() {
        let failureLog = OperationFailureLog()
        failureLog.record(
            operation: "Pull image",
            error: CLIError.nonZeroExit(
                invocation: "container image pull example",
                exitCode: 17,
                standardError: "MY_SECRET_PASSWORD=do-not-copy"
            )
        )
        let copier = DiagnosticsCopierSpy()
        let model = SystemModel(
            context: makeSystemContext(),
            service: SystemServiceStub(),
            failureLog: failureLog,
            diagnosticsCopier: copier
        )

        let diagnostics = model.diagnosticsText
        XCTAssertTrue(diagnostics.contains("CLI version: 1.0.0"))
        XCTAssertTrue(diagnostics.contains("Server version: 1.0.1"))
        XCTAssertTrue(diagnostics.contains("Exit code: 17"))
        XCTAssertFalse(diagnostics.contains("do-not-copy"))
        XCTAssertFalse(diagnostics.contains("PATH="))
        XCTAssertFalse(diagnostics.contains("HOME="))

        model.copyDiagnostics()
        XCTAssertEqual(copier.value, diagnostics)
        XCTAssertTrue(model.didCopyDiagnostics)
    }
}

/// The `container system property list --format json` payload as CLI 1.3.0
/// emits it, with one extra section shaped the way a later release might add
/// one.
private let systemPropertiesFixture = """
{"build":{"cpus":2,"image":"ghcr.io/apple/container-builder-shim/builder:0.13.1","memory":"2048mb","rosetta":true},
 "container":{"cpus":4,"memory":"1gb"},
 "dns":{"domain":"cont"},
 "kernel":{"binaryPath":"opt/kata/share/kata-containers/vmlinux","digest":"sha256:8736c054"},
 "machine":{"cpus":5,"homeMount":"rw","memory":"9gb","virtualization":false},
 "network":{},
 "registry":{"domain":"docker.io"},
 "vminit":{"image":"ghcr.io/apple/containerization/vminit:0.41.0"},
 "future":{"nested":{"key":"value"},"list":["one","two"]}}
"""

private actor SystemCLIStub: ContainerCLI {
    let version: String
    let status: String
    let diskUsage: String
    let logs: String
    let properties: String
    private(set) var commands: [ContainerCommand] = []

    init(
        version: String,
        status: String,
        diskUsage: String,
        logs: String,
        properties: String = "{}"
    ) {
        self.version = version
        self.status = status
        self.diskUsage = diskUsage
        self.logs = logs
        self.properties = properties
    }

    func run(_ command: ContainerCommand) async throws -> CommandResult {
        commands.append(command)
        let output: String
        switch command {
        case .systemVersion:
            output = version
        case .systemStatus:
            output = status
        case .systemDiskUsage:
            output = diskUsage
        case .systemProperties:
            output = properties
        case .systemLogs:
            output = logs
        default:
            output = ""
        }
        return CommandResult(
            standardOutput: output,
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: "container"
        )
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor SystemServiceStub: SystemManaging {
    private(set) var stopCount = 0
    private(set) var startCount = 0
    /// Every start and stop in order, so a restart can be checked as a sequence
    /// rather than as two counts.
    private(set) var calls: [String] = []
    private var running = true

    init(running: Bool = true) { self.running = running }

    func loadSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            versions: SystemVersion(components: [
                SystemVersionDTO(
                    appName: "container",
                    version: "1.0.0",
                    buildType: nil,
                    commit: nil
                ),
                SystemVersionDTO(
                    appName: "container-apiserver",
                    version: "1.0.1",
                    buildType: nil,
                    commit: nil
                ),
            ]),
            status: SystemStatus(dto: SystemStatusDTO(
                status: running ? "ready" : "stopped",
                healthy: running,
                version: "1.0.1",
                message: nil
            )),
            diskUsage: SystemDiskUsage(resources: [
                SystemDiskUsageDTO(
                    type: "images",
                    totalCount: 2,
                    activeCount: 1,
                    sizeBytes: 42,
                    reclaimableBytes: 12
                ),
            ]),
            properties: SystemProperties(sections: [
                SystemProperties.Section(
                    name: "machine",
                    values: ["cpus": "5", "memory": "9gb"]
                ),
            ])
        )
    }

    func loadRecentLogs() -> String {
        "recent service message"
    }

    func startService() {
        startCount += 1
        calls.append("start")
        running = true
    }

    func stopService() {
        stopCount += 1
        calls.append("stop")
        running = false
    }
}

@MainActor
private final class DiagnosticsCopierSpy: DiagnosticsCopying {
    var value: String?

    func copy(_ value: String) {
        self.value = value
    }
}

private func makeSystemContext(isRunning: Bool = true) -> PreflightContext {
    PreflightContext(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/container"),
        versions: SystemVersion(components: [
            SystemVersionDTO(
                appName: "container",
                version: "1.0.0",
                buildType: nil,
                commit: nil
            ),
            SystemVersionDTO(
                appName: "container-apiserver",
                version: "1.0.1",
                buildType: nil,
                commit: nil
            ),
        ]),
        status: SystemStatus(dto: SystemStatusDTO(
            status: isRunning ? "ready" : "stopped",
            healthy: isRunning,
            version: "1.0.1",
            message: nil
        ))
    )
}
