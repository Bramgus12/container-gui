import Foundation

nonisolated struct InventoryIndex: Equatable, Sendable {
    private let imageContainers: [String: [ContainerSummary]]
    private let volumeContainers: [String: [ContainerSummary]]
    private let networkContainerCounts: [String: Int]

    init(
        containers: [ContainerSummary],
        images: [ImageSummary] = [],
        volumes: [VolumeSummary] = [],
        networks: [NetworkSummary] = []
    ) {
        var imageContainers: [String: [ContainerSummary]] = [:]
        for image in images {
            imageContainers[image.id] = containers
                .filter { container in
                    if let digest = image.digest, let containerDigest = container.imageDigest {
                        return digest == containerDigest
                    }
                    return container.image == image.reference
                }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }

        var volumeContainers: [String: [ContainerSummary]] = [:]
        for volume in volumes {
            volumeContainers[volume.name] = containers
                .filter { container in
                    container.mounts.contains { $0.source == volume.name || $0.source == volume.id }
                }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }

        var networkContainerCounts = Dictionary(
            uniqueKeysWithValues: networks.map { ($0.name, 0) }
        )
        for container in containers {
            for name in container.networkNames {
                networkContainerCounts[name, default: 0] += 1
            }
        }

        self.imageContainers = imageContainers
        self.volumeContainers = volumeContainers
        self.networkContainerCounts = networkContainerCounts
    }

    static let empty = InventoryIndex(containers: [])

    func containers(using image: ImageSummary) -> [ContainerSummary] {
        imageContainers[image.id] ?? []
    }

    func containers(attachedTo volume: VolumeSummary) -> [ContainerSummary] {
        volumeContainers[volume.name] ?? []
    }

    func attachedContainerCount(for network: NetworkSummary) -> Int {
        networkContainerCounts[network.name] ?? 0
    }
}
