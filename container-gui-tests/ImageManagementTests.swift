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

    func testCLIServiceFormatsInspectionAndUsesSelectedReference() async throws {
        let reference = "ghcr.io/example/app:1.0"
        let validatedReference = try ImageReference(validating: reference)
        let cli = ImageCLIStub(output: #"{"z":1,"a":{"value":true}}"#)
        let service = CLIImageService(cli: cli)

        let inspection = try await service.inspectImage(reference: reference)
        let commands = await cli.commands

        XCTAssertEqual(commands, [.inspectImage(reference: validatedReference)])
        XCTAssertTrue(inspection.contains("\n"))
        let aIndex = try XCTUnwrap(inspection.range(of: "\"a\"")).lowerBound
        let zIndex = try XCTUnwrap(inspection.range(of: "\"z\"")).lowerBound
        XCTAssertLessThan(aIndex, zIndex)
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
        XCTAssertEqual(
            model.imageInspectionState,
            .loaded(#"{"reference":"docker.io/library/alpine:3.21"}"#)
        )
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
        var events: [ProcessEvent] = []

        try await model.pullImage(reference: "alpine:3.21") {
            events.append($0)
        }
        let listCallCount = await service.listCallCount

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(model.images.map(\.reference), ["alpine:3.21"])
        XCTAssertEqual(listCallCount, 1)
    }

    func testPullNonzeroExitSurfacesProgressError() async {
        let service = ImageServiceStub(
            pullEvents: [
                .standardError("registry denied the request"),
                .terminated(exitCode: 19),
            ]
        )
        let model = AppModel(setup: SetupModel(), imageService: service)

        do {
            try await model.pullImage(reference: "private.example/app:1") { _ in }
            XCTFail("Expected pull failure")
        } catch let error as CLIError {
            guard case .nonZeroExit(_, let exitCode, let standardError, _) = error else {
                return XCTFail("Unexpected CLI error: \(error)")
            }
            XCTAssertEqual(exitCode, 19)
            XCTAssertEqual(standardError, "registry denied the request")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteRefreshesAndPreservesConflictMessage() async {
        let conflict = CLIError.nonZeroExit(
            invocation: "container image delete alpine:3.21",
            exitCode: 1,
            standardError: "image is in use by container web"
        )
        let service = ImageServiceStub(
            images: [makeImage(reference: "alpine:3.21")],
            deletionError: conflict
        )
        let model = AppModel(setup: SetupModel(), imageService: service)
        await model.refreshImages()

        await model.deleteImage(reference: "alpine:3.21")
        let deletedReferences = await service.deletedReferences
        let listCallCount = await service.listCallCount

        XCTAssertTrue(
            model.imageDeletionFailure?.message.contains("image is in use by container web") == true
        )
        XCTAssertEqual(deletedReferences, ["alpine:3.21"])
        XCTAssertEqual(listCallCount, 2)
    }

    func testRunModelAcceptsSelectedImageAsDefault() {
        let model = RunContainerModel(image: "docker.io/library/alpine:3.21")

        XCTAssertEqual(model.image, "docker.io/library/alpine:3.21")
        XCTAssertNotNil(model.configuration)
    }

    private func makeImage(
        reference: String,
        architecture: String = "arm64"
    ) -> ImageSummary {
        let data = Data(
            """
            [{
              "reference": "\(reference)",
              "platform": { "os": "linux", "architecture": "\(architecture)" }
            }]
            """.utf8
        )
        return try! JSONDecoder()
            .decode([ImageDTO].self, from: data)
            .compactMap(ImageSummary.init(dto:))
            .first!
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
    private let imagesResult: [ImageSummary]
    private let pullEvents: [ProcessEvent]
    private let deletionError: CLIError?
    private(set) var listCallCount = 0
    private(set) var deletedReferences: [String] = []

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

    func inspectImage(reference: String) -> String {
        #"{"reference":"\#(reference)"}"#
    }

    nonisolated func pullImage(
        reference: String
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let events = self.pullEvents
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func deleteImage(reference: String) throws {
        deletedReferences.append(reference)
        if let deletionError {
            throw deletionError
        }
    }
}
