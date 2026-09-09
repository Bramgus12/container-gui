import Foundation
import XCTest
@testable import CargoDeck

/// Exact argument generation for the image and registry commands.
///
/// The expectations here were checked against `--help` on CLI 1.3.1 and against
/// Apple's published command reference for 0.12.0 and 1.0.0 — see
/// `docs/CLI_IMAGE_REGISTRY_BASELINE.md`.
final class ImageOperationModelTests: XCTestCase {

    // MARK: - Scheme

    /// The scheme vocabulary is not stable across supported releases: 0.12.0 and
    /// 1.0.0 accept `auto` and default to it, while 1.3.1 accepts only `http`
    /// and `https`. Automatic therefore emits nothing at all, which is valid
    /// everywhere; an explicit choice emits only values every release accepts.
    func testAutomaticSchemeEmitsNoFlag() {
        XCTAssertEqual(RegistryScheme.auto.arguments, [])
        XCTAssertEqual(RegistryScheme.https.arguments, ["--scheme", "https"])
        XCTAssertEqual(RegistryScheme.http.arguments, ["--scheme", "http"])
        XCTAssertFalse(
            RegistryScheme.allCases.flatMap(\.arguments).contains("auto"),
            "`--scheme auto` is rejected by current releases and must never be emitted."
        )
    }

    // MARK: - Platform precedence

    func testPlatformSuppressesOSAndArchitecture() throws {
        let selection = try ImagePlatformSelection(
            platform: "linux/arm64/v8",
            operatingSystem: "linux",
            architecture: "arm64"
        )

        XCTAssertEqual(selection.arguments, ["--platform", "linux/arm64/v8"])
    }

    func testOSAndArchitectureAreEmittedOnlyWithoutAPlatform() throws {
        let selection = try ImagePlatformSelection(
            operatingSystem: "linux",
            architecture: "arm64"
        )

        XCTAssertEqual(selection.arguments, ["--os", "linux", "--arch", "arm64"])
    }

    func testBlankPlatformFieldsAreTreatedAsUnset() throws {
        let selection = try ImagePlatformSelection(
            platform: "   ",
            operatingSystem: "",
            architecture: "\n"
        )

        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.arguments, [])
    }

    func testInvalidPlatformReportsAnImageFieldRatherThanABuildField() {
        do {
            _ = try ImagePlatformSelection(platform: "linux")
            XCTFail("Expected a validation error")
        } catch let error as CommandValidationError {
            guard case .invalid(let field, _) = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
            XCTAssertEqual(field, "Image platform")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Pull

    func testPullPutsOptionsBeforeTheReference() throws {
        let configuration = try ImagePullConfiguration(
            reference: "ghcr.io/example/app:1.0",
            scheme: .http,
            platform: try ImagePlatformSelection(platform: "linux/arm64"),
            maximumConcurrentDownloads: 6
        )

        XCTAssertEqual(configuration.arguments, [
            "image", "pull",
            "--scheme", "http",
            "--progress", "plain",
            "--max-concurrent-downloads", "6",
            "--platform", "linux/arm64",
            "ghcr.io/example/app:1.0",
        ])
    }

    func testPullOmitsConcurrencyWhenUnset() throws {
        let configuration = try ImagePullConfiguration(reference: "alpine:3.21")

        XCTAssertEqual(
            configuration.arguments,
            ["image", "pull", "--progress", "plain", "alpine:3.21"]
        )
    }

    func testPullRejectsNonPositiveConcurrency() {
        XCTAssertThrowsError(
            try ImagePullConfiguration(reference: "alpine:3.21", maximumConcurrentDownloads: 0)
        )
        XCTAssertThrowsError(
            try ImagePullConfiguration(reference: "alpine:3.21", maximumConcurrentDownloads: -1)
        )
    }

    func testPullRejectsALeadingOptionAsAReference() {
        XCTAssertThrowsError(try ImagePullConfiguration(reference: "--all"))
    }

    // MARK: - Capability gating

    /// `--max-concurrent-downloads` arrived in 1.0.0 and is absent from the
    /// 0.12 pull surface, where passing it is a hard failure.
    func testConcurrencyCapabilityBoundaryIsOnePointZero() {
        XCTAssertFalse(
            ImageCapabilities(version: SemanticVersion(major: 0, minor: 12, patch: 3))
                .supportsConcurrentDownloadLimit
        )
        XCTAssertFalse(
            ImageCapabilities(version: SemanticVersion(major: 0, minor: 99, patch: 9))
                .supportsConcurrentDownloadLimit
        )
        XCTAssertTrue(
            ImageCapabilities(version: SemanticVersion(major: 1, minor: 0, patch: 0))
                .supportsConcurrentDownloadLimit
        )
        XCTAssertTrue(
            ImageCapabilities(version: SemanticVersion(major: 1, minor: 3, patch: 1))
                .supportsConcurrentDownloadLimit
        )
    }

    @MainActor
    func testPullModelNeverEmitsConcurrencyOnAnOlderCLI() throws {
        let model = ImagePullModel(
            capabilities: ImageCapabilities(supportsConcurrentDownloadLimit: false)
        )
        model.reference = "alpine:3.21"
        model.maximumConcurrentDownloads = "8"

        let configuration = try model.makeConfiguration()

        XCTAssertNil(configuration.maximumConcurrentDownloads)
        XCTAssertFalse(configuration.arguments.contains("--max-concurrent-downloads"))
        XCTAssertFalse(model.commandPreview.contains("--max-concurrent-downloads"))
    }

    @MainActor
    func testPullModelEmitsConcurrencyOnASupportedCLI() throws {
        let model = ImagePullModel(
            capabilities: ImageCapabilities(supportsConcurrentDownloadLimit: true)
        )
        model.reference = "alpine:3.21"
        model.maximumConcurrentDownloads = "8"

        let configuration = try model.makeConfiguration()

        XCTAssertEqual(configuration.maximumConcurrentDownloads, 8)
        XCTAssertTrue(model.commandPreview.contains("--max-concurrent-downloads 8"))
    }

    // MARK: - Push, tag

    func testPushForcesPlainProgressAndKeepsTheReferenceLast() throws {
        let configuration = try ImagePushConfiguration(
            reference: "ghcr.io/example/app:1.0",
            scheme: .https,
            platform: try ImagePlatformSelection(operatingSystem: "linux")
        )

        XCTAssertEqual(configuration.arguments, [
            "image", "push",
            "--scheme", "https",
            "--progress", "plain",
            "--os", "linux",
            "ghcr.io/example/app:1.0",
        ])
    }

    func testTagRequiresADistinctTarget() {
        XCTAssertThrowsError(
            try ImageTagConfiguration(source: "alpine:3.21", target: "alpine:3.21")
        )
    }

    func testTagArgumentsAreSourceThenTarget() throws {
        let configuration = try ImageTagConfiguration(
            source: "alpine:3.21",
            target: "ghcr.io/example/alpine:3.21"
        )

        XCTAssertEqual(
            configuration.arguments,
            ["image", "tag", "alpine:3.21", "ghcr.io/example/alpine:3.21"]
        )
    }

    // MARK: - Save and load

    func testSaveDeduplicatesReferencesAndKeepsOrder() throws {
        let configuration = try ImageSaveConfiguration(
            references: ["alpine:3.21", "busybox:1", "alpine:3.21"],
            output: "/tmp/images.tar"
        )

        XCTAssertEqual(configuration.references.map(\.rawValue), ["alpine:3.21", "busybox:1"])
        XCTAssertEqual(configuration.arguments, [
            "image", "save",
            "--output", "/tmp/images.tar",
            "alpine:3.21", "busybox:1",
        ])
    }

    func testSaveRequiresAtLeastOneImage() {
        XCTAssertThrowsError(
            try ImageSaveConfiguration(references: [], output: "/tmp/images.tar")
        )
    }

    func testSaveRequiresAnAbsolutePath() {
        XCTAssertThrowsError(
            try ImageSaveConfiguration(references: ["alpine:3.21"], output: "images.tar")
        )
    }

    /// A path with spaces stays one argument. `displayInvocation` quotes it, and
    /// the process is launched from the argument array rather than a shell.
    func testSavePathWithSpacesRemainsASingleArgument() throws {
        let configuration = try ImageSaveConfiguration(
            references: ["alpine:3.21"],
            output: "/Users/me/My Images/all images.tar"
        )

        XCTAssertEqual(
            configuration.arguments,
            ["image", "save", "--output", "/Users/me/My Images/all images.tar", "alpine:3.21"]
        )
        let preview = ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: configuration.arguments
        )
        XCTAssertTrue(preview.contains("'/Users/me/My Images/all images.tar'"), preview)
    }

    func testLoadEmitsForceOnlyWhenRequested() throws {
        XCTAssertEqual(
            try ImageLoadConfiguration(input: "/tmp/images.tar").arguments,
            ["image", "load", "--input", "/tmp/images.tar"]
        )
        XCTAssertEqual(
            try ImageLoadConfiguration(input: "/tmp/images.tar", force: true).arguments,
            ["image", "load", "--input", "/tmp/images.tar", "--force"]
        )
    }

    // MARK: - Delete

    func testDeleteRejectsBothAllAndNamedImages() {
        XCTAssertThrowsError(
            try ImageDeleteConfiguration(references: ["alpine:3.21"], all: true)
        )
    }

    func testDeleteRejectsNeitherAllNorNamedImages() {
        XCTAssertThrowsError(try ImageDeleteConfiguration())
    }

    func testDeleteDeduplicatesNamedImages() throws {
        let configuration = try ImageDeleteConfiguration(
            references: ["alpine:3.21", "alpine:3.21", "busybox:1"]
        )

        XCTAssertEqual(
            configuration.arguments,
            ["image", "delete", "alpine:3.21", "busybox:1"]
        )
    }

    func testDeleteAllEmitsTheFlagAndNoReferences() throws {
        XCTAssertEqual(
            try ImageDeleteConfiguration(all: true).arguments,
            ["image", "delete", "--all"]
        )
        XCTAssertEqual(
            try ImageDeleteConfiguration(all: true, force: true).arguments,
            ["image", "delete", "--all", "--force"]
        )
    }

    func testPruneScopes() {
        XCTAssertEqual(
            ContainerCommand.pruneImages(all: false).arguments,
            ["image", "prune"]
        )
        XCTAssertEqual(
            ContainerCommand.pruneImages(all: true).arguments,
            ["image", "prune", "--all"]
        )
    }
}
