import Foundation
import Observation

@MainActor
@Observable
final class MachineCreateModel: Identifiable {
    let id = UUID()
    let defaults: MachineHostDefaults

    var image = ""
    var name = ""
    var operatingSystem = "linux"
    var architecture = "arm64"
    var cpus: Int
    var memory: String
    var homeMount: MachineHomeMount = .readWrite
    var nestedVirtualization = false
    var kernelPath = ""
    var bootsAfterCreating = true
    var setsDefault = false

    init(defaults: MachineHostDefaults = MachineHostDefaults()) {
        self.defaults = defaults
        cpus = defaults.cpus
        memory = defaults.memory
        architecture = Self.hostArchitecture
    }

    var imageError: String? {
        let value = trimmed(image)
        guard !value.isEmpty else { return nil }
        return validationMessage { _ = try ImageReference(validating: value) }
    }

    var nameError: String? {
        let value = trimmed(name)
        guard !value.isEmpty else { return nil }
        return validationMessage { _ = try MachineIdentifier(validating: value) }
    }

    var memoryError: String? {
        let value = trimmed(memory)
        guard !value.isEmpty else { return nil }
        return validationMessage { _ = try MachineMemory(value) }
    }

    var kernelError: String? {
        let value = trimmed(kernelPath)
        guard !value.isEmpty else { return nil }
        return validationMessage { _ = try MachineKernelPath(validating: value) }
    }

    /// The toggle stays operable even where the host cannot support it, because
    /// the kernel half of the requirement is not knowable from here — but the
    /// note under it says what the host can do.
    var nestedVirtualizationNote: LocalizedStringResource {
        defaults.supportsNestedVirtualization
            ? "This Mac supports it — \(defaults.hostDescription)."
            : "This Mac does not meet the requirement — \(defaults.hostDescription). Needs Apple Silicon M3 or newer on macOS 15 or later."
    }

    var canCreate: Bool { configuration != nil }

    var configuration: MachineCreateConfiguration? { try? makeConfiguration() }

    var commandPreview: String {
        guard let configuration else { return "container machine create" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.createMachine(configuration: configuration).arguments
        )
    }

    private func makeConfiguration() throws -> MachineCreateConfiguration {
        var boot = MachineBootConfiguration(
            cpus: try MachineCPUCount(cpus),
            memory: try MachineMemory(trimmed(memory)),
            homeMount: homeMount,
            virtualization: nestedVirtualization ? true : nil
        )
        let kernel = trimmed(kernelPath)
        if !kernel.isEmpty {
            boot.kernel = try MachineKernelPath(validating: kernel)
        }
        return try MachineCreateConfiguration(
            image: trimmed(image),
            name: optionalTrimmed(name),
            // Only sent when they differ from the host, since the CLI only uses
            // them for a multi-platform image and defaults to this Mac anyway.
            operatingSystem: operatingSystem == "linux" ? nil : operatingSystem,
            architecture: architecture == Self.hostArchitecture ? nil : architecture,
            boot: boot,
            setsDefault: setsDefault,
            bootsAfterCreating: bootsAfterCreating
        )
    }

    private static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
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
