import Foundation

nonisolated enum ContainerCommand: Equatable, Sendable {
    case systemStart
    case systemStop
    case systemStatus
    case systemVersion
    case systemDiskUsage
    case systemDNSList
    case systemProperties
    case systemLogs(follow: Bool, last: SystemLogPeriod?)

    case listContainers(includeStopped: Bool)
    case inspectContainer(id: ContainerIdentifier)
    case run(RunConfiguration)
    case start(id: ContainerIdentifier)
    case stop(id: ContainerIdentifier, timeout: StopTimeout?)
    case delete(id: ContainerIdentifier, force: Bool)
    case logs(id: ContainerIdentifier, follow: Bool, tail: LogTail?)
    case stats(ids: [ContainerIdentifier])

    case listImages
    case inspectImage(reference: ImageReference)
    case pullImage(reference: ImageReference)
    case deleteImage(reference: ImageReference)
    case pruneImages(all: Bool)

    case listNetworks
    case inspectNetwork(name: NetworkName)
    case createNetwork(configuration: NetworkCreateConfiguration)
    case deleteNetwork(name: NetworkName)
    case pruneNetworks

    case listVolumes
    case inspectVolume(name: VolumeName)
    case createVolume(configuration: VolumeCreateConfiguration)
    case deleteVolume(name: VolumeName)
    case pruneVolumes

    case build(BuildConfiguration)
    case builderStatus
    case builderStart(configuration: BuilderStartConfiguration)
    case builderStop
    case builderDelete

    var arguments: [String] {
        switch self {
        case .systemStart:
            ["system", "start", "--disable-kernel-install"]
        case .systemStop:
            ["system", "stop"]
        case .systemStatus:
            ["system", "status", "--format", "json"]
        case .systemVersion:
            ["system", "version", "--format", "json"]
        case .systemDiskUsage:
            ["system", "df", "--format", "json"]
        case .systemDNSList:
            ["system", "dns", "list", "--format", "json"]
        case .systemProperties:
            ["system", "property", "list", "--format", "json"]
        case .systemLogs(let follow, let last):
            ["system", "logs"]
                + (follow ? ["--follow"] : [])
                + (last.map { ["--last", $0.rawValue] } ?? [])

        case .listContainers(let includeStopped):
            ["list"] + (includeStopped ? ["--all"] : []) + ["--format", "json"]
        case .inspectContainer(let id):
            ["inspect", id.rawValue]
        case .run(let configuration):
            configuration.arguments
        case .start(let id):
            ["start", id.rawValue]
        case .stop(let id, let timeout):
            ["stop"] + (timeout.map { ["--time", String($0.seconds)] } ?? []) + [id.rawValue]
        case .delete(let id, let force):
            ["delete"] + (force ? ["--force"] : []) + [id.rawValue]
        case .logs(let id, let follow, let tail):
            ["logs"]
                + (follow ? ["--follow"] : [])
                + (tail.map { ["-n", String($0.lines)] } ?? [])
                + [id.rawValue]
        case .stats(let ids):
            ["stats", "--format", "json", "--no-stream"] + ids.map(\.rawValue)

        case .listImages:
            ["image", "list", "--verbose", "--format", "json"]
        case .inspectImage(let reference):
            ["image", "inspect", reference.rawValue]
        case .pullImage(let reference):
            ["image", "pull", "--progress", "plain", reference.rawValue]
        case .deleteImage(let reference):
            ["image", "delete", reference.rawValue]
        case .pruneImages(let all):
            ["image", "prune"] + (all ? ["--all"] : [])

        case .listNetworks:
            ["network", "list", "--format", "json"]
        case .inspectNetwork(let name):
            ["network", "inspect", name.rawValue]
        case .createNetwork(let configuration):
            Self.createNetworkArguments(configuration)
        case .deleteNetwork(let name):
            ["network", "delete", name.rawValue]
        case .pruneNetworks:
            ["network", "prune"]

        case .listVolumes:
            ["volume", "list", "--format", "json"]
        case .inspectVolume(let name):
            ["volume", "inspect", name.rawValue]
        case .createVolume(let configuration):
            Self.createVolumeArguments(configuration)
        case .deleteVolume(let name):
            ["volume", "delete", name.rawValue]
        case .pruneVolumes:
            ["volume", "prune"]

        case .build(let configuration):
            configuration.arguments
        case .builderStatus:
            ["builder", "status", "--format", "json"]
        case .builderStart(let configuration):
            ["builder", "start"]
                + (configuration.cpuLimit.map { ["--cpus", $0.value] } ?? [])
                + (configuration.memoryLimit.map { ["--memory", $0.value] } ?? [])
        case .builderStop:
            ["builder", "stop"]
        case .builderDelete:
            ["builder", "delete"]
        }
    }

    private static func createVolumeArguments(
        _ configuration: VolumeCreateConfiguration
    ) -> [String] {
        var result = ["volume", "create"]
        for label in configuration.labels {
            result += ["--label", label.argument]
        }
        for option in configuration.options {
            result += ["--opt", option.argument]
        }
        if let size = configuration.size {
            result += ["-s", size.rawValue]
        }
        result.append(configuration.name.rawValue)
        return result
    }

    private static func createNetworkArguments(
        _ configuration: NetworkCreateConfiguration
    ) -> [String] {
        var result = ["network", "create"]
        if configuration.mode == .internal {
            result.append("--internal")
        }
        for label in configuration.labels {
            result += ["--label", label.argument]
        }
        switch configuration.customization {
        case .legacyVariant(let variant):
            if let variant, !variant.isEmpty {
                result += ["--plugin-variant", variant]
            }
        case .options(let options):
            for option in options {
                result += ["--option", option.argument]
            }
        }
        if let plugin = configuration.plugin,
           plugin != NetworkCreateConfiguration.defaultPlugin {
            result += ["--plugin", plugin]
        }
        if let ipv4Subnet = configuration.ipv4Subnet {
            result += ["--subnet", ipv4Subnet.rawValue]
        }
        if let ipv6Subnet = configuration.ipv6Subnet {
            result += ["--subnet-v6", ipv6Subnet.rawValue]
        }
        result.append(configuration.name.rawValue)
        return result
    }
}

nonisolated struct StopTimeout: Equatable, Sendable {
    let seconds: Int

    init(seconds: Int) throws {
        guard seconds >= 0 else {
            throw CommandValidationError.outOfRange(field: "Stop timeout", value: seconds)
        }
        self.seconds = seconds
    }
}

nonisolated struct LogTail: Equatable, Sendable {
    let lines: Int

    init(lines: Int) throws {
        guard lines >= 0 else {
            throw CommandValidationError.outOfRange(field: "Log tail", value: lines)
        }
        self.lines = lines
    }
}

nonisolated struct SystemLogPeriod: Equatable, Sendable {
    let rawValue: String

    init(value: Int, unit: Unit) throws {
        guard value > 0 else {
            throw CommandValidationError.nonPositive(field: "System log period")
        }
        rawValue = "\(value)\(unit.rawValue)"
    }

    enum Unit: String, Equatable, Sendable {
        case minutes = "m"
        case hours = "h"
        case days = "d"
    }
}
