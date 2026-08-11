import Foundation
import Observation

nonisolated enum NetworkListState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

nonisolated enum NetworkInspectionState: Equatable, Sendable {
    case idle
    case loading
    case loaded(NetworkInspection)
    case failed(String)
}

nonisolated enum NetworkMutation: Equatable, Sendable {
    case create(String)
    case delete(String)
    case prune
}

@MainActor
@Observable
final class NetworkModel {
    let capabilities: NetworkCapabilities

    var searchText = "" {
        didSet { updateFilteredNetworks() }
    }
    var selectedNetworkID: String?

    private(set) var networks: [NetworkSummary] = [] {
        didSet { updateFilteredNetworks() }
    }
    private(set) var filteredNetworks: [NetworkSummary] = []
    private(set) var listState: NetworkListState = .idle
    private(set) var inspectionState: NetworkInspectionState = .idle
    private(set) var activeMutation: NetworkMutation?
    private(set) var mutationFailure: String?
    private(set) var lastPruneResult: [String]?

    private let service: any NetworkManaging
    private let failureLog: OperationFailureLog
    private var refreshGeneration = 0
    private var inspectionGeneration = 0

    init(
        service: any NetworkManaging,
        capabilities: NetworkCapabilities,
        failureLog: OperationFailureLog? = nil
    ) {
        self.service = service
        self.capabilities = capabilities
        self.failureLog = failureLog ?? OperationFailureLog()
    }

    var selectedNetwork: NetworkSummary? {
        guard let selectedNetworkID else { return nil }
        return networks.first { $0.id == selectedNetworkID }
    }

    var isInspectorPresented: Bool {
        get { selectedNetworkID != nil }
        set {
            if !newValue {
                selectedNetworkID = nil
                inspectionGeneration += 1
                inspectionState = .idle
            }
        }
    }

    var isBusy: Bool { activeMutation != nil }

    func loadIfNeeded() async {
        guard listState == .idle else { return }
        await refresh()
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        listState = .loading

        do {
            let refreshed = try await service.listNetworks()
            guard generation == refreshGeneration else { return }
            networks = refreshed
            if let selectedNetworkID,
               !refreshed.contains(where: { $0.id == selectedNetworkID }) {
                self.selectedNetworkID = nil
                inspectionGeneration += 1
                inspectionState = .idle
            }
            listState = .loaded
        } catch is CancellationError {
            guard generation == refreshGeneration else { return }
            listState = networks.isEmpty ? .idle : .loaded
        } catch CLIError.cancelled {
            guard generation == refreshGeneration else { return }
            listState = networks.isEmpty ? .idle : .loaded
        } catch {
            guard generation == refreshGeneration else { return }
            failureLog.record(operation: "Refresh networks", error: error)
            listState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    func inspectSelection() async {
        inspectionGeneration += 1
        let generation = inspectionGeneration
        guard let selectedNetwork else {
            inspectionState = .idle
            return
        }
        let selectedID = selectedNetwork.id
        inspectionState = .loading

        do {
            let inspection = try await service.inspectNetwork(name: selectedNetwork.name)
            guard generation == inspectionGeneration,
                  selectedNetworkID == selectedID else { return }
            inspectionState = .loaded(inspection)
        } catch is CancellationError {
            guard generation == inspectionGeneration else { return }
            inspectionState = .idle
        } catch CLIError.cancelled {
            guard generation == inspectionGeneration else { return }
            inspectionState = .idle
        } catch {
            guard generation == inspectionGeneration,
                  selectedNetworkID == selectedID else { return }
            failureLog.record(operation: "Inspect network", error: error)
            inspectionState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    @discardableResult
    func create(_ configuration: NetworkCreateConfiguration) async -> Bool {
        guard activeMutation == nil else { return false }
        activeMutation = .create(configuration.name.rawValue)
        mutationFailure = nil
        lastPruneResult = nil
        defer { activeMutation = nil }

        do {
            try await service.createNetwork(configuration)
            await refresh()
            if let created = networks.first(where: { $0.name == configuration.name.rawValue }) {
                selectedNetworkID = created.id
                await inspectSelection()
            }
            return true
        } catch is CancellationError {
            return false
        } catch CLIError.cancelled {
            return false
        } catch {
            failureLog.record(operation: "Create network", error: error)
            mutationFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return false
        }
    }

    func delete(networkID: String) async {
        guard activeMutation == nil else { return }
        guard let network = networks.first(where: { $0.id == networkID }) else {
            mutationFailure = "The network changed. Refresh the list and try again."
            return
        }
        guard !network.isBuiltIn else {
            mutationFailure = "Built-in networks cannot be deleted."
            return
        }

        activeMutation = .delete(networkID)
        mutationFailure = nil
        lastPruneResult = nil
        defer { activeMutation = nil }
        do {
            try await service.deleteNetwork(name: network.name)
            if selectedNetworkID == networkID {
                selectedNetworkID = nil
                inspectionGeneration += 1
                inspectionState = .idle
            }
            await refresh()
        } catch is CancellationError {
            return
        } catch CLIError.cancelled {
            return
        } catch {
            failureLog.record(operation: "Delete network", error: error)
            mutationFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    func prune() async {
        guard activeMutation == nil else { return }
        activeMutation = .prune
        mutationFailure = nil
        lastPruneResult = nil
        defer { activeMutation = nil }
        do {
            lastPruneResult = try await service.pruneNetworks()
            await refresh()
        } catch is CancellationError {
            return
        } catch CLIError.cancelled {
            return
        } catch {
            failureLog.record(operation: "Prune networks", error: error)
            mutationFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    func dismissMutationFailure() {
        mutationFailure = nil
    }

    func dismissPruneResult() {
        lastPruneResult = nil
    }

    private func updateFilteredNetworks() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredNetworks = networks
            return
        }
        filteredNetworks = networks.filter { network in
            let dictionaryValues = network.labels.flatMap { [$0.key, $0.value] }
                + network.pluginOptions.flatMap { [$0.key, $0.value] }
            let searchableValues = [
                network.name,
                network.state.rawValue,
                network.mode,
                network.ipv4Subnet,
                network.ipv6Subnet,
                network.gateway,
                network.plugin,
            ]
            .compactMap { $0 }
                + dictionaryValues
            return searchableValues.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }
}
