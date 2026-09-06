import Foundation
import XCTest
@testable import Container_GUI

@MainActor
final class ImageManagementTests: XCTestCase {
    func testCLIServiceListsImagesWithAuthoritativeCommand() async throws {
        let cli = ImageCLIStub(output: """
            [{
              "reference": "docker.io/library/alpine:3.21",
              "digest": "sha256:abc",
              "size": 8100000,
              "platform": { "os": "linux", "architecture": "arm64" }
            }]
            """)
        let service = CLIImageService(cli: cli)

        let images = try await service.listImages()
        let commands = await cli.commands

        XCTAssertEqual(commands, [.listImages])
        XCTAssertEqual(images.map(\.reference), ["docker.io/library/alpine:3.21"])
        XCTAssertEqual(images.first?.architecture, "arm64")
    }

    func testCLIServiceDecodesInspectionAndUsesSelectedReference() async throws {
        let reference = "ghcr.io/example/app:1.0"
        let validatedReference = try ImageReference(validating: reference)
        let output = #"[{"name":"ghcr.io/example/app:1.0","index":{"digest":"sha256:index","size":123,"mediaType":"application/vnd.oci.image.index.v1+json"},"variants":[]}]"#
        let cli = ImageCLIStub(output: output)
        let service = CLIImageService(cli: cli)

        let inspection = try await service.inspectImage(reference: reference)
        let commands = await cli.commands

        XCTAssertEqual(commands, [.inspectImage(reference: validatedReference)])
        XCTAssertEqual(inspection.reference, reference)
        XCTAssertEqual(inspection.descriptor?.digest, "sha256:index")
        XCTAssertEqual(inspection.rawJSON, output)
    }

    func testCLIServiceRejectsEmptyInspectionObject() async {
        let service = CLIImageService(cli: ImageCLIStub(output: "[{\"configuration\":{},\"descriptor\":{},\"variants\":[]}]"))

        do {
            _ = try await service.inspectImage(reference: "alpine:3.21")
            XCTFail("Expected an empty inspection object to fail.")
        } catch let error as CLIError {
            guard case .invalidOutput(let description) = error else {
                return XCTFail("Unexpected CLI error: \(error)")
            }
            XCTAssertEqual(description, "Image inspection returned no entries.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshSelectionSearchAndInspectionCompose() async {
        let service = ImageServiceStub(images: [
            makeImage(reference: "docker.io/library/alpine:3.21", architecture: "arm64"),
            makeImage(reference: "ghcr.io/example/web:2.0", architecture: "amd64"),
        ])
        let model = AppModel(setup: SetupModel(), imageService: service)

        await model.refreshImages()
        model.imageSearchText = "alpine"
        model.selectedImageID = "docker.io/library/alpine:3.21"
        await model.inspectSelectedImage()

        XCTAssertEqual(model.filteredImages.map(\.reference), ["docker.io/library/alpine:3.21"])
        guard case .loaded(let inspection) = model.imageInspectionState else {
            return XCTFail("Expected typed image inspection.")
        }
        XCTAssertEqual(inspection.reference, "docker.io/library/alpine:3.21")
    }

    func testPullStreamsProgressAndRefreshesImages() async throws {
        let service = ImageServiceStub(
            images: [makeImage(reference: "alpine:3.21")],
            pullEvents: [
                .standardError("downloading\n"),
                .standardOutput("unpacking\n"),
                .terminated(exitCode: 0),
            ]
        )
        let model = AppModel(setup: SetupModel(), imageService: service)
        let configuration = try ImagePullConfiguration(reference: "alpine:3.21")

        model.startImageOperation(.pull(configuration))
        try await waitForOperation(model)

        XCTAssertEqual(model.imageOperations.activity?.state, .succeeded)
        XCTAssertEqual(model.images.map(\.reference), ["alpine:3.21"])
        let pulls = await service.pullConfigurations
        XCTAssertEqual(pulls, [configuration])
    }

    func testPullActivityParsesProgressAndFallsBackToLatestLine() async throws {
        let service = ImageServiceStub(
            images: [makeImage(reference: "alpine:3.21")],
            pullEvents: [
                .standardError("unpacking layers 3/7\n"),
                .terminated(exitCode: 0),
            ]
        )
        let model = AppModel(setup: SetupModel(), imageService: service)

        model.startImageOperation(.pull(try ImagePullConfiguration(reference: "alpine:3.21")))
        try await waitForOperation(model)

        let activity = try XCTUnwrap(model.imageOperations.activity)
        XCTAssertEqual(activity.label, "unpacking layers 3/7")
        XCTAssertEqual(activity.state, .succeeded)
    }

    func testPullNonzeroExitSurfacesSanitizedFailure() async throws {
        let service = ImageServiceStub(
            pullEvents: [
                .standardError("registry denied the request"),
                .terminated(exitCode: 19),
            ]
        )
        let model = AppModel(setup: SetupModel(), imageService: service)

        model.startImageOperation(
            .pull(try ImagePullConfiguration(reference: "private.example/app:1"))
        )
        try await waitForOperation(model)

        let activity = try XCTUnwrap(model.imageOperations.activity)
        guard case .failed(let message) = activity.state else {
            return XCTFail("Expected a failed pull, got \(activity.state)")
        }
        XCTAssertTrue(message.contains("19"), message)
        XCTAssertTrue(message.contains("registry denied the request"), message)
    }

    func testOnlyOneImageOperationRunsAtATime() async throws {
        let service = ImageServiceStub(images: [makeImage(reference: "alpine:3.21")])
        let model = AppModel(setup: SetupModel(), imageService: service)

        let first = model.startImageOperation(
            .pull(try ImagePullConfiguration(reference: "alpine:3.21"))
        )
        let second = model.startImageOperation(
            .pull(try ImagePullConfiguration(reference: "busybox:1"))
        )

        XCTAssertTrue(first)
        XCTAssertFalse(second, "A second operation must not start while one is running.")
        try await waitForOperation(model)
    }

    func testPushAndSaveDoNotRefreshTheLocalImageList() async throws {
        let service = ImageServiceStub(images: [makeImage(reference: "alpine:3.21")])
        let model = AppModel(setup: SetupModel(), imageService: service)
        await model.refreshImages()
        let baseline = await service.listCallCount

        model.startImageOperation(
            .push(try ImagePushConfiguration(reference: "ghcr.io/example/app:1"))
        )
        try await waitForOperation(model)

        let afterPush = await service.listCallCount
        XCTAssertEqual(afterPush, baseline, "Push does not mutate the local inventory.")

        model.imageOperations.dismiss()
        model.startImageOperation(
            .save(try ImageSaveConfiguration(
                references: ["alpine:3.21"],
                output: "/tmp/images.tar"
            ))
        )
        try await waitForOperation(model)

        let afterSave = await service.listCallCount
        XCTAssertEqual(afterSave, baseline, "Save does not mutate the local inventory.")
    }

    func testLoadRefreshesImagesBecauseItMutatesTheInventory() async throws {
        let service = ImageServiceStub(images: [makeImage(reference: "alpine:3.21")])
        let model = AppModel(setup: SetupModel(), imageService: service)
        await model.refreshImages()
        let baseline = await service.listCallCount

        model.startImageOperation(
            .load(try ImageLoadConfiguration(input: "/tmp/images.tar"))
        )
        try await waitForOperation(model)

        let afterLoad = await service.listCallCount
        XCTAssertGreaterThan(afterLoad, baseline)
    }

    func testTagAddsTheTargetAndSelectsIt() async throws {
        let service = ImageServiceStub(images: [makeImage(reference: "alpine:3.21")])
        let model = AppModel(setup: SetupModel(), imageService: service)
        await model.refreshImages()

        let configuration = try ImageTagConfiguration(
            source: "alpine:3.21",
            target: "ghcr.io/example/alpine:3.21"
        )
        let failure = await model.tagImage(configuration)

        XCTAssertNil(failure)
        let tags = await service.tagConfigurations
        XCTAssertEqual(tags, [configuration])
        XCTAssertEqual(model.selectedImageID, "ghcr.io/example/alpine:3.21")
    }

    func testBulkDeleteSendsOneConfigurationForEverySelectedImage() async throws {
        let service = ImageServiceStub(images: [
            makeImage(reference: "alpine:3.21"),
            makeImage(reference: "busybox:1"),
        ])
        let model = AppModel(setup: SetupModel(), imageService: service)
        await model.refreshImages()

        let configuration = try ImageDeleteConfiguration(
            references: ["alpine:3.21", "busybox:1"]
        )
        model.startImageOperation(.delete(configuration))
        try await waitForOperation(model)

        let configurations = await service.deleteConfigurations
        XCTAssertEqual(configurations, [configuration])
        XCTAssertTrue(model.images.isEmpty)
    }

    func testPruneForwardsTheChosenScope() async throws {
        let service = ImageServiceStub(images: [makeImage(reference: "alpine:3.21")])
        let model = AppModel(setup: SetupModel(), imageService: service)

        model.startImageOperation(.prune(all: true))
        try await waitForOperation(model)

        let flags = await service.pruneAllFlags
        XCTAssertEqual(flags, [true])
    }

    /// Regression: `isBusy` tracks the task, and the task retires itself by
    /// comparing a run token. Comparing the *activity* instead would leave the
    /// handle behind — and the screen permanently busy — whenever the user
    /// dismissed the finished row before reconciliation had returned.
    func testDismissingAFinishedOperationDoesNotWedgeTheScreenBusy() async throws {
        let service = ImageServiceStub(images: [makeImage(reference: "alpine:3.21")])
        let model = AppModel(setup: SetupModel(), imageService: service)

        model.startImageOperation(.prune(all: false))
        try await waitForOperation(model)
        model.imageOperations.dismiss()

        XCTAssertNil(model.imageOperations.activity)
        XCTAssertFalse(
            model.imageOperations.isBusy,
            "A dismissed, finished operation must leave the screen able to start another."
        )
        XCTAssertTrue(
            model.startImageOperation(.prune(all: true)),
            "A second operation must be startable after the first was dismissed."
        )
        try await waitForOperation(model)
    }

    /// The activity finishes on its own task, so the tests wait on its state
    /// rather than on the call that started it.
    private func waitForOperation(
        _ model: AppModel,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let state = model.imageOperations.activity?.state, state != .running {
                // Reconciliation runs after the state flips, so let it land.
                try await Task.sleep(for: .milliseconds(20))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The image operation did not finish within \(timeout).")
    }

    func testDeletionPlanFindsOnlyContainersUsingSelectedReference() async throws {
        let image = makeImage(reference: "alpine:3.21")
        let service = ImageServiceStub(images: [image])
        let store = ImageContainerStore(containers: [
            makeContainer(id: "web", image: "alpine:3.21", state: "running"),
            makeContainer(id: "db", image: "postgres:17", state: "stopped"),
        ])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()

        let preparedPlan = await model.prepareImageDeletion(reference: image.reference)
        let plan = try XCTUnwrap(preparedPlan)

        XCTAssertEqual(plan.dependentContainers.map(\.id), ["web"])
        XCTAssertTrue(plan.blockedContainers.isEmpty)
    }

    func testDeletionPlanUsesDigestToAvoidRepointedTag() async throws {
        let image = makeImage(reference: "example/app:latest", digest: "sha256:new")
        let service = ImageServiceStub(images: [image])
        let store = ImageContainerStore(containers: [
            makeContainer(
                id: "old-release",
                image: image.reference,
                imageDigest: "sha256:old",
                state: "stopped"
            ),
        ])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()

        let preparedPlan = await model.prepareImageDeletion(reference: image.reference)
        let plan = try XCTUnwrap(preparedPlan)

        XCTAssertTrue(plan.dependentContainers.isEmpty)
    }

    func testCleanupDeletesStoppedAndRunningDependenciesBeforeImage() async throws {
        let image = makeImage(reference: "alpine:3.21", digest: "sha256:alpine")
        let service = ImageServiceStub(images: [image])
        let store = ImageContainerStore(containers: [
            makeContainer(
                id: "api",
                image: image.reference,
                imageDigest: image.digest,
                state: "running"
            ),
            makeContainer(
                id: "worker",
                image: image.reference,
                imageDigest: image.digest,
                state: "stopped"
            ),
        ])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()
        let preparedPlan = await model.prepareImageDeletion(reference: image.reference)
        let plan = try XCTUnwrap(preparedPlan)

        await model.deleteImage(using: plan)

        let mutations = await store.recordedMutations
        let deletedReferences = await service.deletedReferences
        XCTAssertEqual(mutations.map(\.containerID), ["api", "worker"])
        XCTAssertEqual(mutations.map(\.mutation), [
            .delete(force: true),
            .delete(force: false),
        ])
        XCTAssertEqual(deletedReferences, ["sha256:alpine"])
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertNil(model.imageDeletionFailure)
    }

    func testCleanupRejectsChangedDependenciesBeforeDeletingAnything() async throws {
        let image = makeImage(reference: "alpine:3.21", digest: "sha256:alpine")
        let service = ImageServiceStub(images: [image])
        let store = ImageContainerStore(containers: [
            makeContainer(
                id: "web",
                image: image.reference,
                imageDigest: image.digest,
                state: "stopped"
            ),
        ])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()
        let preparedPlan = await model.prepareImageDeletion(reference: image.reference)
        let plan = try XCTUnwrap(preparedPlan)
        await store.add(makeContainer(
            id: "new",
            image: image.reference,
            imageDigest: image.digest,
            state: "running"
        ))

        await model.deleteImage(using: plan)

        let mutations = await store.recordedMutations
        let deletedReferences = await service.deletedReferences
        XCTAssertTrue(
            model.imageDeletionFailure?.message.contains("Dependent containers changed") == true
        )
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertTrue(deletedReferences.isEmpty)
    }

    func testCleanupRejectsImageRepointedAfterConfirmation() async throws {
        let reference = "example/app:latest"
        let original = makeImage(reference: reference, digest: "sha256:old")
        let replacement = makeImage(reference: reference, digest: "sha256:new")
        let service = ImageServiceStub(images: [original])
        let store = ImageContainerStore(containers: [
            makeContainer(
                id: "old-release",
                image: reference,
                imageDigest: original.digest,
                state: "stopped"
            ),
        ])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()
        let preparedPlan = await model.prepareImageDeletion(reference: reference)
        let plan = try XCTUnwrap(preparedPlan)
        await service.setImages([replacement])

        await model.deleteImage(using: plan)

        let mutations = await store.recordedMutations
        let deletedReferences = await service.deletedReferences
        XCTAssertEqual(model.imageDeletionFailure?.message, "The image changed. Review the deletion again.")
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertTrue(deletedReferences.isEmpty)
    }

    func testCleanupStopsAfterPartialFailureAndPreservesImage() async throws {
        let image = makeImage(reference: "alpine:3.21", digest: "sha256:alpine")
        let service = ImageServiceStub(images: [image])
        let store = ImageContainerStore(
            containers: [
                makeContainer(
                    id: "a-done",
                    image: image.reference,
                    imageDigest: image.digest,
                    state: "stopped"
                ),
                makeContainer(
                    id: "b-fails",
                    image: image.reference,
                    imageDigest: image.digest,
                    state: "running"
                ),
            ],
            failingContainerID: "b-fails"
        )
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()
        let preparedPlan = await model.prepareImageDeletion(reference: image.reference)
        let plan = try XCTUnwrap(preparedPlan)

        await model.deleteImage(using: plan)

        let deletedReferences = await service.deletedReferences
        let containerIDs = await store.containerIDs
        XCTAssertTrue(
            model.imageDeletionFailure?.message.contains("1 dependent container(s) were deleted")
                == true
        )
        XCTAssertTrue(model.imageDeletionFailure?.message.contains("b-fails") == true)
        XCTAssertTrue(deletedReferences.isEmpty)
        XCTAssertEqual(containerIDs, ["b-fails"])
    }

    func testCleanupReportsDeletedContainersWhenFinalImageDeleteFails() async throws {
        let image = makeImage(reference: "alpine:3.21", digest: "sha256:alpine")
        let deletionError = CLIError.nonZeroExit(
            invocation: "container image delete alpine:3.21",
            exitCode: 1,
            standardError: "image store rejected deletion"
        )
        let service = ImageServiceStub(images: [image], deletionError: deletionError)
        let store = ImageContainerStore(containers: [
            makeContainer(
                id: "removed",
                image: image.reference,
                imageDigest: image.digest,
                state: "stopped"
            ),
        ])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()
        let preparedPlan = await model.prepareImageDeletion(reference: image.reference)
        let plan = try XCTUnwrap(preparedPlan)

        await model.deleteImage(using: plan)

        let containerIDs = await store.containerIDs
        XCTAssertTrue(
            model.imageDeletionFailure?.message.contains("1 dependent container(s) were deleted")
                == true
        )
        XCTAssertTrue(
            model.imageDeletionFailure?.message.contains("image store rejected deletion") == true
        )
        XCTAssertTrue(containerIDs.isEmpty)
        XCTAssertEqual(model.images.map(\.reference), [image.reference])
    }

    func testCleanupBlocksImageWithoutStableDigest() async throws {
        let image = makeImage(reference: "legacy/image:latest")
        let service = ImageServiceStub(images: [image])
        let store = ImageContainerStore(containers: [])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()
        let preparedPlan = await model.prepareImageDeletion(reference: image.reference)
        let plan = try XCTUnwrap(preparedPlan)

        await model.deleteImage(using: plan)

        let deletedReferences = await service.deletedReferences
        XCTAssertTrue(model.imageDeletionFailure?.message.contains("no stable digest") == true)
        XCTAssertTrue(deletedReferences.isEmpty)
    }

    func testCleanupBlocksUnresolvedContainerWithDifferentReference() async throws {
        let image = makeImage(reference: "legacy/image:latest", digest: "sha256:current")
        let service = ImageServiceStub(images: [image])
        let store = ImageContainerStore(containers: [
            makeContainer(id: "legacy", image: "alias/image:old", state: "stopped"),
        ])
        let model = AppModel(
            setup: SetupModel(),
            containerLister: store,
            containerMutator: store,
            imageService: service
        )
        await model.refreshImages()
        let preparedPlan = await model.prepareImageDeletion(reference: image.reference)
        let plan = try XCTUnwrap(preparedPlan)

        XCTAssertEqual(plan.unresolvedContainers.map(\.id), ["legacy"])
        await model.deleteImage(using: plan)

        let deletedReferences = await service.deletedReferences
        let mutations = await store.recordedMutations
        XCTAssertTrue(
            model.imageDeletionFailure?.message.contains("do not report stable image digests") == true
        )
        XCTAssertTrue(deletedReferences.isEmpty)
        XCTAssertTrue(mutations.isEmpty)
    }

    func testRunModelAcceptsSelectedImageAsDefault() {
        let model = RunContainerModel(image: "docker.io/library/alpine:3.21")

        XCTAssertEqual(model.image, "docker.io/library/alpine:3.21")
        XCTAssertNotNil(model.configuration)
    }

    private func makeImage(
        reference: String,
        digest: String? = nil,
        architecture: String = "arm64"
    ) -> ImageSummary {
        let digestField = digest.map { #", "digest": "\#($0)""# } ?? ""
        let data = Data(
            """
            [{
              "reference": "\(reference)"\(digestField),
              "platform": { "os": "linux", "architecture": "\(architecture)" }
            }]
            """.utf8
        )
        return try! JSONDecoder()
            .decode([ImageDTO].self, from: data)
            .compactMap(ImageSummary.init(dto:))
            .first!
    }

    private func makeContainer(
        id: String,
        image: String,
        imageDigest: String? = nil,
        state: String
    ) -> ContainerSummary {
        let digestField = imageDigest.map { #", "digest": "\#($0)""# } ?? ""
        let json = """
            {
              "configuration": {
                "id": "\(id)",
                "image": { "reference": "\(image)"\(digestField) },
                "platform": { "architecture": "arm64" }
              },
              "status": { "state": "\(state)" }
            }
            """
        let dto = try! JSONDecoder().decode(ContainerDTO.self, from: Data(json.utf8))
        return ContainerSummary(dto: dto)!
    }
}

private actor ImageCLIStub: ContainerCLI {
    let output: String
    private(set) var commands: [ContainerCommand] = []

    init(output: String) {
        self.output = output
    }

    func run(_ command: ContainerCommand) async throws -> CommandResult {
        commands.append(command)
        return CommandResult(
            standardOutput: output,
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: "container"
        )
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor ImageServiceStub: ImageManaging {
    private var imagesResult: [ImageSummary]
    private let pullEvents: [ProcessEvent]
    private let deletionError: CLIError?
    private(set) var listCallCount = 0
    private(set) var deletedReferences: [String] = []
    private(set) var deleteConfigurations: [ImageDeleteConfiguration] = []
    private(set) var tagConfigurations: [ImageTagConfiguration] = []
    private(set) var pullConfigurations: [ImagePullConfiguration] = []
    private(set) var pushConfigurations: [ImagePushConfiguration] = []
    private(set) var saveConfigurations: [ImageSaveConfiguration] = []
    private(set) var loadConfigurations: [ImageLoadConfiguration] = []
    private(set) var pruneAllFlags: [Bool] = []

    init(
        images: [ImageSummary] = [],
        pullEvents: [ProcessEvent] = [],
        deletionError: CLIError? = nil
    ) {
        imagesResult = images
        self.pullEvents = pullEvents
        self.deletionError = deletionError
    }

    func listImages() -> [ImageSummary] {
        listCallCount += 1
        return imagesResult
    }

    func inspectImage(reference: String) throws -> ImageInspection {
        let rawJSON = #"{"reference":"\#(reference)"}"#
        let dto = try JSONDecoder().decode(ImageDTO.self, from: Data(rawJSON.utf8))
        return ImageInspection(dto: dto, fallbackReference: reference, rawJSON: rawJSON)!
    }

    nonisolated func pullImage(
        _ configuration: ImagePullConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordPull(configuration)
                for event in await self.pullEventList {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    nonisolated func pushImage(
        _ configuration: ImagePushConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordPush(configuration)
                continuation.yield(.terminated(exitCode: 0))
                continuation.finish()
            }
        }
    }

    func tagImage(_ configuration: ImageTagConfiguration) throws {
        tagConfigurations.append(configuration)
        if let deletionError { throw deletionError }
        if let source = imagesResult.first(where: {
            $0.reference == configuration.source.rawValue
        }) {
            imagesResult.append(source.renamed(to: configuration.target.rawValue))
        }
    }

    nonisolated func saveImages(
        _ configuration: ImageSaveConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordSave(configuration)
                continuation.yield(.terminated(exitCode: 0))
                continuation.finish()
            }
        }
    }

    nonisolated func loadImages(
        _ configuration: ImageLoadConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordLoad(configuration)
                continuation.yield(.terminated(exitCode: 0))
                continuation.finish()
            }
        }
    }

    nonisolated func deleteImages(
        _ configuration: ImageDeleteConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.applyDelete(configuration)
                    continuation.yield(.terminated(exitCode: 0))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated func pruneImages(all: Bool) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordPrune(all)
                continuation.yield(.terminated(exitCode: 0))
                continuation.finish()
            }
        }
    }

    func setImages(_ images: [ImageSummary]) {
        imagesResult = images
    }

    private var pullEventList: [ProcessEvent] { pullEvents }

    private func recordPull(_ configuration: ImagePullConfiguration) {
        pullConfigurations.append(configuration)
    }

    private func recordPush(_ configuration: ImagePushConfiguration) {
        pushConfigurations.append(configuration)
    }

    private func recordSave(_ configuration: ImageSaveConfiguration) {
        saveConfigurations.append(configuration)
    }

    private func recordLoad(_ configuration: ImageLoadConfiguration) {
        loadConfigurations.append(configuration)
    }

    private func recordPrune(_ all: Bool) {
        pruneAllFlags.append(all)
    }

    private func applyDelete(_ configuration: ImageDeleteConfiguration) throws {
        deleteConfigurations.append(configuration)
        deletedReferences.append(contentsOf: configuration.references.map(\.rawValue))
        if let deletionError {
            throw deletionError
        }
        if configuration.all {
            imagesResult.removeAll()
            return
        }
        for reference in configuration.references.map(\.rawValue) {
            imagesResult.removeAll { image in
                image.reference == reference || image.digest == reference
            }
        }
    }
}

extension ImageSummary {
    /// The same image under a second name, which is what `image tag` produces.
    fileprivate func renamed(to reference: String) -> ImageSummary {
        let digestField = digest.map { #", "digest": "\#($0)""# } ?? ""
        let data = Data(
            """
            [{
              "reference": "\(reference)"\(digestField),
              "platform": { "os": "linux", "architecture": "arm64" }
            }]
            """.utf8
        )
        return try! JSONDecoder()
            .decode([ImageDTO].self, from: data)
            .compactMap(ImageSummary.init(dto:))
            .first!
    }
}

private actor ImageContainerStore: ContainerListing, ContainerMutating {
    struct RecordedMutation: Equatable, Sendable {
        let mutation: ContainerMutation
        let containerID: String
    }

    private var containers: [ContainerSummary]
    private let failingContainerID: String?
    private(set) var recordedMutations: [RecordedMutation] = []

    init(
        containers: [ContainerSummary],
        failingContainerID: String? = nil
    ) {
        self.containers = containers
        self.failingContainerID = failingContainerID
    }

    var containerIDs: [String] {
        containers.map(\.id).sorted()
    }

    func listContainers() -> [ContainerSummary] {
        containers
    }

    func mutate(_ mutation: ContainerMutation, containerID: String) throws {
        recordedMutations.append(RecordedMutation(mutation: mutation, containerID: containerID))
        if containerID == failingContainerID {
            throw CLIError.nonZeroExit(
                invocation: "container delete \(containerID)",
                exitCode: 1,
                standardError: "fixture deletion failed"
            )
        }
        if case .delete = mutation {
            containers.removeAll { $0.id == containerID }
        }
    }

    func add(_ container: ContainerSummary) {
        containers.append(container)
    }
}
