import Foundation
import XCTest
@testable import Container_GUI

final class NetworkManagementTests: XCTestCase {
    func testNetworkValidationAndAttachmentSerialization() throws {
        for valid in ["a", "default", "team.web_2", String(repeating: "a", count: 63)] {
            XCTAssertNoThrow(try NetworkName(validating: valid))
        }
        for invalid in [
            "", "-network", "network-", "UPPER", "has space", "has/slash",
            String(repeating: "a", count: 64),
        ] {
            XCTAssertThrowsError(try NetworkName(validating: invalid), "Accepted \(invalid)")
        }

        XCTAssertEqual(
            try NetworkCIDR(validating: "192.168.10.1/024").rawValue,
            "192.168.10.1/024"
        )
        XCTAssertEqual(try NetworkCIDR(validating: "fd00::1/64").family, .ipv6)
        for invalid in ["192.168.1.1", "999.1.1.1/24", "10.0.0.0/33", "fd00::/129"] {
            XCTAssertThrowsError(try NetworkCIDR(validating: invalid))
        }

        let attachment = try NetworkAttachment(
            network: "team-net",
            macAddress: "aa:bb:cc:dd:ee:ff",
            mtu: 1_500
        )
        XCTAssertEqual(attachment.argument, "team-net,mac=AA:BB:CC:DD:EE:FF,mtu=1500")
        XCTAssertThrowsError(try NetworkAttachment(network: "team-net", macAddress: "bad"))
        XCTAssertThrowsError(try NetworkAttachment(network: "team-net", mtu: 1_279))
        XCTAssertThrowsError(try NetworkAttachment(network: "team-net", mtu: 65_536))
    }

    func testNetworkKeyValueValidation() throws {
        XCTAssertEqual(try NetworkKeyValue(key: "purpose", value: "team network").argument, "purpose=team network")
        for key in ["", "has space", "has=equals", "line\nbreak"] {
            XCTAssertThrowsError(try NetworkKeyValue(key: key, value: "value"))
        }
        XCTAssertThrowsError(try NetworkKeyValue(key: "valid", value: "line\nbreak"))

        let duplicate = try NetworkKeyValue(key: "same", value: "one")
        XCTAssertThrowsError(try NetworkCreateConfiguration(
            name: "duplicate-test",
            labels: [duplicate, try NetworkKeyValue(key: "same", value: "two")],
            customization: .options([])
        ))
    }

    func testNetworkCommandArgumentsAndVersionSpecificCreateOrdering() throws {
        let name = try NetworkName(validating: "team-net")
        XCTAssertEqual(ContainerCommand.listNetworks.arguments, ["network", "list", "--format", "json"])
        XCTAssertEqual(ContainerCommand.inspectNetwork(name: name).arguments, ["network", "inspect", "team-net"])
        XCTAssertEqual(ContainerCommand.deleteNetwork(name: name).arguments, ["network", "delete", "team-net"])
        XCTAssertEqual(ContainerCommand.pruneNetworks.arguments, ["network", "prune"])

        let labels = [
            try NetworkKeyValue(key: "owner", value: "platform team"),
            try NetworkKeyValue(key: "purpose", value: "tests"),
        ]
        let options = [
            try NetworkKeyValue(key: "bridge", value: "custom bridge"),
            try NetworkKeyValue(key: "isolation", value: "strict"),
        ]
        let current = try NetworkCreateConfiguration(
            name: "team-net",
            mode: .internal,
            ipv4Subnet: "10.20.0.0/16",
            ipv6Subnet: "fd20::/64",
            labels: labels,
            plugin: "custom-plugin",
            customization: .options(options)
        )
        XCTAssertEqual(
            ContainerCommand.createNetwork(configuration: current).arguments,
            [
                "network", "create", "--internal",
                "--label", "owner=platform team", "--label", "purpose=tests",
                "--option", "bridge=custom bridge", "--option", "isolation=strict",
                "--plugin", "custom-plugin",
                "--subnet", "10.20.0.0/16", "--subnet-v6", "fd20::/64",
                "team-net",
            ]
        )

        let legacy = try NetworkCreateConfiguration(
            name: "legacy-net",
            plugin: "legacy-plugin",
            customization: .legacyVariant("shared vmnet")
        )
        XCTAssertEqual(
            ContainerCommand.createNetwork(configuration: legacy).arguments,
            [
                "network", "create", "--plugin-variant", "shared vmnet",
                "--plugin", "legacy-plugin", "legacy-net",
            ]
        )
    }

    func testCapabilitiesSplitAtOneDotZero() throws {
        XCTAssertEqual(
            NetworkCapabilities(version: try SemanticVersion("0.12.0")).pluginCustomization,
            .legacyVariant
        )
        XCTAssertEqual(
            NetworkCapabilities(version: try SemanticVersion("1.2.2")).pluginCustomization,
            .options
        )
    }

    func testDecodesLegacyAndCurrentNetworkFamilies() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(NetworkDTO.self, from: Data(Self.legacyJSON.utf8))
        let legacySummary = try XCTUnwrap(NetworkSummary(dto: legacy))
        XCTAssertEqual(legacySummary.name, "legacy-net")
        XCTAssertEqual(legacySummary.state, .inactive)
        XCTAssertEqual(legacySummary.ipv4Subnet, "10.10.0.0/24")
        XCTAssertEqual(legacySummary.gateway, "10.10.0.1")
        XCTAssertEqual(legacySummary.plugin, "vmnet")
        XCTAssertEqual(legacy.configuration?.pluginInfo?.variant, "shared")

        let current = try decoder.decode(NetworkDTO.self, from: Data(Self.currentJSON.utf8))
        let currentSummary = try XCTUnwrap(NetworkSummary(dto: current))
        XCTAssertEqual(currentSummary.name, "current-net")
        XCTAssertEqual(currentSummary.state, .active)
        XCTAssertEqual(currentSummary.ipv6Subnet, "fd42::/64")
        XCTAssertEqual(currentSummary.pluginOptions["isolation"], "strict")
        XCTAssertTrue(currentSummary.isBuiltIn)

        let defaultDTO = try decoder.decode(
            NetworkDTO.self,
            from: Data(#"{"id":"default","configuration":{"name":"default"}}"#.utf8)
        )
        XCTAssertTrue(try XCTUnwrap(NetworkSummary(dto: defaultDTO)).isBuiltIn)
    }

    func testServiceUsesAuthoritativeCommandsAndParsesPrune() async throws {
        let cli = NetworkCLIStub(outputs: [
            (.listNetworks, "[\(Self.currentJSON)]"),
            (.pruneNetworks, " first-net \n\nsecond-net\n"),
        ])
        let service = CLINetworkService(cli: cli)

        let listedNames = try await service.listNetworks().map(\.name)
        let prunedNames = try await service.pruneNetworks()
        XCTAssertEqual(listedNames, ["current-net"])
        XCTAssertEqual(prunedNames, ["first-net", "second-net"])
        let commands = await cli.commands
        XCTAssertEqual(commands, [.listNetworks, .pruneNetworks])

        let emptyCLI = NetworkCLIStub(outputs: [(.pruneNetworks, " \n\n")])
        let emptyResult = try await CLINetworkService(cli: emptyCLI).pruneNetworks()
        XCTAssertEqual(emptyResult, [])
    }

    func testServiceAcceptsSingleAndArrayInspectionButRejectsMismatch() async throws {
        let name = try NetworkName(validating: "current-net")
        let singleCLI = NetworkCLIStub(outputs: [
            (.inspectNetwork(name: name), Self.currentJSON),
        ])
        let inspection = try await CLINetworkService(cli: singleCLI)
            .inspectNetwork(name: "current-net")
        XCTAssertEqual(inspection.summary.name, "current-net")

        let mismatchCLI = NetworkCLIStub(outputs: [
            (.inspectNetwork(name: name), "[\(Self.legacyJSON)]"),
        ])
        do {
            _ = try await CLINetworkService(cli: mismatchCLI)
                .inspectNetwork(name: "current-net")
            XCTFail("Expected mismatched inspection to fail")
        } catch let error as CLIError {
            guard case .invalidOutput = error else {
                return XCTFail("Unexpected CLI error: \(error)")
            }
        }
    }

    @MainActor
    func testNetworkModelSearchMutationAndBuiltInDeletionGuard() async throws {
        let service = NetworkServiceStub(networks: [
            try Self.summary(from: Self.currentJSON),
            try Self.summary(from: Self.userJSON),
        ])
        let model = NetworkModel(
            service: service,
            capabilities: NetworkCapabilities(version: try SemanticVersion("1.2.2"))
        )
        await model.refresh()
        model.searchText = "strict"
        XCTAssertEqual(model.filteredNetworks.map(\.name), ["current-net"])

        await model.delete(networkID: "current-id")
        let deletedBuiltIns = await service.deletedNames
        XCTAssertEqual(deletedBuiltIns, [])
        XCTAssertEqual(model.mutationFailure, "Built-in networks cannot be deleted.")

        model.searchText = ""
        model.selectedNetworkID = "user-id"
        await model.delete(networkID: "user-id")
        XCTAssertNil(model.selectedNetworkID)
        let deletedNames = await service.deletedNames
        XCTAssertEqual(deletedNames, ["user-net"])
    }

    @MainActor
    func testNetworkModelCreateSelectsInspectsAndPruneRefreshes() async throws {
        let service = NetworkServiceStub(networks: [try Self.summary(from: Self.currentJSON)])
        let model = NetworkModel(
            service: service,
            capabilities: NetworkCapabilities(version: try SemanticVersion("1.2.2"))
        )
        await model.refresh()

        let configuration = try NetworkCreateConfiguration(
            name: "created-net",
            customization: .options([])
        )
        let created = await model.create(configuration)
        XCTAssertTrue(created)
        XCTAssertEqual(model.selectedNetwork?.name, "created-net")
        guard case .loaded(let inspection) = model.inspectionState else {
            return XCTFail("The newly created network should be inspected.")
        }
        XCTAssertEqual(inspection.summary.name, "created-net")

        await model.prune()
        XCTAssertEqual(model.lastPruneResult, ["created-net"])
        XCTAssertEqual(model.networks.map(\.name), ["current-net"])
        XCTAssertNil(model.selectedNetworkID)
    }

    @MainActor
    func testRunDraftRequiresUniqueAvailableNetworks() async throws {
        let networkService = NetworkServiceStub(networks: [try Self.summary(from: Self.userJSON)])
        let networkModel = NetworkModel(
            service: networkService,
            capabilities: NetworkCapabilities(version: try SemanticVersion("1.2.2"))
        )
        await networkModel.refresh()
        let runModel = RunContainerModel(image: "alpine:3.21", networkModel: networkModel)
        runModel.networks = [
            NetworkAttachmentDraft(
                networkName: "user-net",
                macAddress: "aa:bb:cc:dd:ee:ff",
                mtu: "1500"
            ),
        ]
        XCTAssertEqual(
            runModel.configuration?.networks.first?.argument,
            "user-net,mac=AA:BB:CC:DD:EE:FF,mtu=1500"
        )
        XCTAssertTrue(runModel.commandPreview.contains("--network"))

        runModel.networks.append(NetworkAttachmentDraft(networkName: "user-net"))
        XCTAssertNil(runModel.configuration)
        XCTAssertNotNil(runModel.networkError(for: runModel.networks[0]))
    }

    func testRunConfigurationEmitsMultipleNetworksBeforePortsAndPreservesZeroAttachmentBehavior() throws {
        let first = try NetworkAttachment(network: "first-net")
        let second = try NetworkAttachment(
            network: "second-net",
            macAddress: "02:00:00:00:00:02",
            mtu: 9_000
        )
        let port = try PortMapping(hostPort: 8_080, containerPort: 80)
        let variable = try EnvironmentVariable(key: "MODE", value: "test")
        let configured = try RunConfiguration(
            image: "alpine:3.21",
            networks: [first, second],
            ports: [port],
            environment: [variable]
        )
        XCTAssertEqual(
            configured.arguments,
            [
                "run", "--progress", "plain", "--detach",
                "--network", "first-net",
                "--network", "second-net,mac=02:00:00:00:00:02,mtu=9000",
                "--publish", "8080:80",
                "--env", "MODE=test",
                "alpine:3.21",
            ]
        )

        let implicitDefault = try RunConfiguration(image: "alpine:3.21")
        XCTAssertFalse(implicitDefault.arguments.contains("--network"))
    }

    private static func summary(from json: String) throws -> NetworkSummary {
        let dto = try JSONDecoder().decode(NetworkDTO.self, from: Data(json.utf8))
        return try XCTUnwrap(NetworkSummary(dto: dto))
    }

    private static let legacyJSON = #"{"id":"legacy-net","state":"inactive","config":{"id":"legacy-net","mode":"nat","creationDate":"2026-06-01T10:11:12Z","ipv4Subnet":"10.10.0.0/24","labels":{"team":"legacy"},"pluginInfo":{"plugin":"vmnet","variant":"shared"}},"status":{"address":"10.10.0.0/24","gateway":"10.10.0.1","future":"ignored"},"unknown":true}"#
    private static let currentJSON = #"{"id":"current-id","configuration":{"name":"current-net","mode":"internal","creationDate":"2026-06-01T10:11:12.345Z","labels":{"com.apple.container.resource.role":"builtin"},"plugin":"container-network-vmnet","options":{"isolation":"strict"}},"status":{"ipv4Subnet":"10.42.0.0/24","ipv4Gateway":"10.42.0.1","ipv6Subnet":"fd42::/64"},"future":{"ignored":true}}"#
    private static let userJSON = #"{"id":"user-id","configuration":{"name":"user-net","mode":"nat","plugin":"container-network-vmnet"},"status":{"ipv4Subnet":"10.50.0.0/24"}}"#
}

private actor NetworkCLIStub: ContainerCLI {
    private let outputs: [(ContainerCommand, String)]
    private(set) var commands: [ContainerCommand] = []

    init(outputs: [(ContainerCommand, String)]) {
        self.outputs = outputs
    }

    func run(_ command: ContainerCommand) throws -> CommandResult {
        commands.append(command)
        return CommandResult(
            standardOutput: outputs.first(where: { $0.0 == command })?.1 ?? "",
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

private actor NetworkServiceStub: NetworkManaging {
    private var storedNetworks: [NetworkSummary]
    private(set) var deletedNames: [String] = []

    init(networks: [NetworkSummary]) {
        storedNetworks = networks
    }

    func listNetworks() -> [NetworkSummary] { storedNetworks }

    func inspectNetwork(name: String) throws -> NetworkInspection {
        guard let network = storedNetworks.first(where: { $0.name == name }) else {
            throw CLIError.invalidOutput(description: "missing")
        }
        let raw = #"{"id":"\#(network.id)","configuration":{"name":"\#(network.name)"}}"#
        let dto = try JSONDecoder().decode(NetworkDTO.self, from: Data(raw.utf8))
        return NetworkInspection(dto: dto, rawJSON: raw)!
    }

    func createNetwork(_ configuration: NetworkCreateConfiguration) throws {
        let name = configuration.name.rawValue
        let raw = #"{"id":"\#(name)","configuration":{"name":"\#(name)","mode":"\#(configuration.mode.rawValue)","plugin":"container-network-vmnet"},"status":{"ipv4Subnet":"10.99.0.0/24"}}"#
        let dto = try JSONDecoder().decode(NetworkDTO.self, from: Data(raw.utf8))
        if let network = NetworkSummary(dto: dto) {
            storedNetworks.append(network)
        }
    }

    func deleteNetwork(name: String) {
        deletedNames.append(name)
        storedNetworks.removeAll { $0.name == name }
    }

    func pruneNetworks() -> [String] {
        let deleted = storedNetworks.filter { !$0.isBuiltIn }.map(\.name)
        storedNetworks.removeAll { !$0.isBuiltIn }
        return deleted
    }
}
