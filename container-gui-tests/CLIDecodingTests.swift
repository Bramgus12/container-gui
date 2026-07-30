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
        XCTAssertEqual(details.summary.address, "192.168.64.4")
        XCTAssertEqual(details.networks.first?.name, "default")
        XCTAssertEqual(details.ports.first?.hostPort, 8_080)
        XCTAssertEqual(details.mounts.first?.destination, "/data")
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

    private func decodeFixture<Value: Decodable>(_ path: String) throws -> Value {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(path)
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
    }
}
