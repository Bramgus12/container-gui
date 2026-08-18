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

private actor SystemCLIStub: ContainerCLI {
    let version: String
    let status: String
    let diskUsage: String
    let logs: String
    private(set) var commands: [ContainerCommand] = []

    init(version: String, status: String, diskUsage: String, logs: String) {
        self.version = version
        self.status = status
        self.diskUsage = diskUsage
        self.logs = logs
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
    private var running = true

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
            ])
        )
    }

    func loadRecentLogs() -> String {
        "recent service message"
    }

    func startService() {
        running = true
    }

    func stopService() {
        stopCount += 1
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

private func makeSystemContext() -> PreflightContext {
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
            status: "ready",
            healthy: true,
            version: "1.0.1",
            message: nil
        ))
    )
}
