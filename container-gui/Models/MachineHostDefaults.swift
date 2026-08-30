import Darwin
import Foundation

/// What the CLI would compute for a machine if you gave it no flags, worked out
/// here so the create sheet opens already filled in and submittable rather than
/// showing empty fields the user has to guess at.
nonisolated struct MachineHostDefaults: Equatable, Sendable {
    /// `container machine create` defaults to half the host's cores, and never
    /// fewer than four.
    let cpus: Int
    /// Half the host's memory, expressed the way the `--memory` flag wants it.
    let memory: String
    /// Nested virtualization needs Apple Silicon M3 or newer on macOS 15+. The
    /// kernel also has to be built with `CONFIG_KVM=y`, which cannot be checked
    /// from here — so this reports the host half only.
    let supportsNestedVirtualization: Bool
    /// "M4 Pro, macOS 15.5" — shown next to the nested-virtualization toggle so
    /// the requirement is answered rather than just stated.
    let hostDescription: String

    init(processInfo: ProcessInfo = .processInfo) {
        cpus = max(4, processInfo.activeProcessorCount / 2)

        let halfMemory = processInfo.physicalMemory / 2
        let gigabytes = max(2, Int(halfMemory / 1_073_741_824))
        memory = "\(gigabytes)G"

        let chip = Self.chipName()
        let version = processInfo.operatingSystemVersion
        supportsNestedVirtualization = Self.chipGeneration(chip).map { $0 >= 3 } ?? false
            && version.majorVersion >= 15

        let versionText = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        hostDescription = [chip, "macOS \(versionText)"]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// "Apple M3 Pro" → 3. Intel Macs and anything unrecognised return nil,
    /// which reads as unsupported.
    static func chipGeneration(_ brand: String?) -> Int? {
        guard let brand,
              let match = brand.range(of: #"\bM([0-9]+)\b"#, options: .regularExpression)
        else {
            return nil
        }
        return Int(brand[match].dropFirst())
    }

    private static func chipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
