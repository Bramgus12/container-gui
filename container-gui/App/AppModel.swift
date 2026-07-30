import Foundation
import Observation

nonisolated protocol ContainerListing: Sendable {
    func listContainers() async throws -> [ContainerSummary]
}

actor CLIContainerListService: ContainerListing {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func listContainers() async throws -> [ContainerSummary] {
        let result = try await cli.run(.listContainers(includeStopped: true))

        do {
            let data = Data(result.standardOutput.utf8)
            return try JSONDecoder()
                .decode([ContainerDTO].self, from: data)
                .compactMap(ContainerSummary.init(dto:))
        } catch {
            throw CLIError.invalidOutput(
                description: "The container list could not be decoded as JSON: \(error.localizedDescription)"
            )
        }
    }
}

enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case containers = "Containers"
    case images = "Images"
    case system = "System"
    case settings = "Settings"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .system: "gauge.with.dots.needle.67percent"
        case .settings: "gearshape"
        }
    }
}

enum ContainerFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case running = "Running"
    case stopped = "Stopped"

    var id: Self { self }
}

enum ContainerListState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    let setup: SetupModel

    var destination: AppDestination? = .containers
    var searchText = ""
    var containerFilter: ContainerFilter = .all
    var selectedContainerID: String?

    private(set) var containers: [ContainerSummary] = []
    private(set) var containerListState: ContainerListState = .idle

    private let cliFactory: any ContainerCLIMaking
    private var containerLister: (any ContainerListing)?
    private var configuredExecutableURL: URL?
    private var refreshGeneration = 0

    convenience init() {
        self.init(setup: SetupModel())
    }

    init(
        setup: SetupModel,
        cliFactory: any ContainerCLIMaking = ProcessContainerCLIFactory(),
        containerLister: (any ContainerListing)? = nil
    ) {
        self.setup = setup
        self.cliFactory = cliFactory
        self.containerLister = containerLister
    }

    var filteredContainers: [ContainerSummary] {
        containers.filter { container in
            matchesFilter(container) && matchesSearch(container)
        }
    }

    func activate(_ context: PreflightContext) async {
        if configuredExecutableURL != context.executableURL {
            configuredExecutableURL = context.executableURL
            containerLister = CLIContainerListService(
                cli: cliFactory.makeCLI(executableURL: context.executableURL)
            )
            containers = []
            selectedContainerID = nil
            containerListState = .idle
        }

        if containerListState == .idle {
            await refreshContainers()
        }
    }

    func refreshContainers() async {
        guard let containerLister else {
            containerListState = .failed("The container executable is not ready.")
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        containerListState = .loading

        do {
            let refreshedContainers = try await containerLister.listContainers()
            guard generation == refreshGeneration else { return }

            containers = refreshedContainers
            if let selectedContainerID,
               !refreshedContainers.contains(where: { $0.id == selectedContainerID }) {
                self.selectedContainerID = nil
            }
            containerListState = .loaded
        } catch is CancellationError {
            guard generation == refreshGeneration else { return }
            containerListState = containers.isEmpty ? .idle : .loaded
        } catch {
            guard generation == refreshGeneration else { return }
            containerListState = .failed(error.localizedDescription)
        }
    }

    private func matchesFilter(_ container: ContainerSummary) -> Bool {
        switch containerFilter {
        case .all:
            true
        case .running:
            container.state == .running
        case .stopped:
            container.state == .stopped
        }
    }

    private func matchesSearch(_ container: ContainerSummary) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        return [
            container.id,
            container.image,
            container.architecture,
            container.address,
        ]
        .compactMap { $0 }
        .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
