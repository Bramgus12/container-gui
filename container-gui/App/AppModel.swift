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
    func inspectImage(reference: String) async throws -> ImageInspection
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

    func inspectImage(reference: String) async throws -> ImageInspection {
        let imageReference = try ImageReference(validating: reference)
        let result = try await cli.run(.inspectImage(reference: imageReference))
        let data = Data(result.standardOutput.utf8)
        do {
            let dtos: [ImageDTO]
            if let decoded = try? JSONDecoder().decode([ImageDTO].self, from: data) {
                dtos = decoded
            } else {
                dtos = [try JSONDecoder().decode(ImageDTO.self, from: data)]
            }
            guard let dto = dtos.first,
                  dto.containsInspectionData,
                  let inspection = ImageInspection(
                    dto: dto,
                    fallbackReference: reference,
                    rawJSON: result.standardOutput
                  ) else {
                throw CLIError.invalidOutput(description: "Image inspection returned no entries.")
            }
            return inspection
        } catch let error as CLIError {
            throw error
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
    var invocation: String? = nil
    var exitCode: Int32? = nil
}

enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case containers = "Containers"
    case images = "Images"
    case volumes = "Volumes"
    case networks = "Networks"
    case system = "System"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .system: "gauge.with.dots.needle.67percent"
        }
    }
}

enum ContainerFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case running = "Running"
    case stopped = "Stopped"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .running: "Running"
        case .stopped: "Stopped"
        }
    }
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
    case loaded(ImageInspection)
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
    var searchText = "" {
        didSet { updateFilteredContainers() }
    }
    var containerFilter: ContainerFilter = .all {
        didSet { updateFilteredContainers() }
    }
    var selectedContainerID: String?
    var imageSearchText = "" {
        didSet { updateFilteredImages() }
    }
    /// Narrows the images table to images no container references. Housekeeping
    /// is a filter rather than a bulk selection — deleting still goes one image
    /// at a time, or through Reclaim on the System screen.
    var showsUnusedImagesOnly = false {
        didSet { updateFilteredImages() }
    }
    var selectedImageID: String?

    private(set) var containers: [ContainerSummary] = [] {
        didSet {
            updateFilteredContainers()
            dnsModel?.updateRegisteredNames(from: containers)
            rebuildInventoryIndex()
        }
    }
    private(set) var filteredContainers: [ContainerSummary] = []
    private(set) var containerListState: ContainerListState = .idle
    private(set) var lastContainerRefresh: Date?
    private(set) var containerMutations: [String: ContainerMutation] = [:] {
        didSet { statsPoller?.setPaused(!containerMutations.isEmpty) }
    }
    private(set) var mutationFailure: ContainerMutationFailure?
    private(set) var images: [ImageSummary] = [] {
        didSet {
            updateFilteredImages()
            rebuildInventoryIndex()
        }
    }
    private(set) var filteredImages: [ImageSummary] = []
    private(set) var imageListState: ImageListState = .idle
    private(set) var imageInspectionState: ImageInspectionState = .idle
    private(set) var preparingImageDeletionReference: String?
    private(set) var deletingImageReference: String?
    private(set) var imageDeletionFailure: ImageDeletionFailure?
    private(set) var networkModel: NetworkModel?
    private(set) var volumeModel: VolumeModel?
    private(set) var builderModel: BuilderModel?
    private(set) var systemModel: SystemModel?
    private(set) var dnsModel: DNSModel?
    private(set) var statsPoller: ContainerStatsPoller?

    private let cliFactory: any ContainerCLIMaking
    private var containerLister: (any ContainerListing)?
    private var containerMutator: (any ContainerMutating)?
    private var containerRunner: (any ContainerRunning)?
    private var containerDiagnoser: (any ContainerDiagnosing)?
    private var imageService: (any ImageManaging)?
    private var imageBuilder: (any ImageBuilding)?
    private let failureLog: OperationFailureLog
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
        imageBuilder: (any ImageBuilding)? = nil,
        networkService: (any NetworkManaging)? = nil,
        networkCapabilities: NetworkCapabilities? = nil,
        volumeService: (any VolumeManaging)? = nil,
        builderService: (any BuilderManaging)? = nil,
        dnsService: (any DNSManaging)? = nil,
        failureLog: OperationFailureLog? = nil
    ) {
        self.setup = setup
        self.cliFactory = cliFactory
        self.containerLister = containerLister
        self.containerMutator = containerMutator
        self.containerRunner = containerRunner
        self.containerDiagnoser = containerDiagnoser
        self.imageService = imageService
        self.imageBuilder = imageBuilder
        self.failureLog = failureLog ?? OperationFailureLog()
        if let networkService {
            self.networkModel = NetworkModel(
                service: networkService,
                capabilities: networkCapabilities ?? NetworkCapabilities(
                    version: SemanticVersion(major: 1, minor: 0, patch: 0)
                ),
                failureLog: self.failureLog
            )
        }
        if let volumeService {
            volumeModel = VolumeModel(service: volumeService, failureLog: self.failureLog)
        }
        if let builderService {
            builderModel = BuilderModel(service: builderService, failureLog: self.failureLog)
        }
        if let dnsService {
            dnsModel = DNSModel(service: dnsService, resolverReader: SystemResolverDirectoryReader(), hostResolver: SystemHostResolver(), failureLog: self.failureLog)
        }
        if let statsProvider = containerDiagnoser as? any ContainerStatsListing {
            statsPoller = ContainerStatsPoller(provider: statsProvider)
        }
    }

    var isContainerInspectorPresented: Bool {
        get { selectedContainerID != nil }
        set {
            if !newValue {
                selectedContainerID = nil
            }
        }
    }

    var isImageInspectorPresented: Bool {
        get { selectedImageID != nil }
        set {
            if !newValue {
                selectedImageID = nil
            }
        }
    }

    private func updateFilteredContainers() {
        filteredContainers = containers.filter { container in
            matchesFilter(container) && matchesSearch(container)
        }
    }

    private func updateFilteredImages() {
        let query = imageSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = images
        if showsUnusedImagesOnly {
            result = result.filter { inventoryIndex.containers(using: $0).isEmpty }
        }
        if !query.isEmpty {
            result = result.filter { image in
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
        filteredImages = result
    }

    var unusedImages: [ImageSummary] {
        images.filter { inventoryIndex.containers(using: $0).isEmpty }
    }

    func activate(_ context: PreflightContext) async {
        if configuredExecutableURL != context.executableURL {
            configuredExecutableURL = context.executableURL
            let cli = cliFactory.makeCLI(executableURL: context.executableURL)
            containerLister = CLIContainerListService(cli: cli)
            containerMutator = CLIContainerMutationService(cli: cli)
            containerRunner = CLIContainerRunService(cli: cli)
            let diagnostics = CLIContainerDiagnosticsService(cli: cli)
            containerDiagnoser = diagnostics
            statsPoller = ContainerStatsPoller(provider: diagnostics)
            imageService = CLIImageService(cli: cli)
            imageBuilder = CLIImageBuildService(cli: cli)
            let cliVersion = (try? context.versions.cli.map { try SemanticVersion($0.version) })
                ?? SemanticVersion(major: 1, minor: 0, patch: 0)
            networkModel = NetworkModel(
                service: CLINetworkService(cli: cli),
                capabilities: NetworkCapabilities(version: cliVersion),
                failureLog: failureLog
            )
            volumeModel = VolumeModel(
                service: CLIVolumeService(cli: cli),
                failureLog: failureLog
            )
            builderModel = BuilderModel(
                service: CLIBuilderService(cli: cli),
                failureLog: failureLog
            )
            systemModel = SystemModel(
                context: context,
                service: CLISystemService(cli: cli),
                failureLog: failureLog
            )
            dnsModel = DNSModel(service: CLIDNSService(cli: cli), resolverReader: SystemResolverDirectoryReader(), hostResolver: SystemHostResolver(), failureLog: failureLog)
            containers = []
            selectedContainerID = nil
            containerListState = .idle
            containerMutations = [:]
            mutationFailure = nil
            images = []
            selectedImageID = nil
            imageListState = .idle
            imageInspectionState = .idle
            preparingImageDeletionReference = nil
            deletingImageReference = nil
            imageDeletionFailure = nil
        }

        if containerListState == .idle {
            await refreshContainers()
        }
        Task { [weak self] in
            await self?.refreshSidebarData()
        }
    }

    /// Rebuilt only when one of its four inputs changes. It is read from inside
    /// table cell bodies, so deriving it on every access would re-filter the
    /// whole container list once per row per redraw.
    private(set) var inventoryIndex: InventoryIndex = .empty

    /// Volumes and networks live in their own observable models, so the screens
    /// that own them call this when their list changes.
    func refreshInventoryIndex() {
        rebuildInventoryIndex()
    }

    private func rebuildInventoryIndex() {
        inventoryIndex = InventoryIndex(
            containers: containers,
            images: images,
            volumes: volumeModel?.volumes ?? [],
            networks: networkModel?.networks ?? []
        )
        if showsUnusedImagesOnly {
            updateFilteredImages()
        }
    }

    func inventoryCount(for destination: AppDestination) -> Int? {
        switch destination {
        case .containers: containers.count
        case .images: images.count
        case .volumes: volumeModel?.volumes.count
        case .networks: networkModel?.networks.count
        case .system: nil
        }
    }

    var systemNeedsAttention: Bool {
        guard let systemModel else { return false }
        return !systemModel.status.isRunning
            || systemModel.snapshotState.failedMessage != nil
            || builderModel?.loadingState.failedMessage != nil
    }

    func refreshSidebarData() async {
        async let images: Void = refreshImages()
        async let volumes: Void = volumeModel?.refresh() ?? ()
        async let networks: Void = networkModel?.refresh() ?? ()
        async let builder: Void = builderModel?.refresh() ?? ()
        async let system: Void = systemModel?.refresh() ?? ()
        _ = await (images, volumes, networks, builder, system)
        rebuildInventoryIndex()
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
            let inspection = try await imageService.inspectImage(reference: selectedImage.reference)
            guard generation == imageInspectionGeneration,
                  selectedImageID == selectedID else { return }
            imageInspectionState = .loaded(inspection)
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

    func prepareImageDeletion(reference: String) async -> ImageDeletionPlan? {
        guard preparingImageDeletionReference == nil,
              deletingImageReference == nil else { return nil }
        guard let image = images.first(where: { $0.reference == reference }) else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "The image changed. Refresh the list and try again."
            )
            return nil
        }

        imageDeletionFailure = nil
        preparingImageDeletionReference = reference
        defer { preparingImageDeletionReference = nil }

        await refreshContainers()
        guard case .loaded = containerListState else {
            let message: String
            if case .failed(let failure) = containerListState {
                message = "Dependent containers could not be checked: \(failure)"
            } else {
                message = "Dependent containers could not be checked. Try again."
            }
            imageDeletionFailure = ImageDeletionFailure(reference: reference, message: message)
            return nil
        }
        guard images.contains(where: { $0.id == image.id }) else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "The image changed. Refresh the list and try again."
            )
            return nil
        }

        let dependencies = dependentContainers(for: image)
        return ImageDeletionPlan(
            image: image,
            dependentContainers: dependencies,
            unresolvedContainers: unresolvedContainers(excluding: dependencies)
        )
    }

    func deleteImage(using plan: ImageDeletionPlan) async {
        let reference = plan.image.reference
        guard deletingImageReference == nil else { return }
        guard images.contains(where: { $0.id == plan.image.id }) else {
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
        guard let imageDigest = plan.image.digest else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "The image has no stable digest. Refresh the image list or delete it from Terminal."
            )
            return
        }

        imageDeletionFailure = nil
        deletingImageReference = reference
        defer { deletingImageReference = nil }

        await refreshImages()
        guard case .loaded = imageListState,
              images.first(where: { $0.id == plan.image.id }) == plan.image else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "The image changed. Review the deletion again."
            )
            return
        }

        await refreshContainers()
        guard case .loaded = containerListState else {
            let message: String
            if case .failed(let failure) = containerListState {
                message = "Dependent containers could not be rechecked: \(failure)"
            } else {
                message = "Dependent containers could not be rechecked. Try again."
            }
            imageDeletionFailure = ImageDeletionFailure(reference: reference, message: message)
            await refreshImages()
            return
        }

        let currentDependencies = dependentContainers(for: plan.image)
        guard deletionSnapshots(currentDependencies) == deletionSnapshots(plan.dependentContainers)
        else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "Dependent containers changed. Review the deletion again."
            )
            await refreshImages()
            return
        }
        let currentUnresolvedContainers = unresolvedContainers(excluding: currentDependencies)
        guard deletionSnapshots(currentUnresolvedContainers)
            == deletionSnapshots(plan.unresolvedContainers) else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "Containers with unresolved image identities changed. Review the deletion again."
            )
            await refreshImages()
            return
        }
        guard currentUnresolvedContainers.isEmpty else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "Some containers do not report stable image digests. Review them manually before deleting this image."
            )
            await refreshImages()
            return
        }
        guard currentDependencies.allSatisfy({ cleanupMutation(for: $0) != nil }) else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "A dependent container has an unsupported state. Delete it manually and try again."
            )
            await refreshImages()
            return
        }
        guard currentDependencies.allSatisfy({ $0.imageDigest != nil }) else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "A dependent container has no stable image digest. Delete it manually and try again."
            )
            await refreshImages()
            return
        }
        let cleanupOperations = currentDependencies.compactMap { container in
            cleanupMutation(for: container).map { (container, $0) }
        }
        guard cleanupOperations.allSatisfy({ containerMutations[$0.0.id] == nil }) else {
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: "Another operation is using a dependent container. Try again when it finishes."
            )
            await refreshImages()
            return
        }
        for (container, mutation) in cleanupOperations {
            containerMutations[container.id] = mutation
        }
        defer {
            for (container, mutation) in cleanupOperations
            where containerMutations[container.id] == mutation {
                containerMutations[container.id] = nil
            }
        }

        var deletedContainerCount = 0
        do {
            for (container, mutation) in cleanupOperations {
                do {
                    try await execute(mutation, on: container, reservationIsHeld: true)
                    deletedContainerCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch CLIError.cancelled {
                    throw CLIError.cancelled
                } catch {
                    let prefix = deletedContainerCount == 0
                        ? "No dependent containers were deleted."
                        : "\(deletedContainerCount) dependent container(s) were deleted and cannot be restored."
                    throw ImageCleanupError(
                        message: "\(prefix) Failed to delete \(container.id): \(error.localizedDescription)"
                    )
                }
            }
            do {
                try await imageService.deleteImage(
                    reference: imageDigest
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch CLIError.cancelled {
                throw CLIError.cancelled
            } catch {
                let prefix = deletedContainerCount == 0
                    ? ""
                    : "\(deletedContainerCount) dependent container(s) were deleted and cannot be restored. "
                throw ImageCleanupError(
                    message: "\(prefix)Failed to delete the image: \(error.localizedDescription)"
                )
            }
        } catch is CancellationError {
            // Refresh below because completed mutations cannot be rolled back.
        } catch CLIError.cancelled {
            // ProcessContainerCLI normalizes process cancellation.
        } catch {
            failureLog.record(operation: "Delete image and dependent containers", error: error)
            imageDeletionFailure = ImageDeletionFailure(
                reference: reference,
                message: DiagnosticSanitizer.sanitize(error.localizedDescription)
            )
        }

        await refreshContainers()
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
            lastContainerRefresh = Date()
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
        mutationFailure = nil
        do {
            try await execute(mutation, on: container)
        } catch is CancellationError {
            // Cancellation is an intentional transition, not a user-facing failure.
        } catch CLIError.cancelled {
            // ProcessContainerCLI normalizes process cancellation to CLIError.cancelled.
        } catch {
            failureLog.record(operation: mutation.displayName + " container", error: error)
            let commandDetails: (String?, Int32?)
            if case .nonZeroExit(let invocation, let exitCode, _, _) = error as? CLIError {
                commandDetails = (invocation, exitCode)
            } else {
                commandDetails = (nil, nil)
            }
            mutationFailure = ContainerMutationFailure(
                containerID: containerID,
                mutation: mutation,
                message: DiagnosticSanitizer.sanitize(error.localizedDescription),
                invocation: commandDetails.0.map(DiagnosticSanitizer.sanitize),
                exitCode: commandDetails.1
            )
        }

        await refreshContainers()

        // Starting or stopping a container moves the numbers the sidebar shows.
        // Only the system snapshot is re-read — a full sidebar refresh would
        // spend five CLI processes to update two figures.
        Task { [weak self] in
            await self?.systemModel?.refresh()
        }
    }

    private func execute(
        _ mutation: ContainerMutation,
        on container: ContainerSummary,
        reservationIsHeld: Bool = false
    ) async throws {
        guard mutation.isAllowed(for: container.state) else {
            throw ImageCleanupError(
                message: "The state of \(container.id) changed. Refresh and try again."
            )
        }
        guard let containerMutator else {
            throw CLIError.launchFailed(message: "The container executable is not ready.")
        }

        if reservationIsHeld {
            guard containerMutations[container.id] == mutation else {
                throw ImageCleanupError(message: "The cleanup reservation for \(container.id) was lost.")
            }
            try await containerMutator.mutate(mutation, containerID: container.id)
            return
        }

        guard containerMutations[container.id] == nil else {
            throw ImageCleanupError(message: "Another operation is using \(container.id).")
        }
        containerMutations[container.id] = mutation
        defer { containerMutations[container.id] = nil }
        try await containerMutator.mutate(mutation, containerID: container.id)
    }

    private func dependentContainers(for image: ImageSummary) -> [ContainerSummary] {
        return containers
            .filter { container in
                if let imageDigest = image.digest, let containerDigest = container.imageDigest {
                    return imageDigest == containerDigest
                }
                return container.image == image.reference
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func unresolvedContainers(
        excluding dependencies: [ContainerSummary]
    ) -> [ContainerSummary] {
        let dependencyIDs = Set(dependencies.map(\.id))
        return containers
            .filter { $0.imageDigest == nil && !dependencyIDs.contains($0.id) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func cleanupMutation(for container: ContainerSummary) -> ContainerMutation? {
        switch container.state {
        case .created, .stopped:
            .delete(force: false)
        case .running, .paused:
            .delete(force: true)
        case .unknown:
            nil
        }
    }

    private func deletionSnapshots(
        _ containers: [ContainerSummary]
    ) -> [ImageDeletionDependencySnapshot] {
        containers.map {
            ImageDeletionDependencySnapshot(
                id: $0.id,
                state: $0.state,
                image: $0.image,
                imageDigest: $0.imageDigest
            )
        }
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

    func buildImage(
        _ configuration: BuildConfiguration,
        onEvent: (ProcessEvent) -> Void
    ) async throws {
        guard let imageBuilder else {
            throw CLIError.launchFailed(message: "The container executable is not ready.")
        }
        do {
            var standardError = ""
            for try await event in imageBuilder.buildImage(configuration) {
                if case .standardError(let output) = event { standardError.append(output) }
                if case .terminated(let exitCode) = event, exitCode != 0 {
                    onEvent(event)
                    throw CLIError.nonZeroExit(
                        invocation: ProcessContainerCLI.displayInvocation(
                            executable: "container",
                            arguments: ContainerCommand.build(configuration).arguments
                        ),
                        exitCode: exitCode,
                        standardError: standardError
                    )
                }
                onEvent(event)
            }
            await refreshImages()
            selectedImageID = images.first { $0.reference == configuration.tag.rawValue }?.id
        } catch {
            failureLog.record(operation: "Build image", error: error)
            throw error
        }
    }

    func reconcileAfterCancelledBuild() async {
        await refreshImages()
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

            try Task.checkCancellation()
            await refreshContainers()
            if imageService != nil {
                await refreshImages()
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch CLIError.cancelled {
            throw CLIError.cancelled
        } catch {
            failureLog.record(operation: "Run container", error: error)
            throw error
        }
        selectNewContainer(configuration: configuration, standardOutput: standardOutput)
    }

    func reconcileAfterCancelledRun() async {
        await Task { @MainActor in
            await refreshContainers()
            if imageService != nil {
                await refreshImages()
            }
        }.value
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

private struct ImageDeletionDependencySnapshot: Equatable {
    let id: String
    let state: ContainerState
    let image: String?
    let imageDigest: String?
}

private struct ImageCleanupError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
