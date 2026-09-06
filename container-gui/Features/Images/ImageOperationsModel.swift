import Foundation
import Observation

/// The six image operations that stream. Each carries the configuration it was
/// started with, so the activity can show the exact command it is running and
/// reconcile the right inventory when it ends.
nonisolated enum ImageOperationKind: Equatable, Sendable {
    case pull(ImagePullConfiguration)
    case push(ImagePushConfiguration)
    case save(ImageSaveConfiguration)
    case load(ImageLoadConfiguration)
    case delete(ImageDeleteConfiguration)
    case prune(all: Bool)

    var command: ContainerCommand {
        switch self {
        case .pull(let configuration): .pullImage(configuration: configuration)
        case .push(let configuration): .pushImage(configuration: configuration)
        case .save(let configuration): .saveImages(configuration: configuration)
        case .load(let configuration): .loadImages(configuration: configuration)
        case .delete(let configuration): .deleteImages(configuration: configuration)
        case .prune(let all): .pruneImages(all: all)
        }
    }

    /// Whether finishing — or being interrupted — can have changed the local
    /// image list. Push and save only read it.
    var mutatesLocalImages: Bool {
        switch self {
        case .pull, .load, .delete, .prune: true
        case .push, .save: false
        }
    }

    /// The single reference an operation is "about", where there is one. Used to
    /// re-select the affected row once the list comes back.
    var primaryReference: String? {
        switch self {
        case .pull(let configuration): configuration.reference.rawValue
        case .push(let configuration): configuration.reference.rawValue
        case .save, .load, .delete, .prune: nil
        }
    }

    var invocation: String {
        ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: command.arguments
        )
    }
}

nonisolated enum ImageOperationState: Equatable, Sendable {
    case running
    case succeeded
    case cancelled
    case failed(String)
}

/// One running or finished operation, and everything the progress row shows for
/// it. Held by ``ImageOperationsModel`` rather than by a view, so navigating
/// away from Images does not orphan the child process.
@MainActor
@Observable
final class ImageOperationActivity: Identifiable {
    let id = UUID()
    let kind: ImageOperationKind
    private(set) var state: ImageOperationState = .running
    /// The accumulated output, bounded so a long transfer cannot grow without
    /// limit in memory or in the pane that renders it.
    private(set) var transcript = ""
    private(set) var label = "Waiting to start"
    private(set) var fraction: Double?

    static let transcriptLimit = 65_536

    init(kind: ImageOperationKind) {
        self.kind = kind
    }

    var isRunning: Bool { state == .running }

    var invocation: String { kind.invocation }

    func record(_ event: ProcessEvent) {
        switch event {
        case .standardOutput(let output), .standardError(let output):
            transcript.append(DiagnosticSanitizer.sanitize(output))
            updateParsedProgress(from: output)
        case .terminated(let exitCode):
            transcript.append("Process exited with status \(exitCode).\n")
        }
        if transcript.count > Self.transcriptLimit {
            transcript = String(transcript.suffix(Self.transcriptLimit))
        }
    }

    func finish(_ state: ImageOperationState) {
        self.state = state
        if state == .succeeded {
            fraction = 1
        }
    }

    /// The CLI's plain progress is line-oriented and its wording is not stable
    /// across releases, so the last line is shown as-is and a fraction is only
    /// claimed when a line actually carries an `n / m` pair. Anything else
    /// leaves the bar indeterminate rather than inventing a number.
    private func updateParsedProgress(from output: String) {
        guard let line = output.split(whereSeparator: \.isNewline).last.map(String.init),
              !line.isEmpty else { return }
        label = DiagnosticSanitizer.sanitize(line)

        let pattern = #"(\d+)\s*/\s*(\d+)"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ),
        let completedRange = Range(match.range(at: 1), in: line),
        let totalRange = Range(match.range(at: 2), in: line),
        let completed = Double(line[completedRange]),
        let total = Double(line[totalRange]), total > 0 else {
            fraction = nil
            return
        }
        fraction = min(1, max(0, completed / total))
    }
}

/// Owns the one image operation allowed to run at a time.
///
/// One at a time is a deliberate limit: concurrent transfers would race each
/// other's inventory refreshes, and cancellation would have no single target.
@MainActor
@Observable
final class ImageOperationsModel {
    private(set) var activity: ImageOperationActivity?

    private var service: (any ImageManaging)?
    private var task: Task<Void, Never>?
    /// Identifies the current run. Comparing against it — rather than against
    /// the activity, which the user can dismiss mid-reconcile — is what lets a
    /// finishing run retire only its own task handle.
    private var runToken = 0
    private let failureLog: OperationFailureLog

    init(service: (any ImageManaging)? = nil, failureLog: OperationFailureLog? = nil) {
        self.service = service
        self.failureLog = failureLog ?? OperationFailureLog()
    }

    /// True until reconciliation has finished, not merely until the child
    /// exits. Reconciliation refreshes the very lists a second operation would
    /// act on, so letting one start in that window would race it.
    var isBusy: Bool { task != nil }

    func setService(_ service: (any ImageManaging)?) {
        cancel()
        // A new executable retires the old operation outright: its reconcile
        // would refresh through a service that no longer exists, and leaving the
        // handle behind would keep `isBusy` true for good.
        runToken &+= 1
        task = nil
        self.service = service
        activity = nil
    }

    /// Starts `kind` and returns immediately. `reconcile` runs once the child
    /// has exited — including when it was cancelled — because a partly applied
    /// load or delete still changed the inventory.
    @discardableResult
    func start(
        _ kind: ImageOperationKind,
        reconcile: @escaping @MainActor (ImageOperationState) async -> Void
    ) -> Bool {
        guard !isBusy, let service else { return false }

        let activity = ImageOperationActivity(kind: kind)
        self.activity = activity
        runToken &+= 1
        let token = runToken

        task = Task { [weak self] in
            let state: ImageOperationState
            do {
                try await drainImageOperation(
                    Self.events(for: kind, service: service),
                    command: kind.command
                ) { event in
                    activity.record(event)
                }
                state = .succeeded
            } catch is CancellationError {
                state = .cancelled
            } catch CLIError.cancelled {
                state = .cancelled
            } catch {
                self?.failureLog.record(operation: Self.operationName(for: kind), error: error)
                state = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
            }
            activity.finish(state)
            await reconcile(state)
            // Only retire our own task. Clearing unconditionally would drop the
            // handle of whatever started next, leaving it uncancellable.
            if self?.runToken == token {
                self?.task = nil
            }
        }
        return true
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        guard activity?.isRunning != true else { return }
        activity = nil
    }

    private static func events(
        for kind: ImageOperationKind,
        service: any ImageManaging
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        switch kind {
        case .pull(let configuration): service.pullImage(configuration)
        case .push(let configuration): service.pushImage(configuration)
        case .save(let configuration): service.saveImages(configuration)
        case .load(let configuration): service.loadImages(configuration)
        case .delete(let configuration): service.deleteImages(configuration)
        case .prune(let all): service.pruneImages(all: all)
        }
    }

    private static func operationName(for kind: ImageOperationKind) -> String {
        switch kind {
        case .pull: "Pull image"
        case .push: "Push image"
        case .save: "Save images"
        case .load: "Load images"
        case .delete: "Delete images"
        case .prune: "Prune images"
        }
    }
}
