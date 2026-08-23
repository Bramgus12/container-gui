import XCTest
@testable import Container_GUI

final class DNSManagementTests: XCTestCase {
    func testResolverFileParsesShippingFormat() {
        let body = "domain cont\nsearch cont\nnameserver 127.0.0.1\nport 2053\n"
        let file = ResolverFile.parse(body, path: URL(fileURLWithPath: "/etc/resolver/containerization.cont"))
        XCTAssertEqual(file?.domain, "cont")
        XCTAssertEqual(file?.search, ["cont"])
        XCTAssertEqual(file?.nameserver, "127.0.0.1")
        XCTAssertEqual(file?.port, 2053)
        XCTAssertNotNil(ResolverFile.parse("domain test\n", path: URL(fileURLWithPath: "/tmp/test")))
        XCTAssertNil(ResolverFile.parse("garbage", path: URL(fileURLWithPath: "/tmp/bad")))
    }

    func testValidatedDNSTypes() throws {
        for value in ["cont", "svc.test", "a-b.example"] { XCTAssertNoThrow(try DNSDomainName(validating: value)) }
        for value in ["", "-cont", ".cont", "UPPER", "bad_domain"] { XCTAssertThrowsError(try DNSDomainName(validating: value)) }
        for value in ["127.0.0.1", "1.1.1.1", "2001:4860:4860::8888"] { XCTAssertNoThrow(try DNSNameserver(validating: value)) }
        for value in ["", "999.1.1.1", "resolver"] { XCTAssertThrowsError(try DNSNameserver(validating: value)) }
        for value in ["ndots:2", "timeout:2", "attempts:3", "edns0", "rotate"] { XCTAssertNoThrow(try DNSOption(validating: value)) }
        for value in ["", ":2", "bad value", "ndots:two:extra"] { XCTAssertThrowsError(try DNSOption(validating: value)) }
    }

    func testReadinessStates() {
        XCTAssertEqual(DNSReadiness.resolve(serviceDomain: "cont", resolverDomains: ["cont"]), .resolving(domain: "cont"))
        XCTAssertEqual(DNSReadiness.resolve(serviceDomain: "cont", resolverDomains: []), .serviceOnly(domain: "cont"))
        XCTAssertEqual(DNSReadiness.resolve(serviceDomain: nil, resolverDomains: ["cont"]), .resolverOnly(domain: "cont"))
        XCTAssertEqual(DNSReadiness.resolve(serviceDomain: nil, resolverDomains: []), .notConfigured)
    }

    func testCreateAndDeleteCommands() throws {
        let domain = try DNSDomainName(validating: "test")
        let address = try DNSNameserver(validating: "192.168.64.1")
        XCTAssertEqual(DNSCreateConfiguration(domain: domain, localhostRedirect: address).sudoCommand, "sudo container system dns create test --localhost 192.168.64.1")
        XCTAssertEqual(DNSDeleteConfiguration(domain: domain).sudoCommand, "sudo container system dns delete test")
    }

    @MainActor
    func testAddLocalDomainPreviewFollowsDomainField() {
        let dns = DNSModel(service: DNSServiceStub(), resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: OperationFailureLog())
        let model = AddLocalDomainModel(dns: dns)

        XCTAssertEqual(model.previewDomain, "test")
        model.domain = "  containers.local  "
        XCTAssertEqual(model.previewDomain, "containers.local")
    }

    func testDNSContainerArgumentsAndConflicts() throws {
        let configuration = try RunConfiguration(image: "nginx:1.27", dnsNameservers: [DNSNameserver(validating: "1.1.1.1")], dnsDomain: DNSDomainName(validating: "test"), dnsSearchDomains: [DNSDomainName(validating: "svc.test")], dnsOptions: [DNSOption(validating: "ndots:2")])
        XCTAssertEqual(configuration.arguments.suffix(9), ["--dns", "1.1.1.1", "--dns-domain", "test", "--dns-search", "svc.test", "--dns-option", "ndots:2", "nginx:1.27"])
        XCTAssertThrowsError(try RunConfiguration(image: "nginx", disablesDNS: true, dnsDomain: DNSDomainName(validating: "test")))
        let duplicate = try DNSNameserver(validating: "1.1.1.1")
        XCTAssertThrowsError(try RunConfiguration(image: "nginx", dnsNameservers: [duplicate, duplicate]))
    }

    func testCLIServiceDecodesShippingJSON() async throws {
        let service = CLIDNSService(cli: DNSCLIStub(), executableURL: URL(fileURLWithPath: "/usr/local/bin/container"), privilegedRunner: PrivilegedRunnerStub())
        let domains = try await service.listDomains()
        XCTAssertEqual(domains, ["cont"])
        let serviceDomain = try await service.loadServiceDomain()
        XCTAssertEqual(serviceDomain, "cont")
        XCTAssertEqual(ContainerCommand.systemDNSList.arguments, ["system", "dns", "list", "--format", "json"])
        XCTAssertEqual(ContainerCommand.systemProperties.arguments, ["system", "property", "list", "--format", "json"])
    }

    @MainActor
    func testDNSModelMergesResolverAndServiceStateAndProbes() async {
        let resolver = ResolverFile.parse("domain cont\nnameserver 127.0.0.1\nport 2053", path: URL(fileURLWithPath: "/etc/resolver/containerization.cont"))!
        let model = DNSModel(service: DNSServiceStub(), resolverReader: ResolverReaderStub(files: [resolver]), hostResolver: HostResolverStub(), failureLog: OperationFailureLog())
        await model.refresh()
        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.readiness, .resolving(domain: "cont"))
        XCTAssertEqual(model.domains.first?.resolverFile, resolver)
        XCTAssertEqual(model.domains.first?.isServiceDomain, true)
    }

    @MainActor
    func testSettingTheServiceDomainWritesTheConfigAndAsksForARestart() async throws {
        let configFile = ConfigFileStub()
        // The service still reports the domain it loaded at start.
        let model = DNSModel(service: DNSServiceStub(domains: ["test"], serviceDomain: "cont"), resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: OperationFailureLog(), configFile: configFile)

        let saved = await model.setServiceDomain(try DNSDomainName(validating: "test"))
        XCTAssertTrue(saved)
        XCTAssertEqual(configFile.writtenDomains, ["test"])
        XCTAssertEqual(model.pendingServiceDomain, "test")
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.isWritingConfig)
    }

    @MainActor
    func testTheRestartNoticeClearsOnceTheServiceReportsTheDomain() async throws {
        let model = DNSModel(service: DNSServiceStub(domains: ["test"], serviceDomain: "test"), resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: OperationFailureLog(), configFile: ConfigFileStub())

        let saved = await model.setServiceDomain(try DNSDomainName(validating: "test"))
        XCTAssertTrue(saved)
        XCTAssertNil(model.pendingServiceDomain)
        XCTAssertEqual(model.readiness, .resolving(domain: "test"))
    }

    @MainActor
    func testAnUneditableConfigSurfacesTheMessageAndLeavesNothingPending() async throws {
        let log = OperationFailureLog()
        let failure = ConfigFileError.unsupportedLayout(path: "/Users/test/.config/container/config.toml")
        let model = DNSModel(service: DNSServiceStub(domains: [], serviceDomain: nil), resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: log, configFile: ConfigFileStub(error: failure))

        let saved = await model.setServiceDomain(try DNSDomainName(validating: "test"))
        XCTAssertFalse(saved)
        XCTAssertNil(model.pendingServiceDomain)
        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(model.actionError, failure.localizedDescription)
    }

    @MainActor
    func testAddLocalDomainCanSetTheDomainItIsAdding() async {
        let configFile = ConfigFileStub()
        let dns = DNSModel(service: DNSServiceStub(domains: ["test"], serviceDomain: "cont"), resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: OperationFailureLog(), configFile: configFile)
        let model = AddLocalDomainModel(dns: dns)
        model.domain = "test"
        XCTAssertFalse(model.isServiceDomain)

        await model.setAsServiceDomain()
        XCTAssertEqual(configFile.writtenDomains, ["test"])
        XCTAssertTrue(model.didSetServiceDomain)
        XCTAssertNil(model.configError)
        // The banner now reports the domain as the service one, pending a restart.
        XCTAssertTrue(model.isServiceDomain)
    }

    @MainActor
    func testAddLocalDomainKeepsItsOwnFailureAndClearsItOnSuccess() async {
        let failure = PrivilegedCommandError.failed(invocation: "sudo container", exitCode: 1, message: "cannot create domain (try sudo?)")
        let dns = DNSModel(service: DNSServiceStub(mutationError: failure, domains: []), resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: OperationFailureLog())
        let model = AddLocalDomainModel(dns: dns)
        XCTAssertNil(model.addError)

        model.domain = "test"
        let added = await model.add()
        XCTAssertFalse(added)
        XCTAssertEqual(model.addError, "cannot create domain (try sudo?)")

        let succeeding = AddLocalDomainModel(dns: DNSModel(service: DNSServiceStub(domains: []), resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: OperationFailureLog()))
        succeeding.domain = "test"
        let secondAdd = await succeeding.add()
        XCTAssertTrue(secondAdd)
        XCTAssertNil(succeeding.addError)
    }

    @MainActor
    func testCreateDomainAddsItAndClearsTheMutation() async throws {
        let service = DNSServiceStub(domains: [])
        let model = DNSModel(service: service, resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: OperationFailureLog())
        let configuration = try DNSCreateConfiguration(domain: DNSDomainName(validating: "test"), localhostRedirect: nil)

        let created = await model.createDomain(configuration)
        XCTAssertTrue(created)
        XCTAssertNil(model.activeMutation)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.domains.map(\.name), ["test"])
        let recorded = await service.createdConfigurations
        XCTAssertEqual(recorded, [configuration])
    }

    @MainActor
    func testDeleteDomainRemovesItFromTheList() async throws {
        let service = DNSServiceStub(domains: ["cont"])
        let model = DNSModel(service: service, resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: OperationFailureLog())
        await model.refresh()

        let deleted = await model.deleteDomain(DNSDeleteConfiguration(domain: try DNSDomainName(validating: "cont")))
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.domains.isEmpty)
        XCTAssertEqual(model.readiness, .notConfigured)
    }

    @MainActor
    func testDismissedPasswordDialogLeavesNoFailureBehind() async throws {
        let log = OperationFailureLog()
        let service = DNSServiceStub(mutationError: PrivilegedCommandError.cancelled, domains: [])
        let model = DNSModel(service: service, resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: log)

        let created = await model.createDomain(DNSCreateConfiguration(domain: try DNSDomainName(validating: "test"), localhostRedirect: nil))
        XCTAssertFalse(created)
        XCTAssertNil(model.actionError)
        XCTAssertNil(model.activeMutation)
        XCTAssertTrue(log.records.isEmpty)
    }

    @MainActor
    func testFailedPrivilegedCommandSurfacesTheMessage() async throws {
        let log = OperationFailureLog()
        let failure = PrivilegedCommandError.failed(invocation: "sudo container system dns create test", exitCode: 1, message: "cannot create domain (try sudo?)")
        let service = DNSServiceStub(mutationError: failure, domains: [])
        let model = DNSModel(service: service, resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: log)

        let created = await model.createDomain(DNSCreateConfiguration(domain: try DNSDomainName(validating: "test"), localhostRedirect: nil))
        XCTAssertFalse(created)
        XCTAssertEqual(model.actionError, "cannot create domain (try sudo?)")
        XCTAssertEqual(log.records.count, 1)
        XCTAssertNil(model.activeMutation)
    }

    func testCLIServiceAsksForAdministratorAccessWithTheDomainInThePrompt() async throws {
        let runner = PrivilegedRunnerStub()
        let service = CLIDNSService(cli: DNSCLIStub(), executableURL: URL(fileURLWithPath: "/usr/local/bin/container"), privilegedRunner: runner)

        try await service.createDomain(DNSCreateConfiguration(domain: DNSDomainName(validating: "test"), localhostRedirect: DNSNameserver(validating: "192.168.64.1")))
        try await service.deleteDomain(DNSDeleteConfiguration(domain: DNSDomainName(validating: "test")))

        let commands = await runner.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.first?.arguments, ["system", "dns", "create", "test", "--localhost", "192.168.64.1"])
        XCTAssertEqual(commands.first?.executableURL.path, "/usr/local/bin/container")
        XCTAssertEqual(commands.first?.displayInvocation, "sudo /usr/local/bin/container system dns create test --localhost 192.168.64.1")
        XCTAssertEqual(commands.last?.arguments, ["system", "dns", "delete", "test"])
        XCTAssertTrue(commands.allSatisfy { $0.prompt.contains("test") })
    }

    func testCLIServiceReportsADismissedDialogAsCancelled() async throws {
        let service = CLIDNSService(cli: DNSCLIStub(), executableURL: URL(fileURLWithPath: "/usr/local/bin/container"), privilegedRunner: PrivilegedRunnerStub(error: .cancelled))
        do {
            try await service.deleteDomain(DNSDeleteConfiguration(domain: DNSDomainName(validating: "test")))
            XCTFail("Expected the cancellation to be rethrown")
        } catch let error as PrivilegedCommandError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testPrivilegedScriptQuotesEveryWordAndPinsTheEnvironment() throws {
        let command = PrivilegedCommand(executableURL: URL(fileURLWithPath: "/Users/dev/tools/my container/container"), arguments: ["system", "dns", "create", "test"], prompt: "Add “test”")
        let shell = OSAScriptPrivilegedCommandRunner.shellCommand(for: command, homeDirectory: "/Users/dev")

        XCTAssertEqual(shell, "'/usr/bin/env' 'HOME=/Users/dev' 'PATH=\(OSAScriptPrivilegedCommandRunner.path)' '/Users/dev/tools/my container/container' 'system' 'dns' 'create' 'test'")

        let script = OSAScriptPrivilegedCommandRunner.script(for: command, homeDirectory: "/Users/dev")
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        XCTAssertTrue(script.contains("with prompt \"Add “test”\""))
    }

    func testPrivilegedQuotingSurvivesQuotesAndBackslashes() {
        XCTAssertEqual(OSAScriptPrivilegedCommandRunner.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(OSAScriptPrivilegedCommandRunner.quoted("$(whoami); echo hi"), "'$(whoami); echo hi'")
        XCTAssertEqual(OSAScriptPrivilegedCommandRunner.literal(#"say "hi" \ now"#), #""say \"hi\" \\ now""#)
    }

    func testPrivilegedFailuresAreClassified() {
        XCTAssertEqual(
            OSAScriptPrivilegedCommandRunner.failure(standardError: "34:107: execution error: User canceled. (-128)", exitCode: 1, invocation: "sudo container"),
            .cancelled
        )
        XCTAssertEqual(
            OSAScriptPrivilegedCommandRunner.failure(standardError: "34:107: execution error: cannot create domain (try sudo?) (1)\n", exitCode: 1, invocation: "sudo container"),
            .failed(invocation: "sudo container", exitCode: 1, message: "cannot create domain (try sudo?)")
        )
        XCTAssertEqual(
            OSAScriptPrivilegedCommandRunner.failure(standardError: "osascript: no such file", exitCode: 2, invocation: "sudo container"),
            .failed(invocation: "sudo container", exitCode: 2, message: "osascript: no such file")
        )
    }

    @MainActor
    func testDNSModelRecordsRefreshFailure() async {
        let log = OperationFailureLog()
        let model = DNSModel(service: DNSServiceStub(error: CLIError.invalidOutput(description: "bad")), resolverReader: ResolverReaderStub(files: []), hostResolver: HostResolverStub(), failureLog: log)
        await model.refresh()
        if case .failed = model.listState {} else { XCTFail("Expected failed state") }
        XCTAssertEqual(log.records.count, 1)
    }
}

private actor DNSServiceStub: DNSManaging {
    let error: Error?
    private var mutationError: Error?
    private(set) var domains: [String]
    private(set) var createdConfigurations: [DNSCreateConfiguration] = []
    private(set) var deletedConfigurations: [DNSDeleteConfiguration] = []

    /// The domain the service reports, which is the one it loaded at start and
    /// so can lag behind what `config.toml` now says. Defaults to tracking the
    /// resolver list, which is what most of these tests want.
    private let reportedServiceDomain: String?
    private let reportsFirstDomain: Bool

    init(error: Error? = nil, mutationError: Error? = nil, domains: [String] = ["cont"]) {
        self.error = error
        self.mutationError = mutationError
        self.domains = domains
        reportedServiceDomain = nil
        reportsFirstDomain = true
    }

    init(domains: [String], serviceDomain: String?) {
        error = nil
        mutationError = nil
        self.domains = domains
        reportedServiceDomain = serviceDomain
        reportsFirstDomain = false
    }

    func listDomains() async throws -> [String] { if let error { throw error }; return domains }
    func loadServiceDomain() async throws -> String? {
        if let error { throw error }
        return reportsFirstDomain ? domains.first : reportedServiceDomain
    }

    func createDomain(_ configuration: DNSCreateConfiguration) async throws {
        createdConfigurations.append(configuration)
        if let mutationError { throw mutationError }
        if !domains.contains(configuration.domain.rawValue) { domains.append(configuration.domain.rawValue) }
    }

    func deleteDomain(_ configuration: DNSDeleteConfiguration) async throws {
        deletedConfigurations.append(configuration)
        if let mutationError { throw mutationError }
        domains.removeAll { $0 == configuration.domain.rawValue }
    }
}

private final class ConfigFileStub: ServiceDomainWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error?
    private var written: [String] = []

    init(error: Error? = nil) { self.error = error }

    var writtenDomains: [String] { lock.withLock { written } }

    func writeServiceDomain(_ domain: DNSDomainName) throws -> URL {
        if let error { throw error }
        lock.withLock { written.append(domain.rawValue) }
        return URL(fileURLWithPath: "/tmp/config.toml")
    }
}

private actor PrivilegedRunnerStub: PrivilegedCommandRunning {
    private(set) var commands: [PrivilegedCommand] = []
    private let error: PrivilegedCommandError?

    init(error: PrivilegedCommandError? = nil) { self.error = error }

    func run(_ command: PrivilegedCommand) async throws -> String {
        commands.append(command)
        if let error { throw error }
        return ""
    }
}

private struct ResolverReaderStub: ResolverDirectoryReading {
    let files: [ResolverFile]
    func resolverFiles() -> [ResolverFile] { files }
    func configFileURL() -> URL { URL(fileURLWithPath: "/tmp/config.toml") }
}

private struct HostResolverStub: HostResolving {
    func resolve(_ host: String) async -> DNSProbeResult { .resolved(address: "127.0.0.1", duration: .milliseconds(1)) }
}

private actor DNSCLIStub: ContainerCLI {
    func run(_ command: ContainerCommand) async throws -> CommandResult {
        let output = command == .systemDNSList ? #"["cont"]"# : #"{"dns":{"domain":"cont"}}"#
        return CommandResult(standardOutput: output, standardError: "", exitCode: 0, duration: .zero, invocation: "container")
    }
    nonisolated func stream(_ command: ContainerCommand) -> AsyncThrowingStream<ProcessEvent, Error> { AsyncThrowingStream { $0.finish() } }
}
