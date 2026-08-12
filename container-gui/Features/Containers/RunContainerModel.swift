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

struct NetworkAttachmentDraft: Identifiable, Equatable {
    let id: UUID
    var networkName: String
    var macAddress: String
    var mtu: String

    init(
        id: UUID = UUID(),
        networkName: String = "",
        macAddress: String = "",
        mtu: String = ""
    ) {
        self.id = id
        self.networkName = networkName
        self.macAddress = macAddress
        self.mtu = mtu
    }
}

enum ContainerMountKind: String, CaseIterable, Equatable {
    case volume = "Named volume"
    case hostPath = "Host path"
}

struct ContainerMountDraft: Identifiable, Equatable {
    let id: UUID
    var kind: ContainerMountKind
    var source: String
    var target: String
    var isReadOnly: Bool

    init(
        id: UUID = UUID(),
        kind: ContainerMountKind = .volume,
        source: String = "",
        target: String = "",
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.target = target
        self.isReadOnly = isReadOnly
    }
}

enum RunContainerOutcome: Equatable {
    case succeeded
    case failed
    case cancelled
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
    var networks: [NetworkAttachmentDraft] = []
    var mounts: [ContainerMountDraft] = []
    var ports: [PortMappingDraft] = []
    var environment: [EnvironmentVariableDraft] = []
    var command = ""
    var arguments: [CommandArgumentDraft] = []

    private(set) var isRunning = false
    private(set) var progress = ""
    private(set) var errorMessage: String?
    private weak var networkModel: NetworkModel?
    private weak var volumeModel: VolumeModel?

    init(
        image: String = "",
        networkModel: NetworkModel? = nil,
        volumeModel: VolumeModel? = nil
    ) {
        self.image = image
        self.networkModel = networkModel
        self.volumeModel = volumeModel
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

    func networkError(for draft: NetworkAttachmentDraft) -> String? {
        if networks.filter({ $0.networkName == draft.networkName }).count > 1,
           !draft.networkName.isEmpty {
            return "Each network can be attached only once."
        }
        guard networkModel?.networks.contains(where: { $0.name == draft.networkName }) == true else {
            return draft.networkName.isEmpty
                ? "Select a network."
                : "This network is no longer available. Select another network."
        }
        return validationMessage {
            _ = try makeNetworkAttachment(draft)
        }
    }

    func mountError(for draft: ContainerMountDraft) -> String? {
        if mounts.filter({ trimmed($0.target) == trimmed(draft.target) }).count > 1,
           !trimmed(draft.target).isEmpty {
            return "Each container target can be mounted only once."
        }
        if draft.kind == .volume,
           volumeModel?.volumes.contains(where: { $0.name == trimmed(draft.source) }) != true {
            return trimmed(draft.source).isEmpty
                ? "Select a volume."
                : "This volume is no longer available. Select another volume."
        }
        return validationMessage { _ = try makeMount(draft) }
    }

    var commandError: String? {
        if trimmed(command).isEmpty && !arguments.isEmpty {
            return "Enter a command before adding arguments."
        }
        let controlCharacters = CharacterSet.controlCharacters
        if command.unicodeScalars.contains(where: { controlCharacters.contains($0) }) {
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

    func addNetworkAttachment() {
        let selected = Set(networks.map(\.networkName))
        let name = networkModel?.networks.first { !selected.contains($0.name) }?.name ?? ""
        networks.append(NetworkAttachmentDraft(networkName: name))
    }

    func removeNetworkAttachment(id: UUID) {
        networks.removeAll { $0.id == id }
    }

    func addMount(kind: ContainerMountKind = .volume) {
        let source: String
        if kind == .volume {
            let selected = Set(mounts.filter { $0.kind == .volume }.map(\.source))
            source = volumeModel?.volumes.first { !selected.contains($0.name) }?.name ?? ""
        } else {
            source = ""
        }
        mounts.append(ContainerMountDraft(kind: kind, source: source))
    }

    func removeMount(id: UUID) {
        mounts.removeAll { $0.id == id }
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

    func run(using appModel: AppModel) async -> RunContainerOutcome {
        guard let configuration, !isRunning else { return .failed }

        isRunning = true
        progress = ""
        errorMessage = nil
        defer { isRunning = false }

        do {
            try await appModel.runContainer(configuration) { [weak self] event in
                self?.record(event)
            }
            return .succeeded
        } catch is CancellationError {
            await appModel.reconcileAfterCancelledRun()
            return .cancelled
        } catch CLIError.cancelled {
            await appModel.reconcileAfterCancelledRun()
            return .cancelled
        } catch {
            errorMessage = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return .failed
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
            networks: try networks.map(makeNetworkAttachment),
            mounts: try mounts.map(makeMount),
            ports: try ports.map(makePort),
            environment: try environment.map {
                try EnvironmentVariable(key: trimmed($0.key), value: $0.value)
            },
            command: trimmed(command).isEmpty
                ? []
                : [trimmed(command)] + arguments.map(\.value)
        )
    }

    private func makeNetworkAttachment(
        _ draft: NetworkAttachmentDraft
    ) throws -> NetworkAttachment {
        let name = trimmed(draft.networkName)
        guard networkModel?.networks.contains(where: { $0.name == name }) == true else {
            throw CommandValidationError.invalid(field: "Network attachment", value: name)
        }
        let macAddress = trimmed(draft.macAddress)
        let mtuText = trimmed(draft.mtu)
        let mtu: Int?
        if mtuText.isEmpty {
            mtu = nil
        } else if let parsed = Int(mtuText) {
            mtu = parsed
        } else {
            throw CommandValidationError.invalid(field: "Network MTU", value: mtuText)
        }
        return try NetworkAttachment(
            network: name,
            macAddress: macAddress.isEmpty ? nil : macAddress,
            mtu: mtu
        )
    }

    private func makeMount(_ draft: ContainerMountDraft) throws -> ContainerMount {
        let source = trimmed(draft.source)
        let target = trimmed(draft.target)
        switch draft.kind {
        case .volume:
            guard volumeModel?.volumes.contains(where: { $0.name == source }) == true else {
                throw CommandValidationError.invalid(field: "Volume mount", value: source)
            }
            return try ContainerMount(
                volumeName: source,
                target: target,
                isReadOnly: draft.isReadOnly
            )
        case .hostPath:
            return try ContainerMount(
                hostPath: source,
                target: target,
                isReadOnly: draft.isReadOnly
            )
        }
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
