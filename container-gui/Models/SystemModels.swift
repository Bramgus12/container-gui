import Foundation

nonisolated struct SystemStatusDTO: Decodable, Equatable, Sendable {
    let status: String?
    let healthy: Bool?
    let version: String?
    let message: String?
}

nonisolated struct SystemStatus: Equatable, Sendable {
    let isRunning: Bool
    let version: String?
    let message: String?

    init(dto: SystemStatusDTO) {
        isRunning = dto.healthy ?? ["running", "healthy", "ready"].contains(dto.status?.lowercased())
        version = dto.version
        message = dto.message
    }
}

nonisolated struct SystemVersionDTO: Decodable, Equatable, Sendable {
    let appName: String
    let version: String
    let buildType: String?
    let commit: String?
}

nonisolated struct SystemVersion: Equatable, Sendable {
    let cli: SystemVersionDTO?
    let server: SystemVersionDTO?

    init(components: [SystemVersionDTO]) {
        cli = components.first { $0.appName == "container" }
        server = components.first { $0.appName == "container-apiserver" }
    }
}

struct ContainerStatsDTO: Decodable, Equatable, Sendable {
    let id: String
    let memoryUsageBytes: UInt64?
    let memoryLimitBytes: UInt64?
    let cpuUsageUsec: UInt64?
    let networkRxBytes: UInt64?
    let networkTxBytes: UInt64?
    let blockReadBytes: UInt64?
    let blockWriteBytes: UInt64?
    let numProcesses: Int?
}

struct ContainerStats: Identifiable, Equatable, Sendable {
    let id: String
    let memoryUsageBytes: UInt64?
    let memoryLimitBytes: UInt64?
    let cpuUsageMicroseconds: UInt64?
    let networkReceivedBytes: UInt64?
    let networkTransmittedBytes: UInt64?
    let blockReadBytes: UInt64?
    let blockWrittenBytes: UInt64?
    let processCount: Int?

    init(dto: ContainerStatsDTO) {
        id = dto.id
        memoryUsageBytes = dto.memoryUsageBytes
        memoryLimitBytes = dto.memoryLimitBytes
        cpuUsageMicroseconds = dto.cpuUsageUsec
        networkReceivedBytes = dto.networkRxBytes
        networkTransmittedBytes = dto.networkTxBytes
        blockReadBytes = dto.blockReadBytes
        blockWrittenBytes = dto.blockWriteBytes
        processCount = dto.numProcesses
    }
}

struct SystemDiskUsageDTO: Decodable, Equatable, Sendable {
    let type: String?
    let totalCount: Int?
    let activeCount: Int?
    let sizeBytes: UInt64?
    let reclaimableBytes: UInt64?
}

struct SystemDiskUsage: Equatable, Sendable {
    let resources: [SystemDiskUsageDTO]
}
