import Foundation
import Observation

nonisolated enum VolumeListState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

nonisolated enum VolumeInspectionState: Equatable, Sendable {
    case idle
    case loading
    case loaded(VolumeInspection)
    case failed(String)
}

nonisolated enum VolumeMutation: Equatable, Sendable {
    case create(String)
    case delete(String)
    case prune
}

@MainActor
@Observable
final class VolumeModel {
    var searchText = "" { didSet { updateFilteredVolumes() } }
    var selectedVolumeID: String?

    private(set) var volumes: [VolumeSummary] = [] { didSet { updateFilteredVolumes() } }
    private(set) var filteredVolumes: [VolumeSummary] = []
    private(set) var listState: VolumeListState = .idle
    private(set) var inspectionState: VolumeInspectionState = .idle
    private(set) var activeMutation: VolumeMutation?
    private(set) var mutationFailure: String?
    private(set) var lastPruneResult: [String]?

    private let service: any VolumeManaging
    private let failureLog: OperationFailureLog
    private var refreshGeneration = 0
    private var inspectionGeneration = 0

    init(service: any VolumeManaging, failureLog: OperationFailureLog? = nil) {
        self.service = service
        self.failureLog = failureLog ?? OperationFailureLog()
    }

    var selectedVolume: VolumeSummary? {
        guard let selectedVolumeID else { return nil }
        return volumes.first { $0.id == selectedVolumeID }
    }

    var isInspectorPresented: Bool {
        get { selectedVolumeID != nil }
        set {
            if !newValue {
                selectedVolumeID = nil
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
            let refreshed = try await service.listVolumes()
            guard generation == refreshGeneration else { return }
            volumes = refreshed
            if let selectedVolumeID,
               !refreshed.contains(where: { $0.id == selectedVolumeID }) {
                self.selectedVolumeID = nil
                inspectionGeneration += 1
                inspectionState = .idle
            }
            listState = .loaded
        } catch is CancellationError {
            guard generation == refreshGeneration else { return }
            listState = volumes.isEmpty ? .idle : .loaded
        } catch CLIError.cancelled {
            guard generation == refreshGeneration else { return }
            listState = volumes.isEmpty ? .idle : .loaded
        } catch {
            guard generation == refreshGeneration else { return }
            failureLog.record(operation: "Refresh volumes", error: error)
            listState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    func inspectSelection() async {
        inspectionGeneration += 1
        let generation = inspectionGeneration
        guard let selectedVolume else {
            inspectionState = .idle
            return
        }
        inspectionState = .loading
        do {
            let inspection = try await service.inspectVolume(name: selectedVolume.name)
            guard generation == inspectionGeneration,
                  selectedVolumeID == selectedVolume.id else { return }
            inspectionState = .loaded(inspection)
        } catch is CancellationError {
            guard generation == inspectionGeneration else { return }
            inspectionState = .idle
        } catch CLIError.cancelled {
            guard generation == inspectionGeneration else { return }
            inspectionState = .idle
        } catch {
            guard generation == inspectionGeneration,
                  selectedVolumeID == selectedVolume.id else { return }
            failureLog.record(operation: "Inspect volume", error: error)
            inspectionState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    @discardableResult
    func create(_ configuration: VolumeCreateConfiguration) async -> Bool {
        guard activeMutation == nil else { return false }
        activeMutation = .create(configuration.name.rawValue)
        mutationFailure = nil
        lastPruneResult = nil
        defer { activeMutation = nil }
        do {
            try await service.createVolume(configuration)
            await refresh()
            if let created = volumes.first(where: { $0.name == configuration.name.rawValue }) {
                selectedVolumeID = created.id
                await inspectSelection()
            }
            return true
        } catch is CancellationError {
            return false
        } catch CLIError.cancelled {
            return false
        } catch {
            failureLog.record(operation: "Create volume", error: error)
            mutationFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return false
        }
    }

    func delete(volumeID: String) async {
        guard activeMutation == nil else { return }
        guard let volume = volumes.first(where: { $0.id == volumeID }) else {
            mutationFailure = "The volume changed. Refresh the list and try again."
            return
        }
        activeMutation = .delete(volumeID)
        mutationFailure = nil
        lastPruneResult = nil
        defer { activeMutation = nil }
        do {
            try await service.deleteVolume(name: volume.name)
            if selectedVolumeID == volumeID {
                selectedVolumeID = nil
                inspectionGeneration += 1
                inspectionState = .idle
            }
            await refresh()
        } catch is CancellationError {
            return
        } catch CLIError.cancelled {
            return
        } catch {
            failureLog.record(operation: "Delete volume", error: error)
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
            lastPruneResult = try await service.pruneVolumes()
            await refresh()
        } catch is CancellationError {
            return
        } catch CLIError.cancelled {
            return
        } catch {
            failureLog.record(operation: "Prune volumes", error: error)
            mutationFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    func dismissMutationFailure() { mutationFailure = nil }
    func dismissPruneResult() { lastPruneResult = nil }

    private func updateFilteredVolumes() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredVolumes = volumes
            return
        }
        filteredVolumes = volumes.filter { volume in
            let dictionaryValues = volume.labels.flatMap { [$0.key, $0.value] }
                + volume.options.flatMap { [$0.key, $0.value] }
            return ([
                volume.name,
                volume.driver,
                volume.format,
                volume.source,
            ].compactMap { $0 } + dictionaryValues).contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }
}
