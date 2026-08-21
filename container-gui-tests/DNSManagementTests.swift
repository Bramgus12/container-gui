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
        let service = CLIDNSService(cli: DNSCLIStub())
        XCTAssertEqual(try await service.listDomains(), ["cont"])
        XCTAssertEqual(try await service.loadServiceDomain(), "cont")
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
    init(error: Error? = nil) { self.error = error }
    func listDomains() async throws -> [String] { if let error { throw error }; return ["cont"] }
    func loadServiceDomain() async throws -> String? { if let error { throw error }; return "cont" }
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
