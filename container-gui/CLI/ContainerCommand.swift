import Foundation

nonisolated enum ContainerCommand: Equatable, Sendable {
    case systemStart
    case systemStop
    case systemStatus
    case systemVersion
    case systemDiskUsage
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

    case listNetworks
    case inspectNetwork(name: NetworkName)
    case createNetwork(configuration: NetworkCreateConfiguration)
    case deleteNetwork(name: NetworkName)
    case pruneNetworks

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
        }
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
