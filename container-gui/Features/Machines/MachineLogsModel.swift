import Foundation
import Observation

/// A machine keeps two log files, and which one you want depends on what went
/// wrong: the boot log is where you look when a machine will not start, and the
/// stdio log is the process output once it has.
nonisolated enum MachineLogSource: String, CaseIterable, Identifiable, Sendable {
    case output
    case boot

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .output: "Machine output"
        case .boot: "Boot log"
        }
    }

    var showsBootLog: Bool { self == .boot }
}

@MainActor
@Observable
final class MachineLogsModel: Identifiable {
    let id = UUID()
    let machineID: String

    var source: MachineLogSource = .output {
        didSet {
            guard source != oldValue else { return }
            restart()
        }
    }
    var follows = true {
        didSet {
            guard follows != oldValue else { return }
            restart()
        }
    }
    var tail = 200 {
        didSet {
            guard tail != oldValue else { return }
            restart()
        }
    }
    var filter: LogFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            refreshSnapshot()
        }
    }

    private(set) var snapshot = LogSnapshot(text: "", firstLogicalLineNumber: 1)
    private(set) var counts = LogCounts(all: 0, warnings: 0, errors: 0)
    private(set) var isLoading = false
    private(set) var failure: String?

    private let service: any MachineManaging
    private var buffer = LogBuffer()
    private var task: Task<Void, Never>?

    init(machineID: String, service: any MachineManaging) {
        self.machineID = machineID
        self.service = service
    }

    var commandPreview: String {
        guard let options = try? MachineLogOptions(
            name: machineID,
            showsBootLog: source.showsBootLog,
            follow: follows,
            tail: tail
        ) else {
            return "container machine logs \(machineID)"
        }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.machineLogs(options).arguments
        )
    }

    var plainText: String { buffer.snapshot(filter: .all).text }

    func start() {
        guard task == nil else { return }
        restart()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func restart() {
        task?.cancel()
        buffer.startNewSession()
        refreshSnapshot()
        failure = nil
        isLoading = true

        guard let options = try? MachineLogOptions(
            name: machineID,
            showsBootLog: source.showsBootLog,
            follow: follows,
            tail: tail
        ) else {
            isLoading = false
            failure = String(localized: "Those log options are not valid.")
            return
        }

        let stream = service.streamLogs(options)
        task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .standardOutput(let text), .standardError(let text):
                        append(text)
                    case .terminated:
                        isLoading = false
                        return
                    }
                }
                self?.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                isLoading = false
                // A machine that has never booted has no log file, and the CLI
                // reports that as a failure. There is nothing wrong — there is
                // just nothing to read yet — so it reads as the empty state
                // rather than an error banner. The CLI names `stdio.log` in this
                // message even when `--boot` was asked for, so the file name is
                // not worth matching on.
                if Self.describesAMissingLogFile(error) { return }
                failure = DiagnosticSanitizer.sanitize(error.localizedDescription)
            }
        }
    }

    /// True when the CLI failed only because the log file is not there yet.
    nonisolated static func describesAMissingLogFile(_ error: Error) -> Bool {
        let message: String
        if case CLIError.nonZeroExit(_, _, let standardError, let standardOutput) = error {
            message = standardError + standardOutput
        } else {
            message = error.localizedDescription
        }
        let lowered = message.lowercased()
        return lowered.contains("doesn’t exist")
            || lowered.contains("doesn't exist")
            || lowered.contains("no such file or directory")
    }

    private func append(_ text: String) {
        buffer.append(text)
        isLoading = false
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        snapshot = buffer.snapshot(filter: filter)
        counts = buffer.counts
    }
}
