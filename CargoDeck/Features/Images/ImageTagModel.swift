import Foundation
import Observation

/// Tag is the one image mutation with no progress to show: a single metadata
/// write that either lands or reports why it did not.
@MainActor
@Observable
final class ImageTagModel: Identifiable {
    let id = UUID()
    /// The selected row, shown but not editable — tagging is always "this image
    /// gains another name".
    let source: String
    var target = ""
    private(set) var isTagging = false
    private(set) var errorMessage: String?

    init(source: String) {
        self.source = source
    }

    var targetError: String? {
        let trimmed = trimmedTarget
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try ImageTagConfiguration(source: source, target: trimmed)
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    var configuration: ImageTagConfiguration? {
        try? ImageTagConfiguration(source: source, target: trimmedTarget)
    }

    var canTag: Bool { configuration != nil && !isTagging }

    var commandPreview: String {
        guard let configuration else { return "container image tag" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.tagImage(configuration: configuration).arguments
        )
    }

    /// Returns true when the tag landed, so the sheet can dismiss itself.
    func tag(using appModel: AppModel) async -> Bool {
        guard let configuration, !isTagging else { return false }
        isTagging = true
        errorMessage = nil
        defer { isTagging = false }

        if let failure = await appModel.tagImage(configuration) {
            errorMessage = failure
            return false
        }
        return true
    }

    private var trimmedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
