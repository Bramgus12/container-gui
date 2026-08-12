import Foundation
import XCTest
@testable import Container_GUI

private actor StubUpdateService: UpdateChecking {
    private var result: Result<AppRelease, Error>
    private(set) var callCount = 0

    init(result: Result<AppRelease, Error>) {
        self.result = result
    }

    func setResult(_ value: Result<AppRelease, Error>) {
        result = value
    }

    func latestRelease() throws -> AppRelease {
        callCount += 1
        return try result.get()
    }
}

private actor MemoryPreferences: UpdatePreferencesStoring {
    private var automatic: Bool
    private var lastCheck: Date?
    private var skipped: SemanticVersion?

    init(
        automatic: Bool = true,
        lastCheck: Date? = nil,
        skipped: SemanticVersion? = nil
    ) {
        self.automatic = automatic
        self.lastCheck = lastCheck
        self.skipped = skipped
    }

    func automaticChecksEnabled() -> Bool { automatic }
    func setAutomaticChecksEnabled(_ enabled: Bool) { automatic = enabled }
    func lastCheckDate() -> Date? { lastCheck }
    func setLastCheckDate(_ date: Date) { lastCheck = date }
    func skippedVersion() -> SemanticVersion? { skipped }
    func setSkippedVersion(_ version: SemanticVersion?) { skipped = version }
}

@MainActor
private final class RecordingCopier: DiagnosticsCopying {
    private(set) var copied: [String] = []

    func copy(_ value: String) {
        copied.append(value)
    }
}

private func makeRelease(
    tag: String,
    name: String = "Container GUI",
    notes: String = "",
    page: String = "https://github.com/Bramgus12/container-gui/releases/tag/v9.9.9"
) throws -> AppRelease {
    try AppRelease(dto: GitHubReleaseDTO(
        tagName: tag,
        name: name,
        body: notes,
        htmlURL: page,
        publishedAt: "2026-08-12T07:04:30Z"
    ))
}

@MainActor
private func makeModel(
    service: StubUpdateService,
    preferences: MemoryPreferences = MemoryPreferences(),
    copier: RecordingCopier? = nil,
    installed: String = "1.1.0",
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
) throws -> UpdateModel {
    UpdateModel(
        service: service,
        preferences: preferences,
        installCommandCopier: copier ?? RecordingCopier(),
        installedVersion: try SemanticVersion(installed),
        now: now
    )
}

final class AppReleaseDecodingTests: XCTestCase {
    func testDecodesTagWithAndWithoutVPrefix() throws {
        XCTAssertEqual(try makeRelease(tag: "v1.2.3").version, SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(try makeRelease(tag: "1.2.3").version, SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(try makeRelease(tag: "V2.0").version, SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(try makeRelease(tag: " v1.1.0 ").tag, "v1.1.0")
    }

    func testRejectsUnusableTags() {
        for tag in ["", "latest", "v", "nightly-build"] {
            XCTAssertThrowsError(try makeRelease(tag: tag)) { error in
                guard case UpdateCheckError.invalidRelease = error else {
                    return XCTFail("Expected invalidRelease for \(tag), got \(error)")
                }
            }
        }
    }

    func testFallsBackWhenFieldsAreMissing() throws {
        let release = try AppRelease(dto: GitHubReleaseDTO(
            tagName: "v1.4.0",
            name: nil,
            body: nil,
            htmlURL: nil,
            publishedAt: nil
        ))
        XCTAssertEqual(release.name, "v1.4.0")
        XCTAssertEqual(release.notes, "")
        XCTAssertEqual(release.pageURL, AppDistribution.releasesURL)
        XCTAssertNil(release.publishedAt)
    }

    /// Decodes a captured response from the real
    /// `/repos/Bramgus12/container-gui/releases/latest` endpoint, so a change in
    /// GitHub's payload shape fails here rather than in front of a user.
    func testDecodesCapturedGitHubReleasePayload() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/github/release-latest.json")
        let dto = try JSONDecoder().decode(
            GitHubReleaseDTO.self,
            from: Data(contentsOf: file)
        )
        let release = try AppRelease(dto: dto)

        XCTAssertEqual(release.tag, "v1.1.0")
        XCTAssertEqual(release.version, SemanticVersion(major: 1, minor: 1, patch: 0))
        XCTAssertEqual(release.name, "Container GUI 1.1.0")
        XCTAssertEqual(
            release.pageURL.absoluteString,
            "https://github.com/Bramgus12/container-gui/releases/tag/v1.1.0"
        )
        XCTAssertNotNil(release.publishedAt)
        XCTAssertTrue(release.notes.contains("network management"))
    }

    func testIgnoresUnknownFields() throws {
        let dto = try JSONDecoder().decode(GitHubReleaseDTO.self, from: Data("""
        {
          "tag_name": "v9.9.9",
          "name": "Future",
          "body": "Notes",
          "html_url": "https://example.com/r",
          "published_at": "2026-08-12T07:04:30Z",
          "future_field": {"nested": [1, 2, 3]}
        }
        """.utf8))
        XCTAssertEqual(try AppRelease(dto: dto).version, SemanticVersion(major: 9, minor: 9, patch: 9))
    }

    func testBoundsOversizedReleaseNotes() throws {
        let body = String(repeating: "a", count: AppRelease.maximumNotesLength + 500)
        let release = try makeRelease(tag: "v1.2.0", notes: body)
        XCTAssertEqual(release.notes.count, AppRelease.maximumNotesLength + 2)
        XCTAssertTrue(release.notes.hasSuffix("\n…"))
    }
}

@MainActor
final class UpdateModelTests: XCTestCase {
    func testReportsAvailableOnlyForNewerVersions() async throws {
        for (tag, expectsUpdate) in [("v1.2.0", true), ("v1.1.0", false), ("v1.0.0", false)] {
            let service = StubUpdateService(result: .success(try makeRelease(tag: tag)))
            let model = try makeModel(service: service)
            await model.checkNow()

            if expectsUpdate {
                XCTAssertEqual(model.state.release?.tag, tag)
                XCTAssertNotNil(model.availableRelease)
            } else {
                XCTAssertNil(model.state.release, "\(tag) should not offer an update")
                if case .upToDate = model.state {} else {
                    XCTFail("Expected upToDate for \(tag), got \(model.state)")
                }
            }
        }
    }

    func testAutomaticCheckIsThrottledToOnceADay() async throws {
        let service = StubUpdateService(result: .success(try makeRelease(tag: "v1.2.0")))
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let model = try makeModel(service: service, now: { launch })

        await model.checkIfNeeded()
        var count = await service.callCount
        XCTAssertEqual(count, 1)
        let firstCheck = model.lastCheckDate
        XCTAssertEqual(firstCheck, launch)

        // A second launch a minute later must not call GitHub again.
        let minuteLater = launch.addingTimeInterval(60)
        let laterModel = try makeModel(
            service: service,
            preferences: MemoryPreferences(lastCheck: firstCheck),
            now: { minuteLater }
        )
        await laterModel.checkIfNeeded()
        count = await service.callCount
        XCTAssertEqual(count, 1)

        // A day later it checks again.
        let dayLater = launch.addingTimeInterval(UpdateModel.checkInterval + 1)
        let nextDayModel = try makeModel(
            service: service,
            preferences: MemoryPreferences(lastCheck: firstCheck),
            now: { dayLater }
        )
        await nextDayModel.checkIfNeeded()
        count = await service.callCount
        XCTAssertEqual(count, 2)
    }

    func testAutomaticCheckRespectsThePreference() async throws {
        let service = StubUpdateService(result: .success(try makeRelease(tag: "v1.2.0")))
        let model = try makeModel(
            service: service,
            preferences: MemoryPreferences(automatic: false)
        )

        await model.checkIfNeeded()
        let count = await service.callCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.automaticChecksEnabled)

        // A manual check still works when automatic checks are off.
        await model.checkNow()
        let manualCount = await service.callCount
        XCTAssertEqual(manualCount, 1)
    }

    func testSkippedVersionHidesTheBannerButNotAManualCheck() async throws {
        let service = StubUpdateService(result: .success(try makeRelease(tag: "v1.2.0")))
        let model = try makeModel(service: service)

        await model.checkNow()
        XCTAssertNotNil(model.availableRelease)

        await model.skipCurrentVersion()
        XCTAssertNil(model.availableRelease, "A skipped version must not be surfaced")
        XCTAssertNotNil(model.state.release, "The manual result still knows the release")
        XCTAssertEqual(model.skippedVersion, SemanticVersion(major: 1, minor: 2, patch: 0))

        // A newer release than the skipped one surfaces again.
        await service.setResult(.success(try makeRelease(tag: "v1.3.0")))
        await model.checkNow()
        XCTAssertEqual(model.availableRelease?.tag, "v1.3.0")

        await model.clearSkippedVersion()
        XCTAssertNil(model.skippedVersion)
    }

    func testManualCheckPublishesResultForPresentation() async throws {
        let service = StubUpdateService(result: .success(try makeRelease(tag: "v1.2.0")))
        let model = try makeModel(service: service)

        await model.checkIfNeeded()
        XCTAssertNil(model.pendingManualResult, "Automatic checks must not open a sheet")

        await model.checkNow()
        XCTAssertEqual(model.pendingManualResult?.release?.tag, "v1.2.0")

        model.dismissManualResult()
        XCTAssertNil(model.pendingManualResult)
    }

    func testFailuresSurfaceSanitizedMessagesAndDoNotStampTheCheckDate() async throws {
        let cases: [(UpdateCheckError, String)] = [
            (.rateLimited, "rate-limiting"),
            (.notFound, "No published release"),
            (.unreachable(reason: "offline"), "could not reach GitHub"),
            (.invalidResponse(status: 500), "HTTP 500"),
        ]

        for (error, fragment) in cases {
            let service = StubUpdateService(result: .failure(error))
            let model = try makeModel(service: service)
            await model.checkNow()

            guard case .failed(let message) = model.state else {
                return XCTFail("Expected failure for \(error), got \(model.state)")
            }
            XCTAssertTrue(
                message.contains(fragment),
                "\(message) should describe \(fragment)"
            )
            XCTAssertNil(model.lastCheckDate, "A failed check must not count as a check")
        }
    }

    func testFailureMessagesAreSanitized() async throws {
        let service = StubUpdateService(result: .failure(
            UpdateCheckError.unreachable(reason: "token=super-secret-value")
        ))
        let model = try makeModel(service: service)
        await model.checkNow()

        guard case .failed(let message) = model.state else {
            return XCTFail("Expected a failure state, got \(model.state)")
        }
        XCTAssertFalse(message.contains("super-secret-value"))
        XCTAssertTrue(message.contains("<redacted>"))
    }

    func testCancellationLeavesTheModelIdle() async throws {
        let service = StubUpdateService(result: .failure(CancellationError()))
        let model = try makeModel(service: service)

        await model.checkNow()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.pendingManualResult)
    }

    func testCopiesTheDocumentedInstallCommand() async throws {
        let service = StubUpdateService(result: .success(try makeRelease(tag: "v1.2.0")))
        let copier = RecordingCopier()
        let model = try makeModel(service: service, copier: copier)

        await model.checkNow()
        XCTAssertFalse(model.didCopyInstallCommand)

        model.copyInstallCommand()
        XCTAssertTrue(model.didCopyInstallCommand)
        XCTAssertEqual(copier.copied, [AppDistribution.installCommand])
        XCTAssertTrue(copier.copied[0].hasPrefix("curl -fsSL https://raw.githubusercontent.com/"))
        XCTAssertTrue(copier.copied[0].hasSuffix("/scripts/install.sh | bash"))

        model.resetCopyConfirmation()
        XCTAssertFalse(model.didCopyInstallCommand)
    }

    func testAutomaticCheckPreferenceIsPersisted() async throws {
        let service = StubUpdateService(result: .success(try makeRelease(tag: "v1.2.0")))
        let preferences = MemoryPreferences()
        let model = try makeModel(service: service, preferences: preferences)

        await model.loadPreferences()
        XCTAssertTrue(model.automaticChecksEnabled)

        await model.setAutomaticChecks(false)
        let stored = await preferences.automaticChecksEnabled()
        XCTAssertFalse(stored)
    }
}

final class UpdatePreferencesStoreTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "update-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    func testRoundTripsThroughAFreshStore() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsUpdatePreferences(defaults: defaults)
        let checked = Date(timeIntervalSince1970: 1_800_000_000)

        // Defaults to on so that a fresh install checks for updates.
        var enabled = await store.automaticChecksEnabled()
        XCTAssertTrue(enabled)
        var skipped = await store.skippedVersion()
        XCTAssertNil(skipped)
        var last = await store.lastCheckDate()
        XCTAssertNil(last)

        await store.setAutomaticChecksEnabled(false)
        await store.setLastCheckDate(checked)
        await store.setSkippedVersion(SemanticVersion(major: 1, minor: 2, patch: 3))

        let reopened = UserDefaultsUpdatePreferences(defaults: defaults)
        enabled = await reopened.automaticChecksEnabled()
        last = await reopened.lastCheckDate()
        skipped = await reopened.skippedVersion()
        XCTAssertFalse(enabled)
        XCTAssertEqual(last, checked)
        XCTAssertEqual(skipped, SemanticVersion(major: 1, minor: 2, patch: 3))

        await reopened.setSkippedVersion(nil)
        skipped = await reopened.skippedVersion()
        XCTAssertNil(skipped)
    }

    func testIgnoresACorruptSkippedVersion() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("not-a-version", forKey: UserDefaultsUpdatePreferences.skippedVersionKey)
        let store = UserDefaultsUpdatePreferences(defaults: defaults)
        let skipped = await store.skippedVersion()
        XCTAssertNil(skipped)
    }
}

final class GitHubUpdateServiceTests: XCTestCase {
    private func makeService(
        status: Int,
        body: String
    ) -> GitHubUpdateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.stub = (status, Data(body.utf8))
        return GitHubUpdateService(
            url: AppDistribution.latestReleaseAPIURL,
            session: URLSession(configuration: configuration)
        )
    }

    override func tearDown() {
        StubURLProtocol.stub = nil
        super.tearDown()
    }

    func testDecodesASuccessfulResponse() async throws {
        let service = makeService(status: 200, body: """
        {"tag_name":"v2.0.0","name":"Container GUI 2.0.0","body":"Notes","html_url":"https://example.com/r"}
        """)
        let release = try await service.latestRelease()
        XCTAssertEqual(release.version, SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(release.name, "Container GUI 2.0.0")
    }

    func testMapsRateLimitingAndOtherStatuses() async throws {
        for (status, expected) in [
            (403, UpdateCheckError.rateLimited),
            (429, UpdateCheckError.rateLimited),
            (404, UpdateCheckError.notFound),
            (500, UpdateCheckError.invalidResponse(status: 500)),
        ] {
            let service = makeService(status: status, body: "{}")
            do {
                _ = try await service.latestRelease()
                XCTFail("Expected \(expected) for HTTP \(status)")
            } catch let error as UpdateCheckError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testMapsUndecodableBodies() async throws {
        let service = makeService(status: 200, body: "not json")
        do {
            _ = try await service.latestRelease()
            XCTFail("Expected a decoding failure")
        } catch let error as UpdateCheckError {
            guard case .invalidRelease = error else {
                return XCTFail("Expected invalidRelease, got \(error)")
            }
        }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stub: (status: Int, body: Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
