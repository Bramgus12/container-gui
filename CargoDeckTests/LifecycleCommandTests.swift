import XCTest
@testable import CargoDeck

final class LifecycleCommandTests: XCTestCase {
    private func identifier() throws -> ContainerIdentifier {
        try ContainerIdentifier(validating: "web.1_test")
    }

    // MARK: - create

    func testCreateUsesRunFlagsWithoutProgressOrDetach() throws {
        let configuration = try RunConfiguration(
            image: "alpine:3.22",
            name: "web",
            detached: true,
            removeWhenStopped: true,
            cpuLimit: "2",
            memoryLimit: "512M",
            environment: [try EnvironmentVariable(key: "MODE", value: "test")]
        )

        XCTAssertEqual(
            ContainerCommand.create(configuration).arguments,
            [
                "create",
                "--rm",
                "--name", "web",
                "--cpus", "2",
                "--memory", "512M",
                "--env", "MODE=test",
                "alpine:3.22",
            ]
        )
    }

    func testRunArgumentsAreUnchangedByTheModeSplit() throws {
        let configuration = try RunConfiguration(image: "alpine:3.22", detached: true)

        XCTAssertEqual(
            ContainerCommand.run(configuration).arguments,
            ["run", "--progress", "plain", "--detach", "alpine:3.22"]
        )
        XCTAssertEqual(configuration.arguments, configuration.arguments(mode: .run))
    }

    func testCreateKeepsTheInitProcessArguments() throws {
        let configuration = try RunConfiguration(
            image: "alpine:3.22",
            command: ["sh", "-c", "echo hi"]
        )

        XCTAssertEqual(
            ContainerCommand.create(configuration).arguments,
            ["create", "alpine:3.22", "sh", "-c", "echo hi"]
        )
    }

    // MARK: - kill

    func testKillArguments() throws {
        let id = try identifier()

        XCTAssertEqual(ContainerCommand.kill(id: id, signal: nil).arguments, ["kill", "web.1_test"])
        XCTAssertEqual(
            ContainerCommand.kill(id: id, signal: .term).arguments,
            ["kill", "--signal", "TERM", "web.1_test"]
        )
        XCTAssertEqual(
            ContainerCommand.kill(id: id, signal: .user1).arguments,
            ["kill", "--signal", "USR1", "web.1_test"]
        )
    }

    // MARK: - prune

    func testPruneContainersArguments() {
        XCTAssertEqual(ContainerCommand.pruneContainers.arguments, ["prune"])
    }

    // MARK: - exec

    func testExecArguments() throws {
        let configuration = try ExecConfiguration(
            command: ["sh", "-c", "printenv MODE"],
            environment: [try EnvironmentVariable(key: "MODE", value: "test")],
            user: "root:staff",
            workingDirectory: "/srv",
            interactive: true,
            tty: true
        )

        XCTAssertEqual(
            ContainerCommand.exec(id: try identifier(), configuration: configuration).arguments,
            [
                "exec",
                "--env", "MODE=test",
                "--user", "root:staff",
                "--workdir", "/srv",
                "--interactive",
                "--tty",
                "web.1_test",
                "sh", "-c", "printenv MODE",
            ]
        )
    }

    func testExecPlacesEveryOptionBeforeTheContainerIdentifier() throws {
        let configuration = try ExecConfiguration(command: ["ls", "-la"], detached: true)
        let arguments = ContainerCommand
            .exec(id: try identifier(), configuration: configuration)
            .arguments

        let identifierIndex = try XCTUnwrap(arguments.firstIndex(of: "web.1_test"))
        let options = arguments.prefix(identifierIndex)
        XCTAssertEqual(Array(options), ["exec", "--detach"])
        // Arguments after the identifier belong to the command, dashes included.
        XCTAssertEqual(Array(arguments.suffix(from: identifierIndex + 1)), ["ls", "-la"])
    }

    func testExecRejectsAnEmptyCommand() {
        XCTAssertThrowsError(try ExecConfiguration(command: [])) { error in
            XCTAssertEqual(error as? CommandValidationError, .empty(field: "Command"))
        }
        XCTAssertThrowsError(try ExecConfiguration(command: [""])) { error in
            XCTAssertEqual(error as? CommandValidationError, .empty(field: "Command"))
        }
    }

    func testExecRejectsAnExecutableThatWouldParseAsAnOption() {
        XCTAssertThrowsError(try ExecConfiguration(command: ["--debug"])) { error in
            XCTAssertEqual(
                error as? CommandValidationError,
                .invalid(field: "Command", value: "--debug")
            )
        }
    }

    func testExecRejectsControlCharactersInArguments() {
        XCTAssertThrowsError(try ExecConfiguration(command: ["sh", "-c", "echo hi\nwhoami"]))
    }

    func testExecRejectsDetachedInteractiveSessions() {
        XCTAssertThrowsError(
            try ExecConfiguration(command: ["sh"], interactive: true, detached: true)
        ) { error in
            XCTAssertEqual(
                error as? CommandValidationError,
                .invalid(
                    field: "Exec configuration",
                    value: "Detached cannot be combined with interactive or TTY"
                )
            )
        }
    }

    func testExecRejectsARelativeWorkingDirectory() {
        XCTAssertThrowsError(
            try ExecConfiguration(command: ["ls"], workingDirectory: "srv")
        ) { error in
            XCTAssertEqual(
                error as? CommandValidationError,
                .invalid(field: "Working directory", value: "srv")
            )
        }
    }

    // MARK: - user

    func testProcessUserAcceptsNamesUIDsAndGroups() throws {
        XCTAssertEqual(try ProcessUser(validating: "root").rawValue, "root")
        XCTAssertEqual(try ProcessUser(validating: "1000").rawValue, "1000")
        XCTAssertEqual(try ProcessUser(validating: "1000:1000").rawValue, "1000:1000")
        XCTAssertEqual(try ProcessUser(validating: "app_user.1").rawValue, "app_user.1")
    }

    func testProcessUserRejectsSeparatorsAndFlags() {
        for value in ["", "-root", "root:", ":staff", "root:staff:extra", "root staff", "root;id"] {
            XCTAssertThrowsError(try ProcessUser(validating: value), "accepted \(value)")
        }
    }

    // MARK: - copy

    func testCopyOutOfAContainer() throws {
        let operation = try CopyOperation(
            source: .container(id: "web.1_test", path: "/srv/report.txt"),
            destination: .host(path: "/Users/example/report.txt")
        )

        XCTAssertEqual(
            ContainerCommand.copy(operation).arguments,
            ["copy", "web.1_test:/srv/report.txt", "/Users/example/report.txt"]
        )
    }

    func testCopyIntoAContainer() throws {
        let operation = try CopyOperation(
            source: .host(path: "/Users/example/config.toml"),
            destination: .container(id: "web.1_test", path: "/etc/app/config.toml")
        )

        XCTAssertEqual(
            ContainerCommand.copy(operation).arguments,
            ["copy", "/Users/example/config.toml", "web.1_test:/etc/app/config.toml"]
        )
    }

    func testCopyRequiresExactlyOneContainerEndpoint() throws {
        XCTAssertThrowsError(
            try CopyOperation(
                source: .host(path: "/tmp/a"),
                destination: .host(path: "/tmp/b")
            )
        )
        XCTAssertThrowsError(
            try CopyOperation(
                source: .container(id: "web.1_test", path: "/tmp/a"),
                destination: .container(id: "api", path: "/tmp/b")
            )
        )
    }

    func testCopyRejectsRelativeAndControlCharacterPaths() {
        XCTAssertThrowsError(try CopyEndpoint.host(path: "relative/path"))
        XCTAssertThrowsError(try CopyEndpoint.container(id: "web.1_test", path: "srv"))
        XCTAssertThrowsError(try CopyEndpoint.host(path: "/tmp/a\nb"))
    }

    func testCopyRejectsAnIdentifierThatWouldSplitTheEndpoint() {
        // A colon in the identifier would make the container endpoint ambiguous.
        XCTAssertThrowsError(try CopyEndpoint.container(id: "web:1", path: "/srv"))
    }

    // MARK: - export

    func testExportArguments() throws {
        let output = try LocalPath(validating: "/Users/example/web.tar", field: "Export path")

        XCTAssertEqual(
            ContainerCommand.exportContainer(id: try identifier(), output: output).arguments,
            ["export", "--output", "/Users/example/web.tar", "web.1_test"]
        )
    }
}
