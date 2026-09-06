import Foundation
import Observation

/// Save takes a checklist rather than the table's selection: it is the one image
/// operation whose scope is naturally several images, and widening `DSTable` to
/// multi-selection would change every other screen's selection contract.
@MainActor
@Observable
final class ImageSaveModel: Identifiable {
    let id = UUID()
    let available: [ImageSummary]
    var selectedReferences: Set<String>
    var outputPath = ""
    var platform = ""
    var operatingSystem = ""
    var architecture = ""

    init(available: [ImageSummary], preselected: String?) {
        self.available = available
        selectedReferences = preselected.map { [$0] } ?? []
    }

    func toggle(_ reference: String) {
        if selectedReferences.contains(reference) {
            selectedReferences.remove(reference)
        } else {
            selectedReferences.insert(reference)
        }
    }

    /// Kept in the table's order rather than the order they were ticked, so the
    /// command preview is stable as the checklist changes.
    var orderedSelection: [String] {
        available.map(\.reference).filter { selectedReferences.contains($0) }
    }

    var outputError: String? {
        let trimmed = trimmedOutputPath
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try LocalPath(validating: trimmed, field: "Archive path")
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

    var configuration: ImageSaveConfiguration? {
        try? ImageSaveConfiguration(
            references: orderedSelection,
            output: trimmedOutputPath,
            platform: platformSelection()
        )
    }

    var canSave: Bool { configuration != nil }

    var commandPreview: String {
        guard let configuration else { return "container image save" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.saveImages(configuration: configuration).arguments
        )
    }

    /// The archive the operation will write, for the Reveal in Finder action.
    var outputURL: URL? {
        guard let path = try? LocalPath(validating: trimmedOutputPath, field: "Archive path") else {
            return nil
        }
        return URL(fileURLWithPath: path.rawValue)
    }

    private var trimmedOutputPath: String {
        outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func platformSelection() throws -> ImagePlatformSelection {
        try ImagePlatformSelection(
            platform: platform,
            operatingSystem: operatingSystem,
            architecture: architecture
        )
    }
}

@MainActor
@Observable
final class ImageLoadModel: Identifiable {
    let id = UUID()
    var inputPath = ""
    /// Off by default. Force accepts an archive that contains invalid member
    /// files; it does not bypass every import failure, and the sheet says so.
    var force = false

    var inputError: String? {
        let trimmed = trimmedInputPath
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try LocalPath(validating: trimmed, field: "Archive path")
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    var configuration: ImageLoadConfiguration? {
        try? ImageLoadConfiguration(input: trimmedInputPath, force: force)
    }

    var canLoad: Bool { configuration != nil }

    var commandPreview: String {
        guard let configuration else { return "container image load" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.loadImages(configuration: configuration).arguments
        )
    }

    private var trimmedInputPath: String {
        inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
