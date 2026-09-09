import Foundation
import Observation

@MainActor
@Observable
final class ImagePushModel: Identifiable {
    let id = UUID()
    var reference: String
    var scheme: RegistryScheme = .auto
    var platform = ""
    var operatingSystem = ""
    var architecture = ""

    init(reference: String) {
        self.reference = reference
    }

    var referenceError: String? {
        do {
            _ = try ImageReference(validating: trimmedReference)
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    var platformError: String? {
        do {
            _ = try platformSelection()
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    /// The host half of the reference, or `nil` when the reference names no
    /// registry — which is itself the thing worth telling the user about.
    var registryHost: String? {
        RegistryModel.registryHost(inReference: trimmedReference)
    }

    var configuration: ImagePushConfiguration? {
        try? ImagePushConfiguration(
            reference: trimmedReference,
            scheme: scheme,
            platform: platformSelection()
        )
    }

    var canPush: Bool { configuration != nil }

    var optionCount: Int {
        var count = scheme == .auto ? 0 : 1
        count += (try? platformSelection())?.setValueCount ?? 0
        return count
    }

    var commandPreview: String {
        guard let configuration else { return "container image push" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.pushImage(configuration: configuration).arguments
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
}
