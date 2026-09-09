import Foundation
import Observation

/// `machine set` writes boot config and prints that changes take effect after a
/// stop and start. So this is a current-versus-next pair rather than a form that
/// claims to be live: the left column is what the machine is running on, the
/// right is what it will pick up when it restarts.
@MainActor
@Observable
final class MachineBootConfigurationModel: Identifiable {
    let id = UUID()
    let machineID: String
    let isRunning: Bool

    /// What the machine is running on now. `virtualization` and `kernel` are
    /// `nil` whenever the CLI did not report them, which is currently always —
    /// the rows then read "not reported" rather than inventing a value.
    let currentCPUs: Int?
    let currentMemory: String?
    let currentHomeMount: MachineHomeMount?
    let currentVirtualization: Bool?
    let currentKernel: String?

    var cpus: Int
    var memory: String
    var homeMount: MachineHomeMount
    var virtualization: Bool
    var kernelPath: String

    init(inspection: MachineInspection, pending: MachineBootConfiguration?) {
        machineID = inspection.summary.id
        isRunning = inspection.summary.state == .running

        currentCPUs = inspection.summary.cpus
        currentMemory = inspection.summary.memoryBytes.map(Self.formatMemory)
        currentHomeMount = inspection.homeMount
        currentVirtualization = inspection.virtualization
        currentKernel = inspection.kernelPath

        // A pending change is what the machine will boot with next, so the
        // editor opens showing that rather than the values it is running on.
        cpus = pending?.cpus?.value ?? inspection.summary.cpus ?? 4
        memory = pending?.memory?.value
            ?? inspection.summary.memoryBytes.map(Self.formatMemory)
            ?? ""
        homeMount = pending?.homeMount ?? inspection.homeMount ?? .readWrite
        virtualization = pending?.virtualization ?? inspection.virtualization ?? false
        kernelPath = pending?.kernel?.rawValue ?? inspection.kernelPath ?? ""
    }

    var memoryError: String? {
        let value = trimmed(memory)
        guard !value.isEmpty else { return nil }
        return validationMessage { _ = try MachineMemory(value) }
    }

    /// The CLI validates the kernel before boot — readable, non-empty, a file —
    /// and this says so up front rather than after a failed restart.
    var kernelError: String? {
        let value = trimmed(kernelPath)
        guard !value.isEmpty else { return nil }
        do {
            let path = try MachineKernelPath(validating: value)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.rawValue, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return String(localized: "Not readable at that path — fix it or clear the field to fall back to the system kernel.")
            }
            guard FileManager.default.isReadableFile(atPath: path.rawValue) else {
                return String(localized: "That file is not readable.")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path.rawValue)[.size] as? Int) ?? nil
            if let size, size == 0 {
                return String(localized: "That file is empty.")
            }
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    /// Only what actually differs from the running values is sent, so the
    /// command preview matches the design's promise that it lists your changes.
    var changes: MachineBootConfiguration {
        var boot = MachineBootConfiguration()
        if cpus != currentCPUs, let value = try? MachineCPUCount(cpus) {
            boot.cpus = value
        }
        let memoryValue = trimmed(memory)
        if memoryValue != (currentMemory ?? ""), let value = try? MachineMemory(memoryValue) {
            boot.memory = value
        }
        // Compared against the same fallback the editor defaulted the control
        // to, so a setting the CLI did not report is not counted as a change the
        // user made. `home-mount` is reported in practice; this only matters for
        // a payload that omits it.
        if homeMount != (currentHomeMount ?? .readWrite) {
            boot.homeMount = homeMount
        }
        if virtualization != (currentVirtualization ?? false) {
            boot.virtualization = virtualization
        }
        let kernelValue = trimmed(kernelPath)
        if kernelValue != (currentKernel ?? "") {
            if kernelValue.isEmpty {
                boot.resetsKernel = true
            } else if let value = try? MachineKernelPath(validating: kernelValue) {
                boot.kernel = value
            }
        }
        return boot
    }

    var changeCount: Int { changes.settings.count }

    var canApply: Bool {
        !changes.isEmpty && memoryError == nil && kernelError == nil
    }

    var commandPreview: String {
        guard let configuration = try? MachineSetConfiguration(
            name: machineID,
            boot: changes
        ) else {
            return "container machine set -n \(machineID)"
        }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.setMachineConfiguration(configuration).arguments
        )
    }

    func revert() {
        cpus = currentCPUs ?? 4
        memory = currentMemory ?? ""
        homeMount = currentHomeMount ?? .readWrite
        virtualization = currentVirtualization ?? false
        kernelPath = currentKernel ?? ""
    }

    nonisolated static func formatMemory(_ bytes: UInt64) -> String {
        // The CLI takes "8G", so the editor round-trips in the same units it
        // will send rather than showing a byte count nobody can retype.
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1, gigabytes == gigabytes.rounded() {
            return "\(Int(gigabytes))G"
        }
        if gigabytes >= 1 {
            return String(format: "%.1fG", gigabytes)
        }
        return "\(max(1, bytes / 1_048_576))M"
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
