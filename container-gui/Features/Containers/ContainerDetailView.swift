import AppKit
import SwiftUI

@MainActor
struct ContainerDetailHost: View {
    let appModel: AppModel
    let containerID: String
    @State private var model: ContainerDetailModel?

    init(appModel: AppModel, containerID: String) {
        self.appModel = appModel
        self.containerID = containerID
        _model = State(
            initialValue: appModel.makeContainerDetailModel(containerID: containerID)
        )
    }

    var body: some View {
        Group {
            if let model {
                ContainerDetailView(model: model)
            } else {
                ContentUnavailableView(
                    "Details Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The container executable is not ready.")
                )
            }
        }
    }
}

@MainActor
private struct ContainerDetailView: View {
    @Bindable var model: ContainerDetailModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Detail", selection: $model.selectedTab) {
                ForEach(ContainerDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("container.detail.tabs")
            .padding()

            Divider()

            switch model.selectedTab {
            case .overview:
                overview
            case .logs:
                ContainerLogsSection(model: model)
            case .configuration:
                configuration
            case .stats:
                stats
            }
        }
        .navigationTitle(model.containerID)
        .task {
            await model.appear()
        }
        .onDisappear {
            model.disappear()
        }
    }

    @ViewBuilder
    private var overview: some View {
        switch model.inspectionState {
        case .loading:
            ProgressView("Inspecting container…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            failureView(title: "Inspection Failed", message: message) {
                Task { await model.reloadInspection() }
            }
        case .loaded(let inspection):
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailSection("Container") {
                        detailRow("ID / Name", inspection.details.id)
                        detailRow("State", inspection.details.summary.state.displayName)
                        detailRow("Image", inspection.details.summary.image ?? "—")
                        detailRow(
                            "Platform",
                            [
                                inspection.details.summary.operatingSystem,
                                inspection.details.summary.architecture,
                            ]
                            .compactMap { $0 }
                            .joined(separator: " / ")
                        )
                    }

                    detailSection("Resources") {
                        detailRow(
                            "CPUs",
                            inspection.details.resources?.cpus.map(String.init) ?? "Unlimited"
                        )
                        detailRow(
                            "Memory",
                            inspection.details.resources?.memoryInBytes.map(formatBytes)
                                ?? "Unlimited"
                        )
                    }

                    detailSection("Networks") {
                        if inspection.details.networks.isEmpty {
                            Text("No networks")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(inspection.details.networks) { network in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(network.name ?? "Network")
                                        .fontWeight(.medium)
                                    Text(
                                        [
                                            network.hostname,
                                            network.ipv4Address,
                                            network.ipv6Address,
                                            network.macAddress,
                                        ]
                                        .compactMap { $0 }
                                        .joined(separator: "  •  ")
                                    )
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    detailSection("Published Ports") {
                        if inspection.details.ports.isEmpty {
                            Text("No published ports")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(inspection.details.ports) { port in
                                detailRow(
                                    "\(port.containerPort.map(String.init) ?? "—")/\(port.proto ?? "tcp")",
                                    "\(port.hostAddress ?? "0.0.0.0"):\(port.hostPort.map(String.init) ?? "—")"
                                )
                            }
                        }
                    }

                    detailSection("Mounts") {
                        if inspection.details.mounts.isEmpty {
                            Text("No mounts")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(inspection.details.mounts) { mount in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mount.destination ?? "—")
                                        .fontWeight(.medium)
                                    Text(
                                        [mount.source, mount.options?.joined(separator: ", ")]
                                            .compactMap { $0 }
                                            .joined(separator: "  •  ")
                                    )
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var configuration: some View {
        switch model.inspectionState {
        case .loading:
            ProgressView("Loading configuration…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            failureView(title: "Inspection Failed", message: message) {
                Task { await model.reloadInspection() }
            }
        case .loaded(let inspection):
            ContainerConfigurationView(inspection: inspection)
        }
    }

    private var stats: some View {
        Group {
            if model.isStatsLoading, model.stats == nil {
                ProgressView("Loading stats…")
            } else if let stats = model.stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = model.statsError {
                            errorBanner(error)
                        }

                        detailSection("Resource Usage") {
                            metricRow(
                                "Memory",
                                current: stats.memoryUsageBytes.map(formatBytes) ?? "—",
                                secondary: stats.memoryLimitBytes.map { "of \(formatBytes($0))" }
                            )
                            metricRow(
                                "CPU time",
                                current: stats.cpuUsageMicroseconds.map {
                                    formatDuration(microseconds: $0)
                                } ?? "—"
                            )
                            metricRow(
                                "Processes",
                                current: stats.processCount.map(String.init) ?? "—"
                            )
                        }

                        detailSection("Network I/O") {
                            metricRow(
                                "Received",
                                current: stats.networkReceivedBytes.map(formatBytes) ?? "—"
                            )
                            metricRow(
                                "Transmitted",
                                current: stats.networkTransmittedBytes.map(formatBytes) ?? "—"
                            )
                        }

                        detailSection("Block I/O") {
                            metricRow(
                                "Read",
                                current: stats.blockReadBytes.map(formatBytes) ?? "—"
                            )
                            metricRow(
                                "Written",
                                current: stats.blockWrittenBytes.map(formatBytes) ?? "—"
                            )
                        }
                    }
                    .padding()
                }
            } else if let error = model.statsError {
                failureView(title: "Stats Failed", message: error, retry: nil)
            } else {
                ProgressView("Loading stats…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value.isEmpty ? "—" : value)
            .textSelection(.enabled)
    }

    private func metricRow(
        _ label: String,
        current: String,
        secondary: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(current)
                .fontWeight(.medium)
                .textSelection(.enabled)
            if let secondary {
                Text(secondary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.red.opacity(0.08))
    }

    private func failureView(
        title: String,
        message: String,
        retry: (() -> Void)?
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            if let retry {
                Button("Try Again", action: retry)
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .binary
        )
    }

    private func formatDuration(microseconds: UInt64) -> String {
        let seconds = Double(microseconds) / 1_000_000
        return seconds.formatted(.number.precision(.fractionLength(0...2))) + " s"
    }
}

@MainActor
private struct ContainerLogsSection: View {
    @Bindable var model: ContainerDetailModel
    @State private var isTailing = true
    @State private var jumpToLatestRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            ContainerLogControls(
                followsLogs: $model.followsLogs,
                isPaused: model.isLogPaused,
                isStreaming: model.isLogStreaming,
                hasLogs: !model.logSnapshot.text.isEmpty,
                isAtLatest: isTailing,
                pauseOrResume: model.toggleLogPause,
                copy: copyLogs,
                clear: model.clearLogs,
                jumpToLatest: jumpToLatest
            )

            Divider()

            if let error = model.logError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.08))
            }

            LogViewer(
                snapshot: model.logSnapshot,
                jumpToLatestRequest: jumpToLatestRequest
            ) { value in
                Task { @MainActor in
                    isTailing = value
                }
            }
            .overlay {
                if model.logSnapshot.text.isEmpty {
                    Text("Waiting for logs…")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("logs.waiting")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("logs.viewerContainer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.logSnapshot.text, forType: .string)
    }

    private func jumpToLatest() {
        jumpToLatestRequest &+= 1
        isTailing = true
    }
}

private struct ContainerLogControls: View {
    @Binding var followsLogs: Bool
    let isPaused: Bool
    let isStreaming: Bool
    let hasLogs: Bool
    let isAtLatest: Bool
    let pauseOrResume: () -> Void
    let copy: () -> Void
    let clear: () -> Void
    let jumpToLatest: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Follow", isOn: $followsLogs)
                .toggleStyle(.switch)
                .accessibilityIdentifier("logs.follow")

            Spacer()

            LogJumpToLatestButton(
                isAtLatest: isAtLatest,
                action: jumpToLatest
            )
                .accessibilityIdentifier("logs.jumpToLatest")

            Button(isPaused ? "Resume" : "Pause", action: pauseOrResume)
                .disabled(!isStreaming)
                .accessibilityIdentifier("logs.pause")

            LogCopyButton(hasLogs: hasLogs, action: copy)
                .accessibilityIdentifier("logs.copy")

            Button("Clear", action: clear)
                .disabled(!hasLogs)
                .accessibilityIdentifier("logs.clear")
        }
        .controlSize(.small)
        .padding(10)
    }
}
