import Foundation
import Observation

nonisolated enum MachineListState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

nonisolated enum MachineInspectionState: Equatable, Sendable {
    case idle
    case loading
    case loaded(MachineInspection)
    case failed(String)
}

nonisolated enum MachineMutation: Equatable, Sendable {
    case create(String)
    case applyConfiguration(String)
    case setDefault(String)
    case stop(String)
    case delete(String)
}

@MainActor
@Observable
final class MachineModel {
    var searchText = "" { didSet { updateFilteredMachines() } }
    var selectedMachineID: String?

    private(set) var machines: [MachineSummary] = [] { didSet { updateFilteredMachines() } }
    private(set) var filteredMachines: [MachineSummary] = []
    private(set) var listState: MachineListState = .idle
    private(set) var inspectionState: MachineInspectionState = .idle
    private(set) var activeMutation: MachineMutation?
    private(set) var mutationFailure: String?

    /// `machine set` writes boot config immediately but the machine keeps
    /// running on its old values until it restarts, and `machine inspect`
    /// reports only the stored values — there is no live-vs-stored pair in the
    /// payload. So the pending set is remembered here, keyed by machine, and
    /// cleared when that machine is next seen stopped.
    private(set) var pendingRestartSettings: [String: MachineBootConfiguration] = [:]

    private let service: any MachineManaging
    private let failureLog: OperationFailureLog
    private var refreshGeneration = 0
    private var inspectionGeneration = 0

    init(service: any MachineManaging, failureLog: OperationFailureLog? = nil) {
        self.service = service
        self.failureLog = failureLog ?? OperationFailureLog()
    }

    var selectedMachine: MachineSummary? {
        guard let selectedMachineID else { return nil }
        return machines.first { $0.id == selectedMachineID }
    }

    var defaultMachine: MachineSummary? {
        machines.first(where: \.isDefault)
    }

    var runningCount: Int {
        machines.filter { $0.state == .running }.count
    }

    var stoppedCount: Int {
        machines.filter { $0.state != .running }.count
    }

    var isInspectorPresented: Bool {
        get { selectedMachineID != nil }
        set {
            if !newValue {
                selectedMachineID = nil
                inspectionGeneration += 1
                inspectionState = .idle
            }
        }
    }

    var isBusy: Bool { activeMutation != nil }

    func pendingSettings(for machineID: String) -> MachineBootConfiguration? {
        pendingRestartSettings[machineID]
    }

    /// The run sheet needs the service to attach a pseudo-terminal, and the
    /// machine's state to know whether it will have to boot on the way in.
    func makeRunModel(for machineID: String) -> MachineRunModel {
        MachineRunModel(
            machineID: machineID,
            isRunning: machines.first { $0.id == machineID }?.state == .running,
            service: service
        )
    }

    func makeLogsModel(for machineID: String) -> MachineLogsModel {
        MachineLogsModel(machineID: machineID, service: service)
    }

    func loadIfNeeded() async {
        guard listState == .idle else { return }
        await refresh()
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        listState = .loading
        do {
            let refreshed = try await service.listMachines()
            guard generation == refreshGeneration else { return }
            machines = refreshed
            clearSettledPendingSettings(against: refreshed)
            if let selectedMachineID,
               !refreshed.contains(where: { $0.id == selectedMachineID }) {
                self.selectedMachineID = nil
                inspectionGeneration += 1
                inspectionState = .idle
            }
            listState = .loaded
        } catch is CancellationError {
            guard generation == refreshGeneration else { return }
            listState = machines.isEmpty ? .idle : .loaded
        } catch CLIError.cancelled {
            guard generation == refreshGeneration else { return }
            listState = machines.isEmpty ? .idle : .loaded
        } catch {
            guard generation == refreshGeneration else { return }
            failureLog.record(operation: "Refresh machines", error: error)
            listState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    func inspectSelection() async {
        inspectionGeneration += 1
        let generation = inspectionGeneration
        guard let selectedMachine else {
            inspectionState = .idle
            return
        }
        inspectionState = .loading
        do {
            let inspection = try await service.inspectMachine(name: selectedMachine.id)
            guard generation == inspectionGeneration,
                  selectedMachineID == selectedMachine.id else { return }
            inspectionState = .loaded(inspection)
        } catch is CancellationError {
            guard generation == inspectionGeneration else { return }
            inspectionState = .idle
        } catch CLIError.cancelled {
            guard generation == inspectionGeneration else { return }
            inspectionState = .idle
        } catch {
            guard generation == inspectionGeneration,
                  selectedMachineID == selectedMachine.id else { return }
            failureLog.record(operation: "Inspect machine", error: error)
            inspectionState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    @discardableResult
    func create(_ configuration: MachineCreateConfiguration) async -> Bool {
        await mutate(
            .create(configuration.name?.rawValue ?? configuration.image.rawValue),
            operation: "Create machine"
        ) { [service] in
            let created = try await service.createMachine(configuration)
            return created
        } onSuccess: { [weak self] created in
            guard let self else { return }
            await refresh()
            if !created.isEmpty, machines.contains(where: { $0.id == created }) {
                selectedMachineID = created
                await inspectSelection()
            }
        }
    }

    @discardableResult
    func applyBootConfiguration(
        machineID: String,
        boot: MachineBootConfiguration
    ) async -> Bool {
        guard let configuration = try? MachineSetConfiguration(name: machineID, boot: boot) else {
            mutationFailure = "Those machine settings are not valid."
            return false
        }
        return await mutate(
            .applyConfiguration(machineID),
            operation: "Apply machine configuration"
        ) { [service] in
            try await service.applyBootConfiguration(configuration)
        } onSuccess: { [weak self] _ in
            guard let self else { return }
            // Only a running machine defers the change; a stopped one picks the
            // new values up on its next boot, so there is nothing pending.
            if machines.first(where: { $0.id == machineID })?.state == .running {
                pendingRestartSettings[machineID] = boot
            }
            await refresh()
            if selectedMachineID == machineID { await inspectSelection() }
        }
    }

    @discardableResult
    func setDefault(machineID: String) async -> Bool {
        await mutate(.setDefault(machineID), operation: "Set default machine") { [service] in
            try await service.setDefaultMachine(name: machineID)
        } onSuccess: { [weak self] _ in
            await self?.refresh()
        }
    }

    @discardableResult
    func stop(machineID: String) async -> Bool {
        await mutate(.stop(machineID), operation: "Stop machine") { [service] in
            try await service.stopMachine(name: machineID)
        } onSuccess: { [weak self] _ in
            guard let self else { return }
            // Stopping is what applies a pending boot config, so it settles here.
            pendingRestartSettings.removeValue(forKey: machineID)
            await refresh()
            if selectedMachineID == machineID { await inspectSelection() }
        }
    }

    @discardableResult
    func delete(machineID: String) async -> Bool {
        await mutate(.delete(machineID), operation: "Delete machine") { [service] in
            try await service.deleteMachine(name: machineID)
        } onSuccess: { [weak self] _ in
            guard let self else { return }
            pendingRestartSettings.removeValue(forKey: machineID)
            if selectedMachineID == machineID {
                selectedMachineID = nil
                inspectionGeneration += 1
                inspectionState = .idle
            }
            await refresh()
        }
    }

    func dismissMutationFailure() { mutationFailure = nil }

    /// One definition of "run a mutation, log what failed, never leave the model
    /// busy" — the five machine mutations differ only in their command.
    private func mutate<Value>(
        _ mutation: MachineMutation,
        operation: String,
        body: @Sendable () async throws -> Value,
        onSuccess: (Value) async -> Void
    ) async -> Bool {
        guard activeMutation == nil else { return false }
        activeMutation = mutation
        mutationFailure = nil
        defer { activeMutation = nil }
        do {
            let value = try await body()
            await onSuccess(value)
            return true
        } catch is CancellationError {
            return false
        } catch CLIError.cancelled {
            return false
        } catch {
            failureLog.record(operation: operation, error: error)
            mutationFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return false
        }
    }

    /// A machine that is no longer running has taken its pending settings, and
    /// one that has gone away cannot have any.
    private func clearSettledPendingSettings(against refreshed: [MachineSummary]) {
        guard !pendingRestartSettings.isEmpty else { return }
        let stillPending = Set(
            refreshed.filter { $0.state == .running }.map(\.id)
        )
        pendingRestartSettings = pendingRestartSettings.filter { stillPending.contains($0.key) }
    }

    private func updateFilteredMachines() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredMachines = machines
            return
        }
        filteredMachines = machines.filter { machine in
            [machine.id, machine.address].compactMap { $0 }.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }
}
