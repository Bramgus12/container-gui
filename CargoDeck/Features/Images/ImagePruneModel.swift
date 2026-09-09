import Foundation
import Observation

/// Image-only pruning, kept separate from System → Reclaim so the two scopes
/// the CLI actually has can be chosen deliberately.
@MainActor
@Observable
final class ImagePruneModel: Identifiable {
    nonisolated enum Scope: String, CaseIterable, Equatable, Sendable {
        /// `image prune` — dangling images only.
        case dangling
        /// `image prune --all` — every image no container uses.
        case all
    }

    let id = UUID()
    var scope: Scope = .dangling

    var configurationIsAll: Bool { scope == .all }

    var commandPreview: String {
        ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.pruneImages(all: configurationIsAll).arguments
        )
    }

    /// What the GUI can see of the candidates, which is not the same as what the
    /// CLI will decide. Reachability is the CLI's call, so these are labelled as
    /// estimates wherever they are shown.
    func estimate(images: [ImageSummary], index: InventoryIndex) -> ImagePruneEstimate {
        let unused = images.filter { index.containers(using: $0).isEmpty }
        switch scope {
        case .all:
            return ImagePruneEstimate(
                count: unused.count,
                bytes: unused.compactMap(\.size).reduce(0, &+)
            )
        case .dangling:
            // A dangling image is one with no usable name. The GUI cannot see
            // the CLI's own reachability graph, so this only counts what is
            // visibly untagged and says so.
            let dangling = unused.filter { image in
                let reference = image.reference
                return reference.hasSuffix(":<none>")
                    || reference == "<none>"
                    || !reference.contains(":")
            }
            return ImagePruneEstimate(
                count: dangling.count,
                bytes: dangling.compactMap(\.size).reduce(0, &+)
            )
        }
    }
}

nonisolated struct ImagePruneEstimate: Equatable, Sendable {
    let count: Int
    let bytes: UInt64
}
