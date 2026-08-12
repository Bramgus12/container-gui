import Foundation
import Observation

enum BuilderLoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum BuilderOperation: Equatable, Sendable {
    case start
    case stop
    case delete
}

@MainActor
@Observable
final class BuilderModel {
    private(set) var status: BuilderStatus = .absent
    private(set) var loadingState: BuilderLoadingState = .idle
    private(set) var operation: BuilderOperation?
    private(set) var actionError: String?

    private let service: any BuilderManaging
    private let failureLog: OperationFailureLog
    private var refreshGeneration = 0

    init(service: any BuilderManaging, failureLog: OperationFailureLog? = nil) {
        self.service = service
        self.failureLog = failureLog ?? OperationFailureLog()
    }

    var isBusy: Bool { operation != nil || loadingState == .loading }

    func loadIfNeeded() async {
        guard loadingState == .idle else { return }
        await refresh()
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        loadingState = .loading
        do {
            let refreshed = try await service.status()
            guard generation == refreshGeneration else { return }
            status = refreshed
            loadingState = .loaded
        } catch is CancellationError {
            guard generation == refreshGeneration else { return }
            loadingState = .idle
        } catch CLIError.cancelled {
            guard generation == refreshGeneration else { return }
            loadingState = .idle
        } catch {
            guard generation == refreshGeneration else { return }
            failureLog.record(operation: "Refresh builder status", error: error)
            loadingState = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }
    }

    func start(cpuLimit: String? = nil, memoryLimit: String? = nil) async {
        guard operation == nil else { return }
        do {
            let configuration = try BuilderStartConfiguration(
                cpuLimit: cpuLimit,
                memoryLimit: memoryLimit
            )
            await perform(.start) { try await self.service.start(configuration) }
        } catch {
            actionError = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    func stop() async {
        await perform(.stop) { try await self.service.stop() }
    }

    func delete() async {
        await perform(.delete) { try await self.service.delete() }
    }

    func dismissActionError() { actionError = nil }

    private func perform(
        _ requestedOperation: BuilderOperation,
        action: () async throws -> Void
    ) async {
        guard operation == nil else { return }
        operation = requestedOperation
        actionError = nil
        defer { operation = nil }
        do {
            try await action()
            await refresh()
        } catch is CancellationError {
            return
        } catch CLIError.cancelled {
            return
        } catch {
            failureLog.record(operation: "Manage builder", error: error)
            actionError = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }
}
