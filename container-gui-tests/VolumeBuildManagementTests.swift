import Foundation
import XCTest
@testable import Container_GUI

final class VolumeBuildCommandTests: XCTestCase {
    func testVolumeCommandsAndConfiguration() throws {
        let configuration = try VolumeCreateConfiguration(
            name: "project-data",
            labels: [try VolumeKeyValue(key: "owner", value: "app team")],
            options: [try VolumeKeyValue(key: "journal", value: "ordered")],
            size: "10G"
        )
        let name = try VolumeName(validating: "project-data")

        XCTAssertEqual(ContainerCommand.listVolumes.arguments, ["volume", "list", "--format", "json"])
        XCTAssertEqual(ContainerCommand.inspectVolume(name: name).arguments, ["volume", "inspect", "project-data"])
        XCTAssertEqual(ContainerCommand.deleteVolume(name: name).arguments, ["volume", "delete", "project-data"])
        XCTAssertEqual(ContainerCommand.pruneVolumes.arguments, ["volume", "prune"])
        XCTAssertEqual(
            ContainerCommand.createVolume(configuration: configuration).arguments,
            [
                "volume", "create",
                "--label", "owner=app team",
                "--opt", "journal=ordered",
                "-s", "10G",
                "project-data",
            ]
        )
    }

    func testBuildCommandCoversSupportedV1OptionsAndRequiresTag() throws {
        XCTAssertThrowsError(try BuildConfiguration(tag: "", contextDirectory: "/tmp/project"))
        let configuration = try BuildConfiguration(
            tag: "example/app:dev",
            contextDirectory: "/tmp/project folder",
            dockerfile: "/tmp/project folder/Dockerfile.dev",
            buildArguments: [try BuildKeyValue(key: "VERSION", value: "1.2.3")],
            labels: [try BuildKeyValue(key: "team", value: "platform")],
            noCache: true,
            target: "release",
            platform: "linux/arm64/v8",
            operatingSystem: "ignored",
            architecture: "ignored",
            cpuLimit: "2.5",
            memoryLimit: "4G",
            output: try BuildOutput(type: .tar, destination: "/tmp/app.tar"),
            pull: true
        )

        XCTAssertEqual(
            ContainerCommand.build(configuration).arguments,
            [
                "build", "--tag", "example/app:dev",
                "--file", "/tmp/project folder/Dockerfile.dev",
                "--build-arg", "VERSION=1.2.3",
                "--label", "team=platform",
                "--no-cache", "--target", "release",
                "--platform", "linux/arm64/v8",
                "--cpus", "2.5", "--memory", "4G",
                "--output", "type=tar,dest=/tmp/app.tar",
                "--pull", "--progress", "plain", "/tmp/project folder",
            ]
        )
    }

    func testBuilderCommandsAndTolerantStatus() throws {
        let configuration = try BuilderStartConfiguration(cpuLimit: "3", memoryLimit: "6G")
        XCTAssertEqual(
            ContainerCommand.builderStart(configuration: configuration).arguments,
            ["builder", "start", "--cpus", "3", "--memory", "6G"]
        )
        XCTAssertEqual(ContainerCommand.builderStatus.arguments, ["builder", "status", "--format", "json"])
        XCTAssertEqual(ContainerCommand.builderStop.arguments, ["builder", "stop"])
        XCTAssertEqual(ContainerCommand.builderDelete.arguments, ["builder", "delete"])

        XCTAssertEqual(try BuilderStatus.decode(from: Data("[]".utf8)), .absent)
        let current = try BuilderStatus.decode(from: Data(#"[{"id":"buildkit","configuration":{"image":{"reference":"builder:1"}},"status":{"state":"running","address":"192.168.64.2"}}]"#.utf8))
        XCTAssertEqual(current.state, .running)
        XCTAssertEqual(current.id, "buildkit")
        XCTAssertEqual(current.image, "builder:1")
        XCTAssertEqual(current.address, "192.168.64.2")
    }

    func testRunMountsSerializeBeforePortsAndRejectDuplicateTargets() throws {
        let volume = try ContainerMount(volumeName: "project-data", target: "/data")
        let host = try ContainerMount(hostPath: "/tmp/project folder", target: "/workspace", isReadOnly: true)
        let port = try PortMapping(hostPort: 8_080, containerPort: 80)
        let configuration = try RunConfiguration(
            image: "alpine:3.21",
            mounts: [volume, host],
            ports: [port]
        )

        XCTAssertEqual(
            configuration.arguments,
            [
                "run", "--progress", "plain", "--detach",
                "--mount", "type=volume,source=project-data,target=/data",
                "--mount", "type=bind,source=/tmp/project folder,target=/workspace,readonly",
                "--publish", "8080:80",
                "alpine:3.21",
            ]
        )
        XCTAssertThrowsError(try RunConfiguration(
            image: "alpine:3.21",
            mounts: [volume, try ContainerMount(hostPath: "/tmp/other", target: "/data")]
        ))
    }

    func testVolumePruneDropsOnlyTheLocalizedSummaryLine() {
        XCTAssertEqual(
            CLIVolumeService.prunedVolumeNames(
                from: "Reclaimed 2,3 MB in disk space\nfirst\nsecond\n"
            ),
            ["first", "second"]
        )
    }
}

@MainActor
final class VolumeBuildModelTests: XCTestCase {
    func testVolumeModelCreatesSelectsAndPrunes() async throws {
        let service = VolumeServiceStub()
        let model = VolumeModel(service: service)
        await model.refresh()
        XCTAssertEqual(model.volumes.map(\.name), ["existing"])

        let configuration = try VolumeCreateConfiguration(name: "created")
        let created = await model.create(configuration)
        XCTAssertTrue(created)
        XCTAssertEqual(model.selectedVolume?.name, "created")

        await model.prune()
        XCTAssertEqual(model.lastPruneResult, ["existing", "created"])
        XCTAssertTrue(model.volumes.isEmpty)
    }

    func testRunDraftValidatesNamedAndHostMounts() async {
        let service = VolumeServiceStub()
        let volumeModel = VolumeModel(service: service)
        await volumeModel.refresh()
        let model = RunContainerModel(image: "alpine:3.21", volumeModel: volumeModel)
        model.mounts = [
            ContainerMountDraft(kind: .volume, source: "existing", target: "/data"),
            ContainerMountDraft(kind: .hostPath, source: "/tmp/project", target: "/source", isReadOnly: true),
        ]

        XCTAssertNil(model.mountError(for: model.mounts[0]))
        XCTAssertEqual(model.configuration?.mounts.count, 2)
        XCTAssertTrue(model.commandPreview.contains("type=volume"))
        XCTAssertTrue(model.commandPreview.contains("type=bind"))

        model.mounts[0].source = "missing"
        XCTAssertNil(model.configuration)
        XCTAssertNotNil(model.mountError(for: model.mounts[0]))
    }

    func testImageBuildStreamsAndRefreshesImages() async {
        let builder = ImageBuilderStub()
        let imageService = BuiltImageService()
        let appModel = AppModel(
            setup: SetupModel(),
            imageService: imageService,
            imageBuilder: builder
        )
        let model = ImageBuildModel()
        model.tag = "example/app:built"
        model.contextDirectory = "/tmp/project"
        let outcome = await model.build(using: appModel)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(model.progress.contains("building"))
        let listCount = await imageService.currentListCount()
        XCTAssertEqual(listCount, 1)
        XCTAssertEqual(builder.configurations.count, 1)
    }

    func testBuilderLifecycleRefreshesAuthoritativeStatus() async {
        let service = BuilderServiceStub()
        let model = BuilderModel(service: service)
        await model.refresh()
        XCTAssertEqual(model.status.state, .absent)
        await model.start(cpuLimit: "2", memoryLimit: "4G")
        XCTAssertEqual(model.status.state, .running)
        await model.stop()
        XCTAssertEqual(model.status.state, .stopped)
        await model.delete()
        XCTAssertEqual(model.status.state, .absent)
    }
}

private actor VolumeServiceStub: VolumeManaging {
    private var names = ["existing"]

    func listVolumes() throws -> [VolumeSummary] { try names.map(makeSummary) }

    func inspectVolume(name: String) throws -> VolumeInspection {
        let raw = json(name)
        return VolumeInspection(
            dto: try JSONDecoder().decode(VolumeDTO.self, from: Data(raw.utf8)),
            rawJSON: raw
        )!
    }

    func createVolume(_ configuration: VolumeCreateConfiguration) {
        names.append(configuration.name.rawValue)
    }

    func deleteVolume(name: String) { names.removeAll { $0 == name } }

    func pruneVolumes() -> [String] {
        let deleted = names
        names.removeAll()
        return deleted
    }

    private func makeSummary(_ name: String) throws -> VolumeSummary {
        let dto = try JSONDecoder().decode(VolumeDTO.self, from: Data(json(name).utf8))
        return VolumeSummary(dto: dto)!
    }

    private func json(_ name: String) -> String {
        #"{"id":"\#(name)","configuration":{"name":"\#(name)","driver":"local","sizeInBytes":1048576}}"#
    }
}

nonisolated private final class ImageBuilderStub: ImageBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BuildConfiguration] = []
    var configurations: [BuildConfiguration] { lock.withLock { stored } }

    func buildImage(_ configuration: BuildConfiguration) -> AsyncThrowingStream<ProcessEvent, Error> {
        lock.withLock { stored.append(configuration) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.standardError("building\n"))
            continuation.yield(.terminated(exitCode: 0))
            continuation.finish()
        }
    }
}

private actor BuiltImageService: ImageManaging {
    private(set) var listCount = 0
    func listImages() -> [ImageSummary] { listCount += 1; return [] }
    func inspectImage(reference: String) throws -> ImageInspection {
        throw CLIError.invalidOutput(description: "unused")
    }
    nonisolated func pullImage(reference: String) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func deleteImage(reference: String) {}
    func currentListCount() -> Int { listCount }
}

private actor BuilderServiceStub: BuilderManaging {
    private var state: BuilderState = .absent
    func status() -> BuilderStatus { BuilderStatus(state: state, id: nil, image: nil, address: nil) }
    func start(_ configuration: BuilderStartConfiguration) { state = .running }
    func stop() { state = .stopped }
    func delete() { state = .absent }
}
