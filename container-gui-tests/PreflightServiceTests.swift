import Foundation
import XCTest
@testable import Container_GUI

final class PreflightServiceTests: XCTestCase {
    private let executableURL = URL(fileURLWithPath: "/test/container")

    func testRejectsIntelMacBeforeLookingForCLI() async {
        let service = makeService(
            architecture: "x86_64",
            executableURLs: [executableURL]
        )

        let state = await service.check()

        XCTAssertEqual(
            state,
            .unsupportedPlatform(.requiresAppleSilicon(detectedArchitecture: "x86_64"))
        )
    }

    func testRejectsUnsupportedMacOS() async {
        let service = makeService(
            osMajorVersion: 25,
            executableURLs: [executableURL]
        )

        let state = await service.check()

        XCTAssertEqual(
            state,
            .unsupportedPlatform(.requiresMacOS(
                minimumMajorVersion: 26,
                detected: PlatformVersion(major: 25, minor: 6, patch: 0)
            ))
        )
    }

    func testReportsMissingCLI() async {
        let service = makeService(executableURLs: [])
        let state = await service.check()

        XCTAssertEqual(
            state,
            .missingCLI(customExecutableURL: nil)
        )
    }

    func testUsesCustomExecutableBeforeStandardLocationsAndReportsReady() async {
        let customURL = URL(fileURLWithPath: "/custom/container")
        let bookmarkStore = MemoryBookmarkStore(url: customURL)
        let service = makeService(
            executableURLs: [customURL, executableURL],
            bookmarkStore: bookmarkStore
        )

        let state = await service.check()

        guard case .ready(let context) = state else {
            return XCTFail("Expected ready, got \(state)")
        }
        XCTAssertEqual(context.executableURL, customURL)
        XCTAssertEqual(context.versions.cli?.version, "1.0.0")
        XCTAssertEqual(context.versions.server?.appName, "container-apiserver")
        XCTAssertTrue(context.status.isRunning)
        let storedState = await service.readiness
        XCTAssertEqual(storedState, state)
    }

    func testReportsUnsupportedCLIVersionWithDetectedVersions() async {
        let service = makeService(
            executableURLs: [executableURL],
            versionJSON: versionJSON(cliVersion: "2.0.0")
        )

        let state = await service.check()

        guard case .unsupportedVersion(
            let detected,
            let supported,
            let url,
            let versions
        ) = state else {
            return XCTFail("Expected unsupported version, got \(state)")
        }
        XCTAssertEqual(detected, "2.0.0")
        XCTAssertEqual(supported, .current)
        XCTAssertEqual(url, executableURL)
        XCTAssertEqual(versions.server?.version, "1.0.0")
    }

    func testReportsStoppedService() async {
        let service = makeService(
            executableURLs: [executableURL],
            statusJSON: #"{"status":"stopped","healthy":false,"message":"not running"}"#
        )

        let state = await service.check()

        guard case .serviceStopped(let context) = state else {
            return XCTFail("Expected stopped service, got \(state)")
        }
        XCTAssertFalse(context.status.isRunning)
        XCTAssertEqual(context.status.message, "not running")
    }

    func testReportsMalformedVersionJSON() async {
        let service = makeService(
            executableURLs: [executableURL],
            versionJSON: #"{"not":"an array"}"#
        )

        let state = await service.check()

        guard case .failure(let url, let diagnostic) = state else {
            return XCTFail("Expected failure, got \(state)")
        }
        XCTAssertEqual(url, executableURL)
        XCTAssertTrue(diagnostic.summary.contains("Malformed JSON"))
    }

    func testReportsMalformedStatusJSON() async {
        let service = makeService(
            executableURLs: [executableURL],
            statusJSON: #"[invalid"#
        )

        let state = await service.check()

        guard case .failure(_, let diagnostic) = state else {
            return XCTFail("Expected failure, got \(state)")
        }
        XCTAssertTrue(diagnostic.summary.contains("system status"))
    }

    func testReportsStatusJSONWithoutStatusAsFailure() async {
        let service = makeService(
            executableURLs: [executableURL],
            statusJSON: #"{"future":"value"}"#
        )

        let state = await service.check()

        guard case .failure(_, let diagnostic) = state else {
            return XCTFail("Expected failure, got \(state)")
        }
        XCTAssertTrue(diagnostic.summary.contains("contained no status"))
    }

    func testPreservesExitCodeStderrAndInvocationInFailure() async {
        let error = CLIError.nonZeroExit(
            invocation: "/test/container system version --format json",
            exitCode: 42,
            standardError: "service unavailable\n"
        )
        let service = makeService(
            executableURLs: [executableURL],
            versionResult: .failure(error)
        )

        let state = await service.check()

        guard case .failure(_, let diagnostic) = state else {
            return XCTFail("Expected failure, got \(state)")
        }
        XCTAssertEqual(diagnostic.exitCode, 42)
        XCTAssertEqual(diagnostic.standardError, "service unavailable\n")
        XCTAssertEqual(diagnostic.invocation, "/test/container system version --format json")
    }

    func testBinaryThatDisappearsAfterSelectionIsReportedMissing() async {
        let bookmarkStore = MemoryBookmarkStore(url: executableURL)
        let service = makeService(
            executableURLs: [],
            bookmarkStore: bookmarkStore
        )
        let state = await service.check()

        XCTAssertEqual(
            state,
            .missingCLI(customExecutableURL: executableURL)
        )
    }

    func testSelectAndResetCustomExecutableActions() async {
        let customURL = URL(fileURLWithPath: "/custom/container")
        let bookmarkStore = MemoryBookmarkStore()
        let service = makeService(
            executableURLs: [customURL],
            bookmarkStore: bookmarkStore,
            standardExecutableURLs: []
        )

        guard case .ready(let context) = await service.selectCustomExecutable(customURL) else {
            return XCTFail("Expected selected executable to become ready")
        }
        XCTAssertEqual(context.executableURL, customURL)
        let savedURL = await bookmarkStore.load()
        XCTAssertEqual(savedURL, customURL)

        let resetState = await service.resetCustomExecutable()
        XCTAssertEqual(
            resetState,
            .missingCLI(customExecutableURL: nil)
        )
        let resetURL = await bookmarkStore.load()
        XCTAssertNil(resetURL)
    }

    func testRetryRunsPreflightAgain() async {
        let service = makeService(executableURLs: [executableURL])

        let firstState = await service.check()
        let retriedState = await service.retry()

        XCTAssertEqual(firstState, retriedState)
    }

    func testSemanticVersionsSupportPrereleaseSuffixAndBounds() throws {
        XCTAssertEqual(try SemanticVersion("1.2.3-beta.1"), SemanticVersion(
            major: 1,
            minor: 2,
            patch: 3
        ))
        XCTAssertTrue(SupportedCLIVersions.current.contains(try SemanticVersion("0.12.0")))
        XCTAssertFalse(SupportedCLIVersions.current.contains(try SemanticVersion("2.0.0")))
        XCTAssertThrowsError(try SemanticVersion("not-a-version"))
    }

    private func makeService(
        architecture: String = "arm64",
        osMajorVersion: Int = 26,
        executableURLs: Set<URL>,
        bookmarkStore: MemoryBookmarkStore = MemoryBookmarkStore(),
        standardExecutableURLs: [URL]? = nil,
        versionJSON: String? = nil,
        statusJSON: String = #"{"status":"ready","healthy":true,"version":"1.0.0"}"#,
        versionResult: Result<CommandResult, CLIError>? = nil
    ) -> PreflightService {
        let versionResult = versionResult ?? .success(result(
            versionJSON ?? self.versionJSON(cliVersion: "1.0.0")
        ))
        let cli = StubContainerCLI(
            versionResult: versionResult,
            statusResult: .success(result(statusJSON))
        )
        return PreflightService(
            platform: PlatformSnapshot(
                architecture: architecture,
                operatingSystemVersion: PlatformVersion(
                    major: osMajorVersion,
                    minor: 6,
                    patch: 0
                )
            ),
            standardExecutableURLs: standardExecutableURLs ?? [executableURL],
            bookmarkStore: bookmarkStore,
            fileChecker: StubExecutableFileChecker(executableURLs: executableURLs),
            cliFactory: StubContainerCLIFactory(cli: cli)
        )
    }

    private func versionJSON(cliVersion: String) -> String {
        """
        [
          {"appName":"container","version":"\(cliVersion)"},
          {"appName":"container-apiserver","version":"1.0.0"}
        ]
        """
    }

    private func result(_ output: String) -> CommandResult {
        CommandResult(
            standardOutput: output,
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: "/test/container"
        )
    }
}

nonisolated private final class MemoryBookmarkStore: ExecutableBookmarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    init(url: URL? = nil) {
        self.url = url
    }

    func load() async -> URL? {
        lock.withLock { url }
    }

    func save(_ url: URL) async {
        lock.withLock {
            self.url = url
        }
    }

    func reset() async {
        lock.withLock {
            url = nil
        }
    }
}

nonisolated private struct StubExecutableFileChecker: ExecutableFileChecking {
    let executableURLs: Set<URL>

    func isExecutableFile(at url: URL) -> Bool {
        executableURLs.contains(url)
    }
}

nonisolated private struct StubContainerCLIFactory: ContainerCLIMaking {
    let cli: StubContainerCLI

    func makeCLI(executableURL: URL) -> any ContainerCLI {
        cli
    }
}

nonisolated private struct StubContainerCLI: ContainerCLI {
    let versionResult: Result<CommandResult, CLIError>
    let statusResult: Result<CommandResult, CLIError>

    func run(_ command: ContainerCommand) async throws -> CommandResult {
        switch command {
        case .systemVersion:
            try versionResult.get()
        case .systemStatus:
            try statusResult.get()
        default:
            throw CLIError.invalidOutput(description: "Unexpected command in preflight test.")
        }
    }

    func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
