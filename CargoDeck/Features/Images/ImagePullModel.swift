import Foundation
import Observation

/// The pull sheet's form. It builds a configuration and hands it to the shared
/// operation activity; the progress and cancellation live there, so navigating
/// away from Images mid-pull no longer orphans the child process.
@MainActor
@Observable
final class ImagePullModel: Identifiable {
    let id = UUID()
    var reference = ""
    var scheme: RegistryScheme = .auto
    var platform = ""
    var operatingSystem = ""
    var architecture = ""
    /// Empty leaves the CLI's own default in place. Only offered when the CLI
    /// is new enough to have the flag at all.
    var maximumConcurrentDownloads = ""

    let capabilities: ImageCapabilities

    init(capabilities: ImageCapabilities = ImageCapabilities(supportsConcurrentDownloadLimit: true)) {
        self.capabilities = capabilities
    }

    var referenceError: String? {
        validationMessage { _ = try ImageReference(validating: trimmedReference) }
    }

    var platformError: String? {
        validationMessage { _ = try platformSelection() }
    }

    var concurrencyError: String? {
        validationMessage { _ = try concurrencyLimit() }
    }

    var configuration: ImagePullConfiguration? {
        try? makeConfiguration()
    }

    var canPull: Bool { configuration != nil }

    /// The number of options set, for the rail's badge.
    var optionCount: Int {
        var count = scheme == .auto ? 0 : 1
        count += (try? platformSelection())?.setValueCount ?? 0
        if (try? concurrencyLimit()) ?? nil != nil { count += 1 }
        return count
    }

    var commandPreview: String {
        guard let configuration else {
            return "container image pull"
        }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.pullImage(configuration: configuration).arguments
        )
    }

    func makeConfiguration() throws -> ImagePullConfiguration {
        try ImagePullConfiguration(
            reference: trimmedReference,
            scheme: scheme,
            platform: platformSelection(),
            maximumConcurrentDownloads: concurrencyLimit()
        )
    }

    private var trimmedReference: String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func platformSelection() throws -> ImagePlatformSelection {
        try ImagePlatformSelection(
            platform: platform,
            operatingSystem: operatingSystem,
            architecture: architecture
        )
    }

    /// Never emitted below 1.0.0, whatever the field holds — the flag does not
    /// exist there and passing it is a hard failure.
    private func concurrencyLimit() throws -> Int? {
        guard capabilities.supportsConcurrentDownloadLimit else { return nil }
        let trimmed = maximumConcurrentDownloads.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed) else {
            throw CommandValidationError.invalid(
                field: "Maximum concurrent downloads",
                value: trimmed
            )
        }
        guard value > 0 else {
            throw CommandValidationError.nonPositive(field: "Maximum concurrent downloads")
        }
        return value
    }

    private func validationMessage(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }
}
