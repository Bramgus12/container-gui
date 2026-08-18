import Foundation
import XCTest
@testable import Container_GUI

final class DesignSystemDataTests: XCTestCase {
    func testRelativeUptimeUsesCompactTwoUnitFormatting() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let started = now.addingTimeInterval(-(2 * 86_400 + 4 * 3_600 + 35 * 60))
        let container = try makeContainer(
            id: "web",
            image: "example/web:1",
            state: "running",
            createdAt: now.addingTimeInterval(-300_000),
            startedAt: started
        )

        XCTAssertEqual(RelativeUptimeFormatter().string(for: container, now: now), "2d 4h")
    }

    func testInventoryIndexMatchesImageVolumeAndNetworkReferences() throws {
        let container = try makeContainer(
            id: "web",
            image: "example/web:1",
            digest: "sha256:web",
            state: "running",
            mounts: ["data"],
            networks: ["frontend"]
        )
        let imageDTO = try JSONDecoder().decode(
            ImageDTO.self,
            from: Data(#"{"reference":"example/web:1","digest":"sha256:web"}"#.utf8)
        )
        let volumeDTO = try JSONDecoder().decode(
            VolumeDTO.self,
            from: Data(#"{"id":"data","configuration":{"name":"data"}}"#.utf8)
        )
        let networkDTO = try JSONDecoder().decode(
            NetworkDTO.self,
            from: Data(#"{"id":"frontend","configuration":{"name":"frontend"}}"#.utf8)
        )
        let image = try XCTUnwrap(ImageSummary(dto: imageDTO))
        let volume = try XCTUnwrap(VolumeSummary(dto: volumeDTO))
        let network = try XCTUnwrap(NetworkSummary(dto: networkDTO))

        let index = InventoryIndex(
            containers: [container],
            images: [image],
            volumes: [volume],
            networks: [network]
        )

        XCTAssertEqual(index.containers(using: image).map(\.id), ["web"])
        XCTAssertEqual(index.containers(attachedTo: volume).map(\.id), ["web"])
        XCTAssertEqual(index.attachedContainerCount(for: network), 1)
    }

    func testPortSummaryKeepsTwoMappingsAndCountsTheRemainder() throws {
        let container = try makeContainer(
            id: "web",
            image: "example/web:1",
            state: "running",
            ports: [
                ["hostPort": 8_080, "containerPort": 80, "protocol": "tcp"],
                ["containerPort": 443, "protocol": "udp"],
                ["hostPort": 9_000, "containerPort": 9_000, "protocol": "tcp"],
            ]
        )

        XCTAssertEqual(container.portSummary, "8080:80/tcp, 443/udp +1")
    }

    func testSidebarDiskAggregationIncludesEveryResourceAndReclaimableByte() throws {
        let data = Data(
            #"[{"type":"images","sizeBytes":100,"reclaimableBytes":30},{"type":"volumes","sizeBytes":50,"reclaimableBytes":10}]"#.utf8
        )
        let usage = try SystemDiskUsage.decode(from: data)

        XCTAssertEqual(usage.totalSizeBytes, 150)
        XCTAssertEqual(usage.totalReclaimableBytes, 40)
    }

    func testDiskUsageSegmentsSplitReclaimableOutOfEachResource() throws {
        let data = Data(
            #"[{"type":"images","sizeBytes":100,"reclaimableBytes":30},{"type":"volumes","sizeBytes":50,"reclaimableBytes":10}]"#.utf8
        )
        let usage = try SystemDiskUsage.decode(from: data)
        let segments = usage.usageSegments
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.bytes) })

        XCTAssertEqual(byID["images"], 70)
        XCTAssertEqual(byID["volumes"], 40)
        XCTAssertEqual(byID["reclaimable"], 40)
        // The segments must account for the total exactly, or the bar lies.
        XCTAssertEqual(segments.reduce(0) { $0 + $1.bytes }, usage.totalSizeBytes)
    }

    /// Captured verbatim from `container system df --format json` on 1.2.2.
    /// The CLI spells the size key `sizeInBytes`, which an earlier decoder did
    /// not accept, so every figure decoded as nil and the bars read zero.
    func testDecodesTheDiskUsageShapeTheCLIActuallyEmits() throws {
        let data = Data("""
        {
          "containers" : { "active" : 1, "reclaimable" : 1617645568, "sizeInBytes" : 5187059712, "total" : 2 },
          "images" : { "active" : 2, "reclaimable" : 257511424, "sizeInBytes" : 8960290816, "total" : 3 },
          "volumes" : { "active" : 0, "reclaimable" : 0, "sizeInBytes" : 0, "total" : 0 }
        }
        """.utf8)

        let usage = try SystemDiskUsage.decode(from: data)

        XCTAssertEqual(usage.resource(named: "image")?.sizeBytes, 8_960_290_816)
        XCTAssertEqual(usage.resource(named: "container")?.sizeBytes, 5_187_059_712)
        XCTAssertEqual(usage.resource(named: "image")?.totalCount, 3)
        XCTAssertEqual(usage.totalSizeBytes, 14_147_350_528)
        XCTAssertEqual(usage.totalReclaimableBytes, 1_875_156_992)
        XCTAssertGreaterThan(usage.usageSegments.reduce(0) { $0 + $1.bytes }, 0)
    }

    @MainActor
    func testTotalsAndCPURateAreDerivedAcrossContainers() async throws {
        let provider = RampingStatsStub()
        let poller = ContainerStatsPoller(provider: provider, interval: .milliseconds(20))

        poller.setActive(true)
        try await eventuallyTrue { poller.totalCPUCores != nil }

        // Two containers, 1 GB + 512 MB in use against 2 GB + 1 GB of limits.
        XCTAssertEqual(poller.totalMemoryBytes, 1_610_612_736)
        XCTAssertEqual(poller.totalMemoryLimitBytes, 3_221_225_472)
        XCTAssertEqual(poller.memoryFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(poller.reportingContainerCount, 2)

        // Both counters advance, so the rate must be positive and finite.
        let cores = try XCTUnwrap(poller.totalCPUCores)
        XCTAssertGreaterThan(cores, 0)
        XCTAssertLessThan(cores, 64)

        poller.setActive(false)
        // A stopped poller must not keep reporting a rate from before it paused.
        XCTAssertNil(poller.totalCPUCores)
    }

    @MainActor
    private func eventuallyTrue(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was never met.")
    }

    func testTableColumnSortingOrdersRowsAndFlipsOnReverse() throws {
        let columns: [DSTableColumn<ContainerSummary>] = [
            DSTableColumn("id", "Container") {
                $0.id.localizedStandardCompare($1.id) == .orderedAscending
            },
            DSTableColumn("ports", "Ports"),
        ]
        let rows = [
            try makeContainer(id: "web-10", image: "a", state: "running"),
            try makeContainer(id: "web-2", image: "a", state: "running"),
            try makeContainer(id: "api", image: "a", state: "running"),
        ]

        let ascending = try XCTUnwrap(columns[0].ascending)
        // Standard comparison must order web-2 before web-10, not lexically.
        XCTAssertEqual(rows.sorted(by: ascending).map(\.id), ["api", "web-2", "web-10"])
        XCTAssertEqual(
            rows.sorted { ascending($1, $0) }.map(\.id),
            ["web-10", "web-2", "api"]
        )

        // A column without a comparator is not sortable, and must stay that way
        // rather than silently falling back to some other order.
        XCTAssertNil(columns[1].ascending)
    }

    @MainActor
    func testBundledGeistMonoCanBeRegistered() {
        XCTAssertTrue(DSFont.registerBundledFontsIfNeeded())
        XCTAssertTrue(DSFont.isGeistMonoAvailable)
    }

    @MainActor
    func testStatsPollerRunsOnlyWhenActiveAndUnpaused() async throws {
        let provider = StatsProviderStub()
        let poller = ContainerStatsPoller(provider: provider, interval: .milliseconds(15))

        poller.setActive(true)
        try await Task.sleep(for: .milliseconds(45))
        let activeCount = await provider.callCount
        XCTAssertGreaterThanOrEqual(activeCount, 2)
        XCTAssertEqual(poller.statsByContainerID["web"]?.memoryUsageBytes, 1_024)

        poller.setPaused(true)
        let pausedCount = await provider.callCount
        try await Task.sleep(for: .milliseconds(40))
        let countAfterPause = await provider.callCount
        XCTAssertEqual(countAfterPause, pausedCount)
        poller.setActive(false)
    }

    private func makeContainer(
        id: String,
        image: String,
        digest: String? = nil,
        state: String,
        createdAt: Date? = nil,
        startedAt: Date? = nil,
        mounts: [String] = [],
        networks: [String] = [],
        ports: [[String: Any]] = []
    ) throws -> ContainerSummary {
        let formatter = ISO8601DateFormatter()
        var imageObject: [String: Any] = ["reference": image]
        if let digest { imageObject["digest"] = digest }
        var configuration: [String: Any] = [
            "id": id,
            "image": imageObject,
            "mounts": mounts.map { ["source": $0, "destination": "/data"] },
            "publishedPorts": ports,
        ]
        if let createdAt { configuration["creationDate"] = formatter.string(from: createdAt) }
        var status: [String: Any] = [
            "state": state,
            "networks": networks.map { ["network": $0] },
        ]
        if let startedAt { status["startedDate"] = formatter.string(from: startedAt) }
        let data = try JSONSerialization.data(withJSONObject: [
            "configuration": configuration,
            "status": status,
        ])
        return try XCTUnwrap(ContainerSummary(dto: JSONDecoder().decode(ContainerDTO.self, from: data)))
    }
}

/// Two containers whose cumulative CPU counters climb on every sample.
private actor RampingStatsStub: ContainerStatsListing {
    private var tick: UInt64 = 0

    func allStats() -> [String: ContainerStats] {
        tick += 1
        let entries = [
            ContainerStats(dto: ContainerStatsDTO(
                id: "web",
                memoryUsageBytes: 1_073_741_824,
                memoryLimitBytes: 2_147_483_648,
                cpuUsageUsec: tick * 10_000,
                networkRxBytes: nil,
                networkTxBytes: nil,
                blockReadBytes: nil,
                blockWriteBytes: nil,
                numProcesses: nil
            )),
            ContainerStats(dto: ContainerStatsDTO(
                id: "db",
                memoryUsageBytes: 536_870_912,
                memoryLimitBytes: 1_073_741_824,
                cpuUsageUsec: tick * 5_000,
                networkRxBytes: nil,
                networkTxBytes: nil,
                blockReadBytes: nil,
                blockWriteBytes: nil,
                numProcesses: nil
            )),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }
}

private actor StatsProviderStub: ContainerStatsListing {
    private(set) var callCount = 0

    func allStats() -> [String: ContainerStats] {
        callCount += 1
        let value = ContainerStats(dto: ContainerStatsDTO(
            id: "web",
            memoryUsageBytes: 1_024,
            memoryLimitBytes: 2_048,
            cpuUsageUsec: nil,
            networkRxBytes: nil,
            networkTxBytes: nil,
            blockReadBytes: nil,
            blockWriteBytes: nil,
            numProcesses: nil
        ))
        return [value.id: value]
    }
}
