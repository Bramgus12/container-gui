import XCTest
@testable import Container_GUI

final class RunConfigurationTests: XCTestCase {
    func testAcceptsValidBoundaryValues() throws {
        XCTAssertNoThrow(try ContainerIdentifier(validating: "a"))
        XCTAssertNoThrow(try ImageReference(validating: "localhost:5000/team/app:v1"))
        XCTAssertNoThrow(try CPULimit("0.25"))
        XCTAssertNoThrow(try MemoryLimit("1M"))
        XCTAssertNoThrow(try PortMapping(hostPort: 1, containerPort: 65_535))
        XCTAssertNoThrow(try EnvironmentVariable(key: "_VALID_2", value: "quotes \" and = signs"))
    }

    func testRejectsInvalidNamesAndReferences() {
        for name in ["", "-name", "contains space", "line\nbreak", "slash/name", "unicode_β"] {
            XCTAssertThrowsError(try ContainerIdentifier(validating: name), "Accepted \(name.debugDescription)")
        }
        for reference in ["", "-image", "contains space", "line\nbreak", "example/β:latest"] {
            XCTAssertThrowsError(try ImageReference(validating: reference), "Accepted \(reference.debugDescription)")
        }
    }

    func testRejectsInvalidEnvironmentKeysAndControlCharacters() {
        for key in ["", "2FAST", "HAS-DASH", "HAS SPACE", "Å"] {
            XCTAssertThrowsError(try EnvironmentVariable(key: key, value: "value"))
        }
        XCTAssertThrowsError(try EnvironmentVariable(key: "VALID", value: "line\nbreak"))
    }

    func testRejectsInvalidCPUAndMemoryLimits() {
        for value in ["", "0", "-1", ".5", "1e2", "one"] {
            XCTAssertThrowsError(try CPULimit(value), "Accepted \(value)")
        }
        for value in ["", "0", "-1G", "1.5G", "12GiB", "lots"] {
            XCTAssertThrowsError(try MemoryLimit(value), "Accepted \(value)")
        }
    }

    func testRejectsInvalidPortsAndAddresses() {
        XCTAssertThrowsError(try PortMapping(hostPort: 0, containerPort: 80))
        XCTAssertThrowsError(try PortMapping(hostPort: 80, containerPort: 65_536))
        XCTAssertThrowsError(try PortMapping(hostAddress: "localhost", hostPort: 80, containerPort: 80))
        XCTAssertThrowsError(try PortMapping(hostAddress: "999.1.1.1", hostPort: 80, containerPort: 80))
    }

    func testFormatsIPv6PortMapping() throws {
        let mapping = try PortMapping(
            hostAddress: "::1",
            hostPort: 4_432,
            containerPort: 443
        )
        XCTAssertEqual(mapping.argument, "[::1]:4432:443")
    }

    func testSystemLogPeriodMustBePositive() {
        XCTAssertThrowsError(try SystemLogPeriod(value: 0, unit: .hours))
        XCTAssertThrowsError(try StopTimeout(seconds: -1))
        XCTAssertThrowsError(try LogTail(lines: -1))
    }
}
