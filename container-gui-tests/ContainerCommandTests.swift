import XCTest
@testable import Container_GUI

final class ContainerCommandTests: XCTestCase {
    func testSystemCommandArguments() throws {
        let period = try SystemLogPeriod(value: 15, unit: .minutes)

        XCTAssertEqual(ContainerCommand.systemStart.arguments, ["system", "start", "--disable-kernel-install"])
        XCTAssertEqual(ContainerCommand.systemStop.arguments, ["system", "stop"])
        XCTAssertEqual(ContainerCommand.systemStatus.arguments, ["system", "status", "--format", "json"])
        XCTAssertEqual(ContainerCommand.systemVersion.arguments, ["system", "version", "--format", "json"])
        XCTAssertEqual(ContainerCommand.systemDiskUsage.arguments, ["system", "df", "--format", "json"])
        XCTAssertEqual(
            ContainerCommand.systemLogs(follow: true, last: period).arguments,
            ["system", "logs", "--follow", "--last", "15m"]
        )
    }

    func testContainerCommandArguments() throws {
        let id = try ContainerIdentifier(validating: "web.1_test")
        let timeout = try StopTimeout(seconds: 30)
        let tail = try LogTail(lines: 200)

        XCTAssertEqual(
            ContainerCommand.listContainers(includeStopped: true).arguments,
            ["list", "--all", "--format", "json"]
        )
        XCTAssertEqual(
            ContainerCommand.listContainers(includeStopped: false).arguments,
            ["list", "--format", "json"]
        )
        XCTAssertEqual(ContainerCommand.inspectContainer(id: id).arguments, ["inspect", "web.1_test"])
        XCTAssertEqual(ContainerCommand.start(id: id).arguments, ["start", "web.1_test"])
        XCTAssertEqual(
            ContainerCommand.stop(id: id, timeout: timeout).arguments,
            ["stop", "--time", "30", "web.1_test"]
        )
        XCTAssertEqual(ContainerCommand.stop(id: id, timeout: nil).arguments, ["stop", "web.1_test"])
        XCTAssertEqual(
            ContainerCommand.delete(id: id, force: true).arguments,
            ["delete", "--force", "web.1_test"]
        )
        XCTAssertEqual(
            ContainerCommand.logs(id: id, follow: true, tail: tail).arguments,
            ["logs", "--follow", "-n", "200", "web.1_test"]
        )
        XCTAssertEqual(
            ContainerCommand.stats(ids: [id]).arguments,
            ["stats", "--format", "json", "--no-stream", "web.1_test"]
        )
    }

    func testImageCommandArguments() throws {
        let reference = try ImageReference(validating: "ghcr.io/example/app:1.2@sha256:abc")

        XCTAssertEqual(
            ContainerCommand.listImages.arguments,
            ["image", "list", "--verbose", "--format", "json"]
        )
        XCTAssertEqual(
            ContainerCommand.inspectImage(reference: reference).arguments,
            ["image", "inspect", reference.rawValue]
        )
        XCTAssertEqual(
            ContainerCommand.pullImage(reference: reference).arguments,
            ["image", "pull", "--progress", "plain", reference.rawValue]
        )
        XCTAssertEqual(
            ContainerCommand.deleteImage(reference: reference).arguments,
            ["image", "delete", reference.rawValue]
        )
    }

    func testRunPreservesEveryValueAsOneArgument() throws {
        let port = try PortMapping(
            hostAddress: "127.0.0.1",
            hostPort: 8_080,
            containerPort: 80,
            protocol: .udp
        )
        let message = try EnvironmentVariable(
            key: "GREETING",
            value: #"Hello “container world” — $HOME"#
        )
        let configuration = try RunConfiguration(
            image: "example/app:latest",
            name: "unicode_test",
            detached: true,
            removeWhenStopped: true,
            cpuLimit: "1.5",
            memoryLimit: "512M",
            ports: [port],
            environment: [message],
            command: ["printf", "%s\n", #"spaces, "quotes", and 'apostrophes'"#, "--value"]
        )

        XCTAssertEqual(
            ContainerCommand.run(configuration).arguments,
            [
                "run", "--progress", "plain",
                "--detach", "--rm",
                "--name", "unicode_test",
                "--cpus", "1.5",
                "--memory", "512M",
                "--publish", "127.0.0.1:8080:80/udp",
                "--env", #"GREETING=Hello “container world” — $HOME"#,
                "example/app:latest",
                "printf", "%s\n", #"spaces, "quotes", and 'apostrophes'"#, "--value",
            ]
        )
    }

    func testDashPrefixedResourceValuesAreRejectedButCommandArgumentsAreAllowed() throws {
        XCTAssertThrowsError(try ContainerIdentifier(validating: "--all"))
        XCTAssertThrowsError(try ImageReference(validating: "--help"))

        let configuration = try RunConfiguration(
            image: "alpine:latest",
            command: ["echo", "--help"]
        )
        XCTAssertEqual(Array(configuration.arguments.suffix(2)), ["echo", "--help"])
    }
}
