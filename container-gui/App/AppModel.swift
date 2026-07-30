import Foundation
import Observation

nonisolated protocol ContainerListing: Sendable {
    func listContainers() async throws -> [ContainerSummary]
}

nonisolated protocol ContainerMutating: Sendable {
    func mutate(_ mutation: ContainerMutation, containerID: String) async throws
}

nonisolated protocol ContainerRunning: Sendable {
    func streamRun(
        _ configuration: RunConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error>
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

actor CLIContainerMutationService: ContainerMutating {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func mutate(_ mutation: ContainerMutation, containerID: String) async throws {
        let identifier = try ContainerIdentifier(validating: containerID)
        _ = try await cli.run(mutation.command(for: identifier))
    }
}

nonisolated struct CLIContainerRunService: ContainerRunning {
    let cli: any ContainerCLI

    func streamRun(
        _ configuration: RunConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        cli.stream(.run(configuration))
    }
}

nonisolated enum ContainerMutation: Equatable, Sendable {
    case start
    case stop
    case delete(force: Bool)

    var displayName: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .delete(force: false): "Delete"
        case .delete(force: true): "Force Delete"
        }
    }

    func isAllowed(for state: ContainerState) -> Bool {
        switch (self, state) {
        case (.start, .created), (.start, .stopped):
            true
        case (.stop, .running), (.stop, .paused):
            true
        case (.delete(force: false), .created), (.delete(force: false), .stopped):
            true
        case (.delete(force: true), .created),
             (.delete(force: true), .running),
             (.delete(force: true), .stopped),
             (.delete(force: true), .paused):
            true
        default:
            false
        }
    }

    fileprivate func command(for identifier: ContainerIdentifier) -> ContainerCommand {
        switch self {
        case .start:
            .start(id: identifier)
        case .stop:
            .stop(id: identifier, timeout: nil)
        case .delete(let force):
            .delete(id: identifier, force: force)
        }
    }
}

nonisolated struct ContainerMutationFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let containerID: String
    let mutation: ContainerMutation
    let message: String
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
    private(set) var containerMutations: [String: ContainerMutation] = [:]
    private(set) var mutationFailure: ContainerMutationFailure?

    private let cliFactory: any ContainerCLIMaking
    private var containerLister: (any ContainerListing)?
    private var containerMutator: (any ContainerMutating)?
    private var containerRunner: (any ContainerRunning)?
    private var containerDiagnoser: (any ContainerDiagnosing)?
    private var configuredExecutableURL: URL?
    private var refreshGeneration = 0

    convenience init() {
        self.init(setup: SetupModel())
    }

    init(
        setup: SetupModel,
        cliFactory: any ContainerCLIMaking = ProcessContainerCLIFactory(),
        containerLister: (any ContainerListing)? = nil,
        containerMutator: (any ContainerMutating)? = nil,
        containerRunner: (any ContainerRunning)? = nil,
        containerDiagnoser: (any ContainerDiagnosing)? = nil
    ) {
        self.setup = setup
        self.cliFactory = cliFactory
        self.containerLister = containerLister
        self.containerMutator = containerMutator
        self.containerRunner = containerRunner
        self.containerDiagnoser = containerDiagnoser
    }

    var filteredContainers: [ContainerSummary] {
        containers.filter { container in
            matchesFilter(container) && matchesSearch(container)
        }
    }

    func activate(_ context: PreflightContext) async {
        if configuredExecutableURL != context.executableURL {
            configuredExecutableURL = context.executableURL
            let cli = cliFactory.makeCLI(executableURL: context.executableURL)
            containerLister = CLIContainerListService(cli: cli)
            containerMutator = CLIContainerMutationService(cli: cli)
            containerRunner = CLIContainerRunService(cli: cli)
            containerDiagnoser = CLIContainerDiagnosticsService(cli: cli)
            containers = []
            selectedContainerID = nil
            containerListState = .idle
            containerMutations = [:]
            mutationFailure = nil
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

    func mutationInProgress(for containerID: String) -> ContainerMutation? {
        containerMutations[containerID]
    }

    func canPerform(_ mutation: ContainerMutation, on container: ContainerSummary) -> Bool {
        containerMutations[container.id] == nil && mutation.isAllowed(for: container.state)
    }

    func perform(_ mutation: ContainerMutation, on containerID: String) async {
        guard containerMutations[containerID] == nil else {
            return
        }
        guard let container = containers.first(where: { $0.id == containerID }),
              mutation.isAllowed(for: container.state)
        else {
            mutationFailure = ContainerMutationFailure(
                containerID: containerID,
                mutation: mutation,
                message: "The container state changed. Refresh the list and try again."
            )
            return
        }
        guard let containerMutator else {
            mutationFailure = ContainerMutationFailure(
                containerID: containerID,
                mutation: mutation,
                message: "The container executable is not ready."
            )
            return
        }

        mutationFailure = nil
        containerMutations[containerID] = mutation
        defer { containerMutations[containerID] = nil }

        do {
            try await containerMutator.mutate(mutation, containerID: containerID)
        } catch is CancellationError {
            // Cancellation is an intentional transition, not a user-facing failure.
        } catch CLIError.cancelled {
            // ProcessContainerCLI normalizes process cancellation to CLIError.cancelled.
        } catch {
            mutationFailure = ContainerMutationFailure(
                containerID: containerID,
                mutation: mutation,
                message: error.localizedDescription
            )
        }

        await refreshContainers()
    }

    func dismissMutationFailure() {
        mutationFailure = nil
    }

    func makeContainerDetailModel(containerID: String) -> ContainerDetailModel? {
        guard let containerDiagnoser else { return nil }
        return ContainerDetailModel(containerID: containerID, service: containerDiagnoser)
    }

    func runContainer(
        _ configuration: RunConfiguration,
        onEvent: (ProcessEvent) -> Void
    ) async throws {
        guard let containerRunner else {
            throw CLIError.launchFailed(message: "The container executable is not ready.")
        }

        var standardOutput = ""
        var standardError = ""
        for try await event in containerRunner.streamRun(configuration) {
            switch event {
            case .standardOutput(let output):
                standardOutput.append(output)
            case .standardError(let output):
                standardError.append(output)
            case .terminated(let exitCode) where exitCode != 0:
                onEvent(event)
                throw CLIError.nonZeroExit(
                    invocation: ProcessContainerCLI.displayInvocation(
                        executable: "container",
                        arguments: ContainerCommand.run(configuration).arguments
                    ),
                    exitCode: exitCode,
                    standardError: standardError
                )
            case .terminated:
                break
            }
            onEvent(event)
        }

        await refreshContainers()
        selectNewContainer(configuration: configuration, standardOutput: standardOutput)
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

    private func selectNewContainer(
        configuration: RunConfiguration,
        standardOutput: String
    ) {
        if let requestedName = configuration.name?.rawValue,
           containers.contains(where: { $0.id == requestedName }) {
            selectedContainerID = requestedName
            return
        }

        let outputTokens = standardOutput
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .reversed()
        if let container = containers.first(where: { container in
            outputTokens.contains {
                container.id == $0
                    || container.id.hasPrefix($0)
                    || $0.hasPrefix(container.id)
            }
        }) {
            selectedContainerID = container.id
        }
    }
}
