import Foundation
import Observation

nonisolated struct MachineEnvironmentDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

@MainActor
@Observable
final class MachineRunModel: Identifiable {
    let id = UUID()
    let machineID: String
    /// `machine run` boots a stopped machine on the way in, and the first boot
    /// also creates your user — so the sheet says so before you wait for it.
    let willBootFirst: Bool

    var command = ""
    var runsAsRoot = false
    var user = ""
    var workingDirectory = ""
    var environment: [MachineEnvironmentDraft] = []
    var environmentFile = ""
    var detached = false

    /// The session, once started. Nil while the form is still being filled in.
    private(set) var session: (any InteractiveProcessSession)?
    private(set) var exitCode: Int32?
    private(set) var startFailure: String?

    private let service: any MachineManaging

    init(machineID: String, isRunning: Bool, service: any MachineManaging) {
        self.machineID = machineID
        willBootFirst = !isRunning
        self.service = service
    }

    var isRunningSession: Bool { session != nil && exitCode == nil }

    /// A blank command is a login shell, which is what the CLI does with no
    /// executable argument.
    var isLoginShell: Bool {
        command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var userError: String? {
        let value = trimmed(user)
        guard !value.isEmpty else { return nil }
        if runsAsRoot {
            return String(localized: "Choose either root or a specific user, not both.")
        }
        return validationMessage { _ = try ProcessUser(validating: value) }
    }

    var workingDirectoryError: String? {
        let value = trimmed(workingDirectory)
        guard !value.isEmpty else { return nil }
        return validationMessage { _ = try LocalPath(validating: value, field: "Working directory") }
    }

    var environmentFileError: String? {
        let value = trimmed(environmentFile)
        guard !value.isEmpty else { return nil }
        return validationMessage { _ = try LocalPath(validating: value, field: "Environment file") }
    }

    func environmentError(for draft: MachineEnvironmentDraft) -> String? {
        let key = trimmed(draft.key)
        guard !key.isEmpty else { return nil }
        return validationMessage { _ = try EnvironmentVariable(key: key, value: draft.value) }
    }

    func addEnvironmentVariable() { environment.append(MachineEnvironmentDraft()) }
    func removeEnvironmentVariable(id: UUID) { environment.removeAll { $0.id == id } }

    var canStart: Bool { configuration != nil && session == nil }

    var configuration: MachineRunConfiguration? { try? makeConfiguration() }

    var commandPreview: String {
        guard let configuration else { return "container machine run -n \(machineID)" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.machineRun(configuration: configuration).arguments
        )
    }

    func start(terminalSize: TerminalSize = .default) {
        guard let configuration, session == nil else { return }
        startFailure = nil
        exitCode = nil
        do {
            session = try service.attachRun(configuration, terminalSize: terminalSize)
        } catch {
            startFailure = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    func finish(exitCode: Int32) {
        self.exitCode = exitCode
    }

    func terminate() {
        session?.terminate()
        session = nil
    }

    private func makeConfiguration() throws -> MachineRunConfiguration {
        try MachineRunConfiguration(
            name: machineID,
            command: parsedCommand,
            environment: try environment
                .filter { !trimmed($0.key).isEmpty }
                .map { try EnvironmentVariable(key: trimmed($0.key), value: $0.value) },
            environmentFile: optionalTrimmed(environmentFile),
            user: optionalTrimmed(user),
            runsAsRoot: runsAsRoot,
            workingDirectory: optionalTrimmed(workingDirectory),
            // A login shell always gets a terminal; the CLI ignores --tty for it.
            interactive: true,
            tty: true,
            detached: detached
        )
    }

    /// Splits on whitespace, honouring quotes so a path with a space survives.
    /// Anything more elaborate belongs in a shell, which is what the blank
    /// command already gives you.
    private var parsedCommand: [String] {
        let value = trimmed(command)
        guard !value.isEmpty else { return [] }
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in value {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private func validationMessage(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
