import Foundation

enum ContainerCommand: Equatable, Sendable {
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
        }
    }
}

struct StopTimeout: Equatable, Sendable {
    let seconds: Int

    init(seconds: Int) throws {
        guard seconds >= 0 else {
            throw CommandValidationError.outOfRange(field: "Stop timeout", value: seconds)
        }
        self.seconds = seconds
    }
}

struct LogTail: Equatable, Sendable {
    let lines: Int

    init(lines: Int) throws {
        guard lines >= 0 else {
            throw CommandValidationError.outOfRange(field: "Log tail", value: lines)
        }
        self.lines = lines
    }
}

struct SystemLogPeriod: Equatable, Sendable {
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
