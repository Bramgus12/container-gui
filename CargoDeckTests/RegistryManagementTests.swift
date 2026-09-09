import Foundation
import XCTest
@testable import CargoDeck

@MainActor
final class RegistryManagementTests: XCTestCase {
    /// Awkward on purpose: whitespace, quotes, a leading dash and non-ASCII all
    /// have to stay out of every artifact, not merely be escaped in them.
    private static let sentinel = #"-not-a-flag 'quoted" pa$$ wörd"#

    // MARK: - Command construction

    func testListUsesQuietRatherThanAStructuredFormat() {
        XCTAssertEqual(
            ContainerCommand.listRegistries.arguments,
            ["registry", "list", "--quiet"]
        )
    }

    func testLoginAlwaysUsesPasswordStdinAndPutsTheServerLast() throws {
        let configuration = try RegistryLoginConfiguration(
            server: "registry.example.test:5000",
            username: "ci-user",
            scheme: .http
        )

        XCTAssertEqual(configuration.arguments, [
            "registry", "login",
            "--password-stdin",
            "--scheme", "http",
            "--username", "ci-user",
            "registry.example.test:5000",
        ])
    }

    func testAutomaticSchemeOmitsTheFlagEntirely() throws {
        let configuration = try RegistryLoginConfiguration(
            server: "ghcr.io",
            username: "ci-user"
        )

        XCTAssertEqual(configuration.arguments, [
            "registry", "login", "--password-stdin", "--username", "ci-user", "ghcr.io",
        ])
    }

    func testLogoutNamesTheHost() throws {
        XCTAssertEqual(
            ContainerCommand.logoutRegistry(host: try RegistryHost(validating: "ghcr.io")).arguments,
            ["registry", "logout", "ghcr.io"]
        )
    }

    // MARK: - Host validation

    func testHostRejectsSchemesPathsAndOptionInjection() {
        // Surrounding whitespace is trimmed rather than rejected — see
        // `testHostTrimsSurroundingWhitespace` — so interior whitespace is what
        // has to fail here.
        for value in [
            "https://ghcr.io",
            "ghcr.io/library",
            "--all",
            "gh cr.io",
            "",
            "   ",
            "-ghcr.io",
            "ghcr.io:notaport",
        ] {
            XCTAssertThrowsError(
                try RegistryHost(validating: value),
                "\(value) should not validate as a registry host"
            )
        }
    }

    func testHostAcceptsHostsAndPorts() throws {
        for value in ["ghcr.io", "docker.io", "localhost:5000", "registry.example.test:443"] {
            XCTAssertEqual(try RegistryHost(validating: value).rawValue, value)
        }
    }

    func testHostTrimsSurroundingWhitespace() throws {
        XCTAssertEqual(try RegistryHost(validating: "  ghcr.io \n").rawValue, "ghcr.io")
    }

    // MARK: - Quiet-list parsing

    func testQuietListParsingValidatesDeduplicatesAndSorts() {
        let output = """
        ghcr.io

        docker.io
        ghcr.io
        not a host
        localhost:5000
        """

        XCTAssertEqual(
            CLIRegistryService.hosts(from: output).map(\.host),
            ["docker.io", "ghcr.io", "localhost:5000"]
        )
    }

    func testQuietListParsingDropsNoiseRatherThanShowingIt() {
        let output = "Warning: config file is read-only\nghcr.io\n"

        XCTAssertEqual(CLIRegistryService.hosts(from: output).map(\.host), ["ghcr.io"])
    }

    // MARK: - Service

    func testServiceSendsThePasswordThroughStandardInputOnly() async throws {
        let cli = RegistryCLIStub(output: "")
        let service = CLIRegistryService(cli: cli)
        let configuration = try RegistryLoginConfiguration(
            server: "ghcr.io",
            username: "ci-user"
        )

        try await service.login(configuration, password: Self.sentinel)

        let commands = await cli.commands
        let payloads = await cli.standardInputPayloads
        XCTAssertEqual(commands, [.loginRegistry(configuration: configuration)])
        XCTAssertEqual(payloads.count, 1)

        // Exactly the secret plus the single newline the CLI reads to.
        let payload = try XCTUnwrap(payloads.first.flatMap { $0 })
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), Self.sentinel + "\n")

        // And nothing of it anywhere in the command itself.
        let arguments = commands.flatMap(\.arguments)
        XCTAssertFalse(arguments.contains { $0.contains("pa$$") }, "\(arguments)")
        let preview = ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: arguments
        )
        XCTAssertFalse(preview.contains(Self.sentinel), preview)
    }

    func testFailedLoginSurfacesASanitizedErrorWithoutTheSecret() async throws {
        let cli = RegistryCLIStub(
            output: "",
            error: .nonZeroExit(
                invocation: "container registry login --password-stdin ghcr.io",
                exitCode: 1,
                standardError: "unauthorized"
            )
        )
        let model = RegistryModel(service: CLIRegistryService(cli: cli))
        let configuration = try RegistryLoginConfiguration(
            server: "ghcr.io",
            username: "ci-user"
        )

        let succeeded = await model.login(configuration, password: Self.sentinel)

        XCTAssertFalse(succeeded)
        let failure = try XCTUnwrap(model.mutationFailure)
        XCTAssertTrue(failure.contains("unauthorized"), failure)
        XCTAssertFalse(failure.contains(Self.sentinel), failure)
    }

    // MARK: - Model

    func testRefreshLoadsSortedHostsAndClearsAStaleSelection() async {
        let cli = RegistryCLIStub(output: "ghcr.io\ndocker.io\n")
        let model = RegistryModel(service: CLIRegistryService(cli: cli))
        model.selectedRegistryID = "gone.example.test"

        await model.refresh()

        XCTAssertEqual(model.registries.map(\.host), ["docker.io", "ghcr.io"])
        XCTAssertEqual(model.listState, .loaded)
        XCTAssertNil(model.selectedRegistryID)
    }

    func testLoginRefreshesAndSelectsTheNewHost() async throws {
        let cli = RegistryCLIStub(output: "ghcr.io\n")
        let model = RegistryModel(service: CLIRegistryService(cli: cli))

        let succeeded = await model.login(
            try RegistryLoginConfiguration(server: "ghcr.io", username: "ci-user"),
            password: Self.sentinel
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.selectedRegistryID, "ghcr.io")
        let commands = await cli.commands
        XCTAssertTrue(commands.contains(.listRegistries), "Login must reconcile the list.")
    }

    func testLogoutRefusesAHostThatIsNoLongerListed() async {
        let cli = RegistryCLIStub(output: "ghcr.io\n")
        let model = RegistryModel(service: CLIRegistryService(cli: cli))
        await model.refresh()

        await model.logout(host: "docker.io")

        XCTAssertEqual(
            model.mutationFailure,
            "The registry changed. Refresh the list and try again."
        )
        let commands = await cli.commands
        XCTAssertFalse(
            commands.contains { command in
                if case .logoutRegistry = command { return true }
                return false
            },
            "A stale host must not reach the CLI."
        )
    }

    func testLogoutClearsTheSelectionAndRefreshes() async {
        let cli = RegistryCLIStub(output: "ghcr.io\n")
        let model = RegistryModel(service: CLIRegistryService(cli: cli))
        await model.refresh()
        model.selectedRegistryID = "ghcr.io"
        await cli.setOutput("")

        await model.logout(host: "ghcr.io")

        XCTAssertNil(model.selectedRegistryID)
        XCTAssertTrue(model.registries.isEmpty)
        XCTAssertNil(model.mutationFailure)
    }

    func testSearchFiltersHosts() async {
        let cli = RegistryCLIStub(output: "ghcr.io\ndocker.io\n")
        let model = RegistryModel(service: CLIRegistryService(cli: cli))
        await model.refresh()

        model.searchText = "ghcr"

        XCTAssertEqual(model.filteredRegistries.map(\.host), ["ghcr.io"])
    }

    // MARK: - Reference host matching

    func testRegistryHostIsExtractedOnlyWhenTheFirstSegmentLooksLikeAHost() {
        XCTAssertEqual(
            RegistryModel.registryHost(inReference: "ghcr.io/example/app:1.0"),
            "ghcr.io"
        )
        XCTAssertEqual(
            RegistryModel.registryHost(inReference: "localhost:5000/app:1.0"),
            "localhost:5000"
        )
        // `library` is a namespace, not a registry.
        XCTAssertNil(RegistryModel.registryHost(inReference: "library/alpine:3.21"))
        XCTAssertNil(RegistryModel.registryHost(inReference: "alpine:3.21"))
    }

    func testLoggedInCheckMatchesTheReferenceHost() async {
        let cli = RegistryCLIStub(output: "ghcr.io\n")
        let model = RegistryModel(service: CLIRegistryService(cli: cli))
        await model.refresh()

        XCTAssertTrue(model.isLoggedIn(forReference: "ghcr.io/example/app:1.0"))
        XCTAssertFalse(model.isLoggedIn(forReference: "docker.io/library/alpine:3.21"))
        XCTAssertFalse(model.isLoggedIn(forReference: "alpine:3.21"))
    }

    // MARK: - Login form

    func testLoginFormClearsThePasswordBeforeSubmitting() async {
        let cli = RegistryCLIStub(output: "ghcr.io\n")
        let model = RegistryModel(service: CLIRegistryService(cli: cli))
        let draft = RegistryLoginModel()
        draft.server = "ghcr.io"
        draft.username = "ci-user"
        draft.setPassword(Self.sentinel)

        XCTAssertTrue(draft.canSubmit)
        let succeeded = await draft.submit(using: model)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(
            draft.password.isEmpty,
            "The form must not hold the secret once submission has started."
        )
        XCTAssertFalse(draft.hasPassword)
    }

    func testLoginFormPreviewShowsPasswordStdinAndNeverTheSecret() {
        let draft = RegistryLoginModel()
        draft.server = "ghcr.io"
        draft.username = "ci-user"
        draft.setPassword(Self.sentinel)

        let preview = draft.commandPreview

        XCTAssertTrue(preview.contains("--password-stdin"), preview)
        XCTAssertFalse(preview.contains(Self.sentinel), preview)
        XCTAssertFalse(preview.contains("*"), "No placeholder either — see the login sheet.")
    }

    /// Regression: `password` is `@ObservationIgnored`, so a view cannot observe
    /// it changing. Enablement therefore has to hang off `hasPassword`, which
    /// `setPassword` maintains — writing the property directly would leave the
    /// Log In button disabled no matter what was typed.
    func testTypingAPasswordEnablesSubmitting() {
        let draft = RegistryLoginModel()
        draft.server = "ghcr.io"
        draft.username = "ci-user"

        XCTAssertFalse(draft.canSubmit)
        draft.setPassword("t")

        XCTAssertTrue(draft.hasPassword)
        XCTAssertTrue(draft.canSubmit)

        draft.setPassword("")
        XCTAssertFalse(draft.hasPassword)
        XCTAssertFalse(draft.canSubmit)
    }

    func testLoginFormCannotSubmitWithoutAPassword() {
        let draft = RegistryLoginModel()
        draft.server = "ghcr.io"
        draft.username = "ci-user"

        XCTAssertFalse(draft.canSubmit)
    }

    func testLoginFormRejectsAServerWithAScheme() {
        let draft = RegistryLoginModel()
        draft.server = "https://ghcr.io"

        XCTAssertNotNil(draft.serverError)
        XCTAssertNil(draft.configuration)
    }
}

private actor RegistryCLIStub: ContainerCLI {
    private var output: String
    private let error: CLIError?
    private(set) var commands: [ContainerCommand] = []
    private(set) var standardInputPayloads: [Data?] = []

    init(output: String, error: CLIError? = nil) {
        self.output = output
        self.error = error
    }

    func setOutput(_ output: String) {
        self.output = output
    }

    func run(_ command: ContainerCommand) async throws -> CommandResult {
        try await run(command, standardInput: nil)
    }

    func run(
        _ command: ContainerCommand,
        standardInput: Data?
    ) async throws -> CommandResult {
        commands.append(command)
        if standardInput != nil {
            standardInputPayloads.append(standardInput)
        }
        if let error, case .loginRegistry = command {
            throw error
        }
        return CommandResult(
            standardOutput: output,
            standardError: "",
            exitCode: 0,
            duration: .zero,
            invocation: "container \(command.arguments.joined(separator: " "))"
        )
    }

    nonisolated func stream(
        _ command: ContainerCommand
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
