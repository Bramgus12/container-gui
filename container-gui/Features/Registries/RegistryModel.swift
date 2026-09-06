import Foundation
import Observation

/// Registry logins as an inventory, following the same generation / state /
/// failure conventions as `VolumeModel` and `NetworkModel`.
///
/// The Apple Container CLI owns the credentials. This model never reads, writes,
/// or persists a Keychain entry, and never holds a password: the secret reaches
/// `login` as a parameter, is handed to the service, and goes out of scope.
@MainActor
@Observable
final class RegistryModel {
    var searchText = "" { didSet { updateFilteredRegistries() } }
    var selectedRegistryID: String?

    private(set) var registries: [RegistrySummary] = [] { didSet { updateFilteredRegistries() } }
    private(set) var filteredRegistries: [RegistrySummary] = []
    private(set) var listState: RegistryListState = .idle
    private(set) var activeMutation: RegistryMutation?
    private(set) var mutationFailure: String?

    private let service: any RegistryManaging
    private let failureLog: OperationFailureLog
    private var refreshGeneration = 0

    init(service: any RegistryManaging, failureLog: OperationFailureLog? = nil) {
        self.service = service
        self.failureLog = failureLog ?? OperationFailureLog()
    }

    var selectedRegistry: RegistrySummary? {
        guard let selectedRegistryID else { return nil }
        return registries.first { $0.id == selectedRegistryID }
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
            let refreshed = try await service.listRegistries()
            guard generation == refreshGeneration else { return }
            registries = refreshed
            if let selectedRegistryID,
               !refreshed.contains(where: { $0.id == selectedRegistryID }) {
                self.selectedRegistryID = nil
            }
            listState = .loaded
        } catch is CancellationError {
            guard generation == refreshGeneration else { return }
            listState = registries.isEmpty ? .idle : .loaded
        } catch CLIError.cancelled {
            guard generation == refreshGeneration else { return }
            listState = registries.isEmpty ? .idle : .loaded
        } catch {
            guard generation == refreshGeneration else { return }
            failureLog.record(operation: "Refresh registries", error: error)
            listState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    /// `password` is consumed here and never stored. The caller clears its own
    /// field as submission starts, so the secret's lifetime is this call.
    @discardableResult
    func login(
        _ configuration: RegistryLoginConfiguration,
        password: String
    ) async -> Bool {
        guard activeMutation == nil else { return false }
        activeMutation = .login(configuration.server.rawValue)
        mutationFailure = nil
        defer { activeMutation = nil }
        do {
            try await service.login(configuration, password: password)
            await refresh()
            if registries.contains(where: { $0.host == configuration.server.rawValue }) {
                selectedRegistryID = configuration.server.rawValue
            }
            return true
        } catch is CancellationError {
            // A cancelled login may still have been written, so reconcile.
            await refresh()
            return false
        } catch CLIError.cancelled {
            await refresh()
            return false
        } catch {
            failureLog.record(operation: "Registry login", error: error)
            mutationFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return false
        }
    }

    func logout(host: String) async {
        guard activeMutation == nil else { return }
        guard registries.contains(where: { $0.host == host }) else {
            mutationFailure = "The registry changed. Refresh the list and try again."
            return
        }
        activeMutation = .logout(host)
        mutationFailure = nil
        defer { activeMutation = nil }
        do {
            try await service.logout(host: host)
            if selectedRegistryID == host {
                selectedRegistryID = nil
            }
            await refresh()
        } catch is CancellationError {
            await refresh()
        } catch CLIError.cancelled {
            await refresh()
        } catch {
            failureLog.record(operation: "Registry logout", error: error)
            mutationFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    /// Whether the GUI knows of a login for the host a reference names. A `false`
    /// is informational only — anonymous pulls and public pushes are normal.
    func isLoggedIn(forReference reference: String) -> Bool {
        guard let host = Self.registryHost(inReference: reference) else { return false }
        return isLoggedIn(host: host)
    }

    func isLoggedIn(host: String) -> Bool {
        registries.contains { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// The registry half of an image reference, using the same rule the CLI
    /// does: the first path segment is a registry only when it looks like a
    /// host — it carries a dot or a port, or it is `localhost`.
    nonisolated static func registryHost(inReference reference: String) -> String? {
        guard let separator = reference.firstIndex(of: "/") else { return nil }
        let candidate = String(reference[reference.startIndex..<separator])
        guard candidate == "localhost"
            || candidate.contains(".")
            || candidate.contains(":") else { return nil }
        return candidate
    }

    func dismissMutationFailure() { mutationFailure = nil }

    private func updateFilteredRegistries() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredRegistries = registries
            return
        }
        filteredRegistries = registries.filter {
            $0.host.localizedCaseInsensitiveContains(query)
        }
    }
}
