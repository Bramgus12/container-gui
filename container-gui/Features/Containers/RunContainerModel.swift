import Foundation
import Observation

struct PortMappingDraft: Identifiable, Equatable {
    let id: UUID
    var hostAddress: String
    var hostPort: String
    var containerPort: String
    var portProtocol: PortProtocol

    init(
        id: UUID = UUID(),
        hostAddress: String = "",
        hostPort: String = "",
        containerPort: String = "",
        portProtocol: PortProtocol = .tcp
    ) {
        self.id = id
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.portProtocol = portProtocol
    }
}

struct EnvironmentVariableDraft: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

struct CommandArgumentDraft: Identifiable, Equatable {
    let id: UUID
    var value: String

    init(id: UUID = UUID(), value: String = "") {
        self.id = id
        self.value = value
    }
}

@MainActor
@Observable
final class RunContainerModel: Identifiable {
    let id = UUID()
    var image = ""
    var name = ""
    var detached = true
    var removeWhenStopped = false
    var cpuLimit = ""
    var memoryLimit = ""
    var ports: [PortMappingDraft] = []
    var environment: [EnvironmentVariableDraft] = []
    var command = ""
    var arguments: [CommandArgumentDraft] = []

    private(set) var isRunning = false
    private(set) var progress = ""
    private(set) var errorMessage: String?

    init(image: String = "") {
        self.image = image
    }

    var imageError: String? {
        validationMessage {
            _ = try ImageReference(validating: trimmed(image))
        }
    }

    var nameError: String? {
        let value = trimmed(name)
        guard !value.isEmpty else { return nil }
        return validationMessage {
            _ = try ContainerIdentifier(validating: value)
        }
    }

    var cpuLimitError: String? {
        let value = trimmed(cpuLimit)
        guard !value.isEmpty else { return nil }
        return validationMessage {
            _ = try CPULimit(value)
        }
    }

    var memoryLimitError: String? {
        let value = trimmed(memoryLimit)
        guard !value.isEmpty else { return nil }
        return validationMessage {
            _ = try MemoryLimit(value)
        }
    }

    func portError(for draft: PortMappingDraft) -> String? {
        validationMessage {
            _ = try makePort(draft)
        }
    }

    func environmentError(for draft: EnvironmentVariableDraft) -> String? {
        validationMessage {
            _ = try EnvironmentVariable(key: trimmed(draft.key), value: draft.value)
        }
    }

    var commandError: String? {
        if trimmed(command).isEmpty && !arguments.isEmpty {
            return "Enter a command before adding arguments."
        }
        if command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "Command cannot contain control characters."
        }
        return nil
    }

    var configuration: RunConfiguration? {
        try? makeConfiguration()
    }

    var commandPreview: String {
        guard let configuration else { return "container run" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.run(configuration).arguments
        )
    }

    var canRun: Bool {
        configuration != nil && !isRunning
    }

    func addPort() {
        ports.append(PortMappingDraft())
    }

    func removePort(id: UUID) {
        ports.removeAll { $0.id == id }
    }

    func addEnvironmentVariable() {
        environment.append(EnvironmentVariableDraft())
    }

    func removeEnvironmentVariable(id: UUID) {
        environment.removeAll { $0.id == id }
    }

    func addArgument() {
        arguments.append(CommandArgumentDraft())
    }

    func removeArgument(id: UUID) {
        arguments.removeAll { $0.id == id }
    }

    func run(using appModel: AppModel) async -> Bool {
        guard let configuration, !isRunning else { return false }

        isRunning = true
        progress = ""
        errorMessage = nil
        defer { isRunning = false }

        do {
            try await appModel.runContainer(configuration) { [weak self] event in
                self?.record(event)
            }
            return true
        } catch is CancellationError {
            return false
        } catch CLIError.cancelled {
            return false
        } catch {
            errorMessage = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return false
        }
    }

    private func makeConfiguration() throws -> RunConfiguration {
        let image = trimmed(image)
        let name = trimmed(name)
        let cpuLimit = trimmed(cpuLimit)
        let memoryLimit = trimmed(memoryLimit)

        guard commandError == nil else {
            throw CommandValidationError.invalid(field: "Command", value: command)
        }

        return try RunConfiguration(
            image: image,
            name: name.isEmpty ? nil : name,
            detached: detached,
            removeWhenStopped: removeWhenStopped,
            cpuLimit: cpuLimit.isEmpty ? nil : cpuLimit,
            memoryLimit: memoryLimit.isEmpty ? nil : memoryLimit,
            ports: try ports.map(makePort),
            environment: try environment.map {
                try EnvironmentVariable(key: trimmed($0.key), value: $0.value)
            },
            command: trimmed(command).isEmpty
                ? []
                : [trimmed(command)] + arguments.map(\.value)
        )
    }

    private func makePort(_ draft: PortMappingDraft) throws -> PortMapping {
        let hostAddress = trimmed(draft.hostAddress)
        guard let hostPort = Int(trimmed(draft.hostPort)) else {
            throw CommandValidationError.invalid(field: "Host port", value: draft.hostPort)
        }
        guard let containerPort = Int(trimmed(draft.containerPort)) else {
            throw CommandValidationError.invalid(
                field: "Container port",
                value: draft.containerPort
            )
        }
        return try PortMapping(
            hostAddress: hostAddress.isEmpty ? nil : hostAddress,
            hostPort: hostPort,
            containerPort: containerPort,
            protocol: draft.portProtocol
        )
    }

    private func record(_ event: ProcessEvent) {
        let text: String
        switch event {
        case .standardOutput(let output), .standardError(let output):
            text = output
        case .terminated(let exitCode):
            text = "Process exited with status \(exitCode).\n"
        }

        progress.append(DiagnosticSanitizer.sanitize(text))
        let maximumCharacters = 32_768
        if progress.count > maximumCharacters {
            progress = String(progress.suffix(maximumCharacters))
        }
    }

    private func validationMessage(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
