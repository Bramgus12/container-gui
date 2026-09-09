import Foundation
import XCTest
@testable import CargoDeck

@MainActor
final class MachineModelTests: XCTestCase {

    func testRefreshLoadsMachinesAndIdentifiesTheDefault() async {
        let service = MachineServiceStub()
        let model = MachineModel(service: service)

        await model.refresh()

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.machines.map(\.id), ["running-box", "stopped-box"])
        XCTAssertEqual(model.defaultMachine?.id, "running-box")
        XCTAssertEqual(model.runningCount, 1)
        XCTAssertEqual(model.stoppedCount, 1)
    }

    func testSearchFiltersOnNameAndAddress() async {
        let model = MachineModel(service: MachineServiceStub())
        await model.refresh()

        model.searchText = "stopped"
        XCTAssertEqual(model.filteredMachines.map(\.id), ["stopped-box"])

        model.searchText = "192.168.64.10"
        XCTAssertEqual(model.filteredMachines.map(\.id), ["running-box"])

        model.searchText = ""
        XCTAssertEqual(model.filteredMachines.count, 2)
    }

    /// `machine set` writes immediately but a running machine keeps its old
    /// values until it restarts, and `machine inspect` reports only the stored
    /// values — so the pending set has to be tracked in the app.
    func testApplyingConfigurationToARunningMachineLeavesItPending() async {
        let service = MachineServiceStub()
        let model = MachineModel(service: service)
        await model.refresh()

        let applied = await model.applyBootConfiguration(
            machineID: "running-box",
            boot: MachineBootConfiguration(cpus: try? MachineCPUCount(8))
        )

        XCTAssertTrue(applied)
        XCTAssertNotNil(model.pendingSettings(for: "running-box"))
        XCTAssertEqual(service.appliedSettings, ["cpus=8"])
    }

    /// A stopped machine picks the new values up on its next boot, so nothing is
    /// deferred and nothing should be flagged.
    func testApplyingConfigurationToAStoppedMachineIsNotPending() async {
        let model = MachineModel(service: MachineServiceStub())
        await model.refresh()

        await model.applyBootConfiguration(
            machineID: "stopped-box",
            boot: MachineBootConfiguration(homeMount: .readOnly)
        )

        XCTAssertNil(model.pendingSettings(for: "stopped-box"))
    }

    func testStoppingAMachineSettlesItsPendingConfiguration() async {
        let service = MachineServiceStub()
        let model = MachineModel(service: service)
        await model.refresh()

        await model.applyBootConfiguration(
            machineID: "running-box",
            boot: MachineBootConfiguration(cpus: try? MachineCPUCount(8))
        )
        XCTAssertNotNil(model.pendingSettings(for: "running-box"))

        await model.stop(machineID: "running-box")

        XCTAssertNil(model.pendingSettings(for: "running-box"))
        XCTAssertEqual(model.machines.first { $0.id == "running-box" }?.state, .stopped)
    }

    /// A machine that stopped by some other route — the CLI, a crash — has also
    /// taken its pending values, so a plain refresh must settle them too.
    func testARefreshThatFindsTheMachineStoppedClearsThePendingFlag() async {
        let service = MachineServiceStub()
        let model = MachineModel(service: service)
        await model.refresh()

        await model.applyBootConfiguration(
            machineID: "running-box",
            boot: MachineBootConfiguration(cpus: try? MachineCPUCount(8))
        )
        XCTAssertNotNil(model.pendingSettings(for: "running-box"))

        await service.stopOutOfBand("running-box")
        await model.refresh()

        XCTAssertNil(model.pendingSettings(for: "running-box"))
    }

    func testDeletingClearsSelectionAndPendingState() async {
        let model = MachineModel(service: MachineServiceStub())
        await model.refresh()
        model.selectedMachineID = "running-box"

        await model.applyBootConfiguration(
            machineID: "running-box",
            boot: MachineBootConfiguration(cpus: try? MachineCPUCount(8))
        )
        await model.delete(machineID: "running-box")

        XCTAssertNil(model.selectedMachineID)
        XCTAssertNil(model.pendingSettings(for: "running-box"))
        XCTAssertFalse(model.machines.contains { $0.id == "running-box" })
    }

    func testSetDefaultMovesTheStar() async {
        let model = MachineModel(service: MachineServiceStub())
        await model.refresh()

        await model.setDefault(machineID: "stopped-box")

        XCTAssertEqual(model.defaultMachine?.id, "stopped-box")
    }

    func testAFailingCommandSurfacesAndClears() async {
        let service = MachineServiceStub()
        await service.failEverything()
        let model = MachineModel(service: service)

        await model.refresh()
        guard case .failed(let message) = model.listState else {
            return XCTFail("Expected the list to report a failure, got \(model.listState).")
        }
        XCTAssertTrue(
            message.contains("Machine command failed."),
            "The CLI's own message should survive into the banner, got: \(message)"
        )

        let stopped = await model.stop(machineID: "running-box")
        XCTAssertFalse(stopped)
        XCTAssertNotNil(model.mutationFailure)

        model.dismissMutationFailure()
        XCTAssertNil(model.mutationFailure)
    }

    /// Applying an empty change would build a `machine set` with no settings,
    /// which the CLI rejects. It never reaches the service.
    func testAnEmptyConfigurationIsRefusedBeforeItReachesTheCLI() async {
        let service = MachineServiceStub()
        let model = MachineModel(service: service)
        await model.refresh()

        let applied = await model.applyBootConfiguration(
            machineID: "running-box",
            boot: MachineBootConfiguration()
        )

        XCTAssertFalse(applied)
        XCTAssertNotNil(model.mutationFailure)
        XCTAssertTrue(service.appliedSettings.isEmpty)
    }
}

private final class MachineServiceStub: MachineManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var machines: [(id: String, state: String, isDefault: Bool, address: String?)] = [
        ("running-box", "running", true, "192.168.64.10"),
        ("stopped-box", "stopped", false, nil),
    ]
    private var applied: [String] = []
    private var fails = false

    var appliedSettings: [String] { lock.withLock { applied } }

    func failEverything() { lock.withLock { fails = true } }

    func stopOutOfBand(_ id: String) {
        lock.withLock {
            guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
            machines[index].state = "stopped"
            machines[index].address = nil
        }
    }

    func listMachines() async throws -> [MachineSummary] {
        try checkFailure()
        return lock.withLock { machines }.map { machine in
            MachineSummary(
                id: machine.id,
                state: MachineState(machine.state),
                isDefault: machine.isDefault,
                address: machine.address,
                cpus: 4,
                memoryBytes: 4_294_967_296,
                diskBytes: 1_073_741_824,
                createdAt: Date(timeIntervalSinceReferenceDate: 0)
            )
        }
    }

    func inspectMachine(name: String) async throws -> MachineInspection {
        try checkFailure()
        let raw = #"{"id":"\#(name)","status":"running","cpus":4,"memory":4294967296}"#
        let dto = try JSONDecoder().decode(
            MachineInspectionDTO.self,
            from: Data(raw.utf8)
        )
        guard let inspection = MachineInspection(dto: dto, rawJSON: raw) else {
            throw CLIError.invalidOutput(description: "no machine")
        }
        return inspection
    }

    func createMachine(_ configuration: MachineCreateConfiguration) async throws -> String {
        try checkFailure()
        let name = configuration.name?.rawValue ?? "created"
        lock.withLock { machines.append((name, "running", false, "192.168.64.20")) }
        return name
    }

    func applyBootConfiguration(_ configuration: MachineSetConfiguration) async throws {
        try checkFailure()
        lock.withLock { applied.append(contentsOf: configuration.boot.settings) }
    }

    func setDefaultMachine(name: String) async throws {
        try checkFailure()
        lock.withLock {
            for index in machines.indices {
                machines[index].isDefault = machines[index].id == name
            }
        }
    }

    func stopMachine(name: String) async throws {
        try checkFailure()
        stopOutOfBand(name)
    }

    func deleteMachine(name: String) async throws {
        try checkFailure()
        lock.withLock { machines.removeAll { $0.id == name } }
    }

    nonisolated func streamLogs(
        _ options: MachineLogOptions
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.standardOutput("machine log line\n"))
            continuation.yield(.terminated(exitCode: 0))
            continuation.finish()
        }
    }

    nonisolated func attachRun(
        _ configuration: MachineRunConfiguration,
        terminalSize: TerminalSize
    ) throws -> any InteractiveProcessSession {
        throw CLIError.launchFailed(message: "Interactive sessions are not available in tests.")
    }

    private func checkFailure() throws {
        if lock.withLock({ fails }) {
            throw CLIError.invalidOutput(description: "Machine command failed.")
        }
    }
}
