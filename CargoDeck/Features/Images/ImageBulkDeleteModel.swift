import Foundation
import Observation

/// The exact set a bulk delete will run against, resolved from a freshly
/// refreshed snapshot. Holding it as a value is what makes "the scope you
/// confirmed is the scope that ran" checkable rather than merely intended.
nonisolated struct ImageBulkDeleteScope: Equatable, Sendable {
    let references: [String]
    let blockedReferences: [String]
    let totalBytes: UInt64
    let isAll: Bool

    var deletableCount: Int { isAll ? references.count : references.count }
}

/// Named or all-image deletion.
///
/// Unlike the single-image path this never deletes dependent containers: one
/// bulk action must not cascade into unrelated container deletion. Images a
/// container still uses are listed as blocked, passed to the CLI anyway, and
/// preserved by it — the failure is then reported per image.
@MainActor
@Observable
final class ImageBulkDeleteModel: Identifiable {
    nonisolated enum Mode: String, CaseIterable, Equatable, Sendable {
        case named
        case all
    }

    let id = UUID()
    var mode: Mode = .named
    var selectedReferences: Set<String> = []
    /// The CLI's narrow meaning, and the only one offered: ignore targets that
    /// are already gone. It never force-removes an in-use image.
    var ignoreMissing = false

    private(set) var isPreparing = false
    private(set) var staleScopeMessage: String?
    /// Non-nil once a fresh snapshot has confirmed the scope. Any change to the
    /// form clears it, so confirmation always follows a verified snapshot.
    private(set) var confirmedScope: ImageBulkDeleteScope?

    init(preselected: String? = nil) {
        selectedReferences = preselected.map { [$0] } ?? []
    }

    func toggle(_ reference: String) {
        if selectedReferences.contains(reference) {
            selectedReferences.remove(reference)
        } else {
            selectedReferences.insert(reference)
        }
        invalidateConfirmation()
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        invalidateConfirmation()
    }

    func setIgnoreMissing(_ value: Bool) {
        ignoreMissing = value
        invalidateConfirmation()
    }

    func invalidateConfirmation() {
        confirmedScope = nil
        staleScopeMessage = nil
    }

    func orderedSelection(from images: [ImageSummary]) -> [String] {
        images.map(\.reference).filter { selectedReferences.contains($0) }
    }

    var hasSelection: Bool { mode == .all || !selectedReferences.isEmpty }

    func configuration(from images: [ImageSummary]) -> ImageDeleteConfiguration? {
        switch mode {
        case .all:
            return try? ImageDeleteConfiguration(all: true, force: ignoreMissing)
        case .named:
            return try? ImageDeleteConfiguration(
                references: orderedSelection(from: images),
                force: ignoreMissing
            )
        }
    }

    func commandPreview(from images: [ImageSummary]) -> String {
        guard let configuration = configuration(from: images) else {
            return "container image delete"
        }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.deleteImages(configuration: configuration).arguments
        )
    }

    /// Refreshes images and containers, then resolves the scope against what
    /// came back. A snapshot that no longer matches the review returns the sheet
    /// to review rather than executing a scope the user never saw.
    func prepareConfirmation(using appModel: AppModel) async {
        guard !isPreparing else { return }
        isPreparing = true
        staleScopeMessage = nil
        confirmedScope = nil
        defer { isPreparing = false }

        let reviewed = mode == .all ? nil : Set(selectedReferences)

        await appModel.refreshImages()
        await appModel.refreshContainers()

        guard case .loaded = appModel.imageListState else {
            staleScopeMessage = "The image list could not be rechecked. Try again."
            return
        }
        guard case .loaded = appModel.containerListState else {
            staleScopeMessage = "Dependent containers could not be rechecked. Try again."
            return
        }

        let images = appModel.images
        let index = appModel.inventoryIndex

        if let reviewed {
            let present = Set(images.map(\.reference))
            let vanished = reviewed.subtracting(present)
            guard vanished.isEmpty else {
                // Drop what is gone so a second Review shows the real set.
                selectedReferences.subtract(vanished)
                staleScopeMessage = vanished.count == 1
                    ? "“\(vanished.sorted().joined())” is no longer present. Review the selection again."
                    : "\(vanished.count) selected images are no longer present. Review the selection again."
                return
            }
        }

        let targets: [ImageSummary]
        switch mode {
        case .all:
            targets = images
        case .named:
            targets = images.filter { selectedReferences.contains($0.reference) }
        }
        guard !targets.isEmpty else {
            staleScopeMessage = "Nothing is selected to delete."
            return
        }

        let blocked = targets
            .filter { !index.containers(using: $0).isEmpty }
            .map(\.reference)

        confirmedScope = ImageBulkDeleteScope(
            references: targets.map(\.reference),
            blockedReferences: blocked,
            totalBytes: targets.compactMap(\.size).reduce(0, &+),
            isAll: mode == .all
        )
    }
}
