import Foundation
import XCTest
@testable import Container_GUI

final class CLIDecodingTests: XCTestCase {
    func testDecodesMinimumSupportedContainerFixture() throws {
        let dtos: [ContainerDTO] = try decodeFixture("0.12.0/containers-0.12.0.json")
        let containers = dtos.compactMap(ContainerSummary.init(dto:))

        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].id, "legacy-web")
        XCTAssertEqual(containers[0].image, "docker.io/library/nginx:1.27")
        XCTAssertEqual(containers[0].state, .running)
        XCTAssertEqual(containers[0].address, "192.168.64.3")
        XCTAssertEqual(containers[1].state, .unknown("future-state"))
    }

    func testDecodesCurrentContainerFixtureAndIgnoresUnknownFields() throws {
        let dtos: [ContainerDTO] = try decodeFixture("1.0.0/containers-1.0.0.json")
        let details = try XCTUnwrap(ContainerDetails(dto: XCTUnwrap(dtos.first)))

        XCTAssertEqual(details.id, "current-web")
        XCTAssertEqual(details.summary.architecture, "arm64")
        XCTAssertEqual(details.summary.imageDigest, "sha256:2222")
        XCTAssertEqual(details.summary.address, "192.168.64.4")
        XCTAssertEqual(details.networks.first?.name, "default")
        XCTAssertEqual(details.ports.first?.hostPort, 8_080)
        XCTAssertEqual(details.mounts.first?.destination, "/data")
        XCTAssertEqual(details.mounts.first?.type, "virtiofs")
        XCTAssertEqual(details.process?.environment, ["API_TOKEN=secret", "MODE=production"])
        XCTAssertEqual(details.process?.user?.processUserDescription, "1000:1000")
        XCTAssertEqual(details.resources?.storage, 8_589_934_592)
        XCTAssertEqual(details.sockets.first?.hostPath, "/tmp/service.sock")
        XCTAssertEqual(details.labels["com.example.role"], "web")
        XCTAssertEqual(details.dns?.domain, "example.test")
        XCTAssertEqual(details.capAdd, ["CAP_NET_BIND_SERVICE"])
        XCTAssertEqual(details.networks.first?.variant, "standard")
    }

    func testDecodesBothImageFixtureShapes() throws {
        let oldDTOs: [ImageDTO] = try decodeFixture("0.12.0/images-0.12.0.json")
        let newDTOs: [ImageDTO] = try decodeFixture("1.0.0/images-1.0.0.json")
        let old = try XCTUnwrap(oldDTOs.first.flatMap(ImageSummary.init(dto:)))
        let new = try XCTUnwrap(newDTOs.first.flatMap(ImageSummary.init(dto:)))

        XCTAssertEqual(old.reference, "docker.io/library/alpine:3.20")
        XCTAssertEqual(old.size, 8_100_000)
        XCTAssertEqual(new.reference, "ghcr.io/example/app:1.0")
        XCTAssertEqual(new.digest, "sha256:2222")
        XCTAssertEqual(new.size, 42_000_000)
    }

    func testDecodesBothNetworkFixtureShapesAndInspections() throws {
        let legacy: [NetworkDTO] = try decodeFixture("0.12.0/networks-0.12.0.json")
        let current: [NetworkDTO] = try decodeFixture("1.0.0/networks-1.0.0.json")
        let legacyInspectionDTO: NetworkDTO = try decodeFixture(
            "0.12.0/network-inspect-0.12.0.json"
        )
        let currentInspectionDTOs: [NetworkDTO] = try decodeFixture(
            "1.0.0/network-inspect-1.0.0.json"
        )

        let legacySummaries = legacy.compactMap(NetworkSummary.init(dto:))
        let currentSummaries = current.compactMap(NetworkSummary.init(dto:))
        XCTAssertEqual(legacySummaries.map(\.name), ["default", "legacy-fixture"])
        XCTAssertEqual(legacySummaries[1].gateway, "10.12.0.1")
        XCTAssertEqual(currentSummaries.map(\.name), ["default", "current-fixture"])
        XCTAssertEqual(currentSummaries[1].pluginOptions["isolation"], "strict")
        XCTAssertTrue(legacySummaries[0].isBuiltIn)
        XCTAssertTrue(currentSummaries[0].isBuiltIn)

        let legacyInspection = try XCTUnwrap(NetworkInspection(
            dto: legacyInspectionDTO,
            rawJSON: "legacy"
        ))
        let currentInspection = try XCTUnwrap(currentInspectionDTOs.first.flatMap {
            NetworkInspection(dto: $0, rawJSON: "current")
        })
        XCTAssertEqual(legacyInspection.legacyPluginVariant, "host")
        XCTAssertEqual(currentInspection.summary.ipv6Subnet, "fd20::/64")
    }

    func testDecodesCurrentNestedImageListShape() throws {
        let data = Data(
            #"""
            [{
              "configuration": {
                "creationDate": "2026-06-16T00:00:15Z",
                "descriptor": {
                  "digest": "sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b",
                  "mediaType": "application/vnd.oci.image.index.v1+json",
                  "size": 9218
                },
                "name": "docker.io/library/alpine:latest"
              },
              "id": "28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b",
              "variants": [{
                "digest": "sha256:e7a1a92a5bfeee40966aea60f0796b0e7917cc35591542701834f03a68fa3d18",
                "platform": { "architecture": "arm64", "os": "linux", "variant": "v8" },
                "size": 4184689
              }]
            }]
            """#.utf8
        )

        let dtos = try JSONDecoder().decode([ImageDTO].self, from: data)
        let image = try XCTUnwrap(dtos.first.flatMap(ImageSummary.init(dto:)))

        XCTAssertEqual(image.reference, "docker.io/library/alpine:latest")
        XCTAssertEqual(image.digest, "sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b")
        XCTAssertEqual(image.size, 9218)
        XCTAssertEqual(image.operatingSystem, "linux")
        XCTAssertEqual(image.architecture, "arm64")
    }

    func testDecodesLegacyImageInspectionShape() throws {
        let rawJSON = #"""
        [{
          "name": "docker.io/library/alpine:3.20",
          "index": {
            "digest": "sha256:index",
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "size": 512
          },
          "variants": [{
            "platform": {"os": "linux", "architecture": "arm64", "variant": "v8"},
            "size": 8100000,
            "config": {
              "created": "2026-04-27T10:00:00Z",
              "author": "Apple",
              "architecture": "arm64",
              "os": "linux",
              "config": {
                "User": "1000:1000",
                "Env": ["TOKEN=secret"],
                "Entrypoint": ["/bin/sh"],
                "Cmd": ["-c", "echo ready"],
                "WorkingDir": "/work",
                "Labels": {"org.example.kind": "fixture"},
                "StopSignal": "SIGTERM"
              },
              "rootfs": {"type": "layers", "diff_ids": ["sha256:layer"]},
              "history": [{"created_by": "RUN echo ready", "empty_layer": false}]
            }
          }]
        }]
        """#
        let dto = try XCTUnwrap(JSONDecoder().decode([ImageDTO].self, from: Data(rawJSON.utf8)).first)
        let inspection = try XCTUnwrap(ImageInspection(
            dto: dto,
            fallbackReference: "alpine:3.20",
            rawJSON: rawJSON
        ))

        XCTAssertEqual(inspection.reference, "docker.io/library/alpine:3.20")
        XCTAssertEqual(inspection.descriptor?.digest, "sha256:index")
        XCTAssertEqual(inspection.variants.first?.configuration?.environment, ["TOKEN=secret"])
        XCTAssertEqual(inspection.variants.first?.rootFS?.diffIDs, ["sha256:layer"])
        XCTAssertEqual(inspection.variants.first?.history.first?.createdBy, "RUN echo ready")
    }

    func testDecodesCurrentImageInspectionShape() throws {
        let rawJSON = #"""
        [{
          "configuration": {
            "name": "ghcr.io/example/app:1.0",
            "creationDate": "2026-06-16T00:00:15Z",
            "descriptor": {
              "digest": "sha256:index",
              "mediaType": "application/vnd.oci.image.index.v1+json",
              "size": 9218,
              "annotations": {"org.opencontainers.image.title": "Example"}
            }
          },
          "variants": [{
            "digest": "sha256:manifest",
            "platform": {"architecture": "amd64", "os": "linux"},
            "size": 42000000,
            "config": {
              "created": "2026-06-15T22:00:00Z",
              "architecture": "amd64",
              "os": "linux",
              "config": {"Env": ["MODE=production"]},
              "rootfs": {"type": "layers", "diff_ids": []}
            }
          }]
        }]
        """#
        let dto = try XCTUnwrap(JSONDecoder().decode([ImageDTO].self, from: Data(rawJSON.utf8)).first)
        let inspection = try XCTUnwrap(ImageInspection(
            dto: dto,
            fallbackReference: "ghcr.io/example/app:1.0",
            rawJSON: rawJSON
        ))

        XCTAssertEqual(inspection.reference, "ghcr.io/example/app:1.0")
        XCTAssertEqual(inspection.descriptor?.annotations?["org.opencontainers.image.title"], "Example")
        XCTAssertEqual(inspection.variants.first?.digest, "sha256:manifest")
        XCTAssertEqual(inspection.variants.first?.architecture, "amd64")
        XCTAssertEqual(inspection.variants.first?.configuration?.environment, ["MODE=production"])
    }

    func testDecodesVersionStatusAndStatsFixtures() throws {
        let versions: [SystemVersionDTO] = try decodeFixture("1.0.0/system-version.json")
        let version = SystemVersion(components: versions)
        let statusDTO: SystemStatusDTO = try decodeFixture("1.0.0/system-status.json")
        let statsDTOs: [ContainerStatsDTO] = try decodeFixture("1.0.0/stats.json")

        XCTAssertEqual(version.cli?.version, "1.0.0")
        XCTAssertEqual(version.server?.appName, "container-apiserver")
        XCTAssertTrue(SystemStatus(dto: statusDTO).isRunning)
        XCTAssertEqual(statsDTOs.first.map(ContainerStats.init(dto:))?.processCount, 3)
    }

    func testMinimumFieldsDoNotFailWholeDecode() throws {
        let data = Data(#"[{"configuration":{"id":"only-an-id"},"status":"mystery","newField":42}]"#.utf8)
        let dtos = try JSONDecoder().decode([ContainerDTO].self, from: data)
        let summary = try XCTUnwrap(dtos.first.flatMap(ContainerSummary.init(dto:)))

        XCTAssertEqual(summary.id, "only-an-id")
        XCTAssertEqual(summary.state, .unknown("mystery"))
        XCTAssertNil(summary.image)
    }

    func testDecodesFoundationNumericDatesUsedByLegacyCLIJSON() throws {
        let data = Data(#"[{"configuration":{"id":"legacy"},"status":"running","startedDate":0}]"#.utf8)
        let dto = try XCTUnwrap(JSONDecoder().decode([ContainerDTO].self, from: data).first)
        let details = try XCTUnwrap(ContainerDetails(dto: dto))

        XCTAssertEqual(details.startedAt, Date(timeIntervalSinceReferenceDate: 0))

        let imageDTO = try JSONDecoder().decode(
            ImageDTO.self,
            from: Data(#"{"name":"legacy-image","createdAt":0}"#.utf8)
        )
        XCTAssertEqual(ImageSummary(dto: imageDTO)?.createdAt, Date(timeIntervalSinceReferenceDate: 0))
    }

    private func decodeFixture<Value: Decodable>(_ path: String) throws -> Value {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(path)
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
    }
}
