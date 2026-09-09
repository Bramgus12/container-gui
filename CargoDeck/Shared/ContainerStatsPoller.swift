import Foundation
import Observation

nonisolated protocol ContainerStatsListing: Sendable {
    func allStats() async throws -> [String: ContainerStats]
}

@MainActor
@Observable
final class ContainerStatsPoller {
    private(set) var statsByContainerID: [String: ContainerStats] = [:]
    private(set) var lastRefresh: Date?
    private(set) var lastRefreshFailed = false

    /// Fraction of one CPU core used by all containers together, in the same
    /// terms `docker stats` reports: 1.0 is one core saturated, and a container
    /// on four cores can report 4.0. Nil until two samples exist, because it is
    /// derived from the change in cumulative CPU time between them.
    private(set) var totalCPUCores: Double?

    private var previousSample: (stats: [String: ContainerStats], date: Date)?

    var totalMemoryBytes: UInt64 {
        statsByContainerID.values.compactMap(\.memoryUsageBytes).reduce(0, &+)
    }

    var totalMemoryLimitBytes: UInt64 {
        statsByContainerID.values.compactMap(\.memoryLimitBytes).reduce(0, &+)
    }

    /// Memory in use against the sum of the containers' own limits.
    var memoryFraction: Double {
        let limit = totalMemoryLimitBytes
        guard limit > 0 else { return 0 }
        return min(1, Double(totalMemoryBytes) / Double(limit))
    }

    var reportingContainerCount: Int { statsByContainerID.count }

    private let provider: any ContainerStatsListing
    private let interval: Duration
    private var isActive = false
    private var isPaused = false
    private var task: Task<Void, Never>?

    init(provider: any ContainerStatsListing, interval: Duration = .seconds(5)) {
        self.provider = provider
        self.interval = interval
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        updateTask()
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        updateTask()
    }

    func refresh() async {
        guard isActive, !isPaused else { return }
        do {
            let stats = try await provider.allStats()
            let now = Date()
            totalCPUCores = Self.cpuCores(from: previousSample, to: (stats, now))
            previousSample = (stats, now)
            statsByContainerID = stats
            lastRefresh = now
            lastRefreshFailed = false
        } catch is CancellationError {
            return
        } catch CLIError.cancelled {
            return
        } catch {
            lastRefreshFailed = true
        }
    }

    /// CPU time is cumulative, so the rate is the change between two samples.
    /// Containers that restarted (their counter went backwards) and containers
    /// that only appear in one sample are skipped rather than counted as a
    /// spike.
    private static func cpuCores(
        from previous: (stats: [String: ContainerStats], date: Date)?,
        to current: (stats: [String: ContainerStats], date: Date)
    ) -> Double? {
        guard let previous else { return nil }
        let elapsed = current.date.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return nil }

        var deltaMicroseconds: UInt64 = 0
        for (id, now) in current.stats {
            guard let nowCPU = now.cpuUsageMicroseconds,
                  let wasCPU = previous.stats[id]?.cpuUsageMicroseconds,
                  nowCPU >= wasCPU else { continue }
            deltaMicroseconds &+= nowCPU - wasCPU
        }
        return Double(deltaMicroseconds) / (elapsed * 1_000_000)
    }

    private func updateTask() {
        task?.cancel()
        task = nil
        guard isActive, !isPaused else {
            previousSample = nil
            totalCPUCores = nil
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                do {
                    try await Task.sleep(for: self.interval)
                } catch {
                    return
                }
            }
        }
    }
}
