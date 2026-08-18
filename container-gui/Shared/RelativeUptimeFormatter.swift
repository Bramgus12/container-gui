import Foundation

nonisolated struct RelativeUptimeFormatter: Sendable {
    func string(for container: ContainerSummary, now: Date = Date()) -> String {
        switch container.state {
        case .running, .paused:
            guard let startedAt = container.startedAt else { return "running" }
            return compactDuration(from: startedAt, to: now)
        case .stopped:
            guard let createdAt = container.createdAt else { return "stopped" }
            return "stopped \(compactDuration(from: createdAt, to: now))"
        case .created:
            return "created"
        case .unknown(let value):
            return value
        }
    }

    func compactDuration(from start: Date, to end: Date) -> String {
        let totalMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
