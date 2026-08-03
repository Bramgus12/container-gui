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

nonisolated protocol ImageManaging: Sendable {
    func listImages() async throws -> [ImageSummary]
    func inspectImage(reference: String) async throws -> String
    func pullImage(reference: String) -> AsyncThrowingStream<ProcessEvent, Error>
    func deleteImage(reference: String) async throws
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

nonisolated struct CLIImageService: ImageManaging {
    let cli: any ContainerCLI

    func listImages() async throws -> [ImageSummary] {
        let result = try await cli.run(.listImages)
        do {
            return try JSONDecoder()
                .decode([ImageDTO].self, from: Data(result.standardOutput.utf8))
                .compactMap(ImageSummary.init(dto:))
        } catch {
            throw CLIError.invalidOutput(
                description: "The image list could not be decoded as JSON: \(error.localizedDescription)"
            )
        }
    }

    func inspectImage(reference: String) async throws -> String {
        let imageReference = try ImageReference(validating: reference)
        let result = try await cli.run(.inspectImage(reference: imageReference))
        let data = Data(result.standardOutput.utf8)
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let formatted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: formatted, as: UTF8.self)
        } catch {
            throw CLIError.invalidOutput(
                description: "Image inspection could not be decoded as JSON: \(error.localizedDescription)"
            )
        }
    }

    func pullImage(reference: String) -> AsyncThrowingStream<ProcessEvent, Error> {
        do {
            let imageReference = try ImageReference(validating: reference)
            return cli.stream(.pullImage(reference: imageReference))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func deleteImage(reference: String) async throws {
        let imageReference = try ImageReference(validating: reference)
        _ = try await cli.run(.deleteImage(reference: imageReference))
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

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .system: "gauge.with.dots.needle.67percent"
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

enum ImageListState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum ImageInspectionState: Equatable, Sendable {
    case idle
    case loading
    case loaded(String)
    case failed(String)
}

struct ImageDeletionFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let reference: String
    let message: String
}

@MainActor
@Observable
final class AppModel {
    let setup: SetupModel

    var destination: AppDestination? = .containers
    var searchText = ""
    var containerFilter: ContainerFilter = .all
    var selectedContainerID: String?
    var imageSearchText = ""
    var selectedImageID: String?

    private(set) var containers: [ContainerSummary] = []
    private(set) var containerListState: ContainerListState = .idle
    private(set) var containerMutations: [String: ContainerMutation] = [:]
    private(set) var mutationFailure: ContainerMutationFailure?
    private(set) var images: [ImageSummary] = []
    private(set) var imageListState: ImageListState = .idle
    private(set) var imageInspectionState: ImageInspectionState = .idle
    private(set) var deletingImageReference: String?
    private(set) var imageDeletionFailure: ImageDeletionFailure?

    private let cliFactory: any ContainerCLIMaking
    private var containerLister: (any ContainerListing)?
    private var containerMutator: (any ContainerMutating)?
    private var containerRunner: (any ContainerRunning)?
    private var containerDiagnoser: (any ContainerDiagnosing)?
    private var imageService: (any ImageManaging)?
    private let failureLog: OperationFailureLog
    private var systemModel: SystemModel?
    private var configuredExecutableURL: URL?
    private var refreshGeneration = 0
    private var imageRefreshGeneration = 0
    private var imageInspectionGeneration = 0

    convenience init() {
        self.init(setup: SetupModel())
    }

    init(
        setup: SetupModel,
        cliFactory: any ContainerCLIMaking = ProcessContainerCLIFactory(),
        containerLister: (any ContainerListing)? = nil,
        containerMutator: (any ContainerMutating)? = nil,
        containerRunner: (any ContainerRunning)? = nil,
        containerDiagnoser: (any ContainerDiagnosing)? = nil,
        imageService: (any ImageManaging)? = nil,
        failureLog: OperationFailureLog? = nil
    ) {
        self.setup = setup
        self.cliFactory = cliFactory
        self.containerLister = containerLister
        self.containerMutator = containerMutator
        self.containerRunner = containerRunner
        self.containerDiagnoser = containerDiagnoser
        self.imageService = imageService
        self.failureLog = failureLog ?? OperationFailureLog()
    }

    var filteredContainers: [ContainerSummary] {
        containers.filter { container in
            matchesFilter(container) && matchesSearch(container)
        }
    }

    var filteredImages: [ImageSummary] {
        let query = imageSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return images }
        return images.filter { image in
            [
                image.reference,
                image.digest,
                image.operatingSystem,
                image.architecture,
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
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
            imageService = CLIImageService(cli: cli)
            systemModel = SystemModel(
                context: context,
                service: CLISystemService(cli: cli),
                failureLog: failureLog
            )
            containers = []
            selectedContainerID = nil
            containerListState = .idle
            containerMutations = [:]
            mutationFailure = nil
            images = []
            selectedImageID = nil
            imageListState = .idle
            imageInspectionState = .idle
            deletingImageReference = nil
            imageDeletionFailure = nil
        }

        if containerListState == .idle {
            await refreshContainers()
        }
    }

    func refreshImages() async {
        guard let imageService else {
            imageListState = .failed("The container executable is not ready.")
            return
        }

        imageRefreshGeneration += 1
        let generation = imageRefreshGeneration
        imageListState = .loading

        do {
            let refreshedImages = try await imageService.listImages()
            guard generation == imageRefreshGeneration else { return }
            images = refreshedImages
            if let selectedImageID,
               !refreshedImages.contains(where: { $0.id == selectedImageID }) {
                self.selectedImageID = nil
                imageInspectionState = .idle
            }
            imageListState = .loaded
        } catch is CancellationError {
            guard generation == imageRefreshGeneration else { return }
            imageListState = images.isEmpty ? .idle : .loaded
        } catch {
            guard generation == imageRefreshGeneration else { return }
            failureLog.record(operation: "Refresh images", error: error)
            imageListState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    func inspectSelectedImage() async {
        guard let selectedImage else {
            imageInspectionGeneration += 1
            imageInspectionState = .idle
            return
        }
        guard let imageService else {
            imageInspectionState = .failed("The container executable is not ready.")
            return
        }

        imageInspectionGeneration += 1
        let generation = imageInspectionGeneration
        let selectedID = selectedImage.id
        imageInspectionState = .loading

        do {
            let json = try await imageService.inspectImage(reference: selectedImage.reference)
            guard generation == imageInspectionGeneration,
                  selectedImageID == selectedID else { return }
            imageInspectionState = .loaded(json)
        } catch is CancellationError {
            guard generation == imageInspectionGeneration else { return }
            imageInspectionState = .idle
        } catch {
            guard generation == imageInspectionGeneration,
                  selectedImageID == selectedID else { return }
            failureLog.record(operation: "Inspect image", error: error)
            imageInspectionState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    func pullImage(
        reference: String,
        onEvent: (ProcessEvent) -> Void
    ) async throws {
        guard let imageService else {
            throw CLIError.launchFailed(message: "The container executable is not ready.")
        }

        do {
            var standardError = ""
            for try await event in imageService.pullImage(reference: reference) {
                if case .standardError(let output) = event {
                    standardError.append(output)
                }
                if case .terminated(let exitCode) = event, exitCode != 0 {
                    onEvent(event)
                    let validatedReference = try ImageReference(validating: reference)
                    throw CLIError.nonZeroExit(
                        invocation: ProcessContainerCLI.displayInvocation(
                            executable: "container",
                            arguments: ContainerCommand.pullImage(reference: validatedReference).arguments
                        ),
                        exitCode: exitCode,
                        standardError: standardError
                    )
                }
                onEvent(event)
            }
            await refreshImages()
        } catch {
            failureLog.record(operation: "Pull image", error: error)
            throw error
        }
    }

    func deleteImage(reference: String) async {
        guard deletingImageReference == nil else { return }
        guard images.contains(where: { $0.reference == reference }) else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "The image changed. Refresh the list and try again."
            )
            return
        }
        guard let imageService else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "The container executable is not ready."
            )
            return
        }

        imageDeletionFailure = nil
        deletingImageReference = reference
        defer { deletingImageReference = nil }
        do {
            try await imageService.deleteImage(reference: reference)
        } catch is CancellationError {
            // Cancellation is intentional.
        } catch CLIError.cancelled {
            // Process cancellation is normalized by ProcessContainerCLI.
        } catch {
            failureLog.record(operation: "Delete image", error: error)
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: DiagnosticSanitizer.sanitize(error.localizedDescription)
            )
        }
        await refreshImages()
    }

    func dismissImageDeletionFailure() {
        imageDeletionFailure = nil
    }

    var selectedImage: ImageSummary? {
        guard let selectedImageID else { return nil }
        return images.first { $0.id == selectedImageID }
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
            failureLog.record(operation: "Refresh containers", error: error)
            containerListState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
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
            failureLog.record(operation: mutation.displayName + " container", error: error)
            mutationFailure = ContainerMutationFailure(
                containerID: containerID,
                mutation: mutation,
                message: DiagnosticSanitizer.sanitize(error.localizedDescription)
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

    func makeSystemModel(context: PreflightContext) -> SystemModel {
        if let systemModel {
            return systemModel
        }
        let cli = cliFactory.makeCLI(executableURL: context.executableURL)
        let model = SystemModel(
            context: context,
            service: CLISystemService(cli: cli),
            failureLog: failureLog
        )
        systemModel = model
        return model
    }

    func runContainer(
        _ configuration: RunConfiguration,
        onEvent: (ProcessEvent) -> Void
    ) async throws {
        guard let containerRunner else {
            throw CLIError.launchFailed(message: "The container executable is not ready.")
        }

        var standardOutput = ""
        do {
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
        } catch {
            failureLog.record(operation: "Run container", error: error)
            throw error
        }
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
