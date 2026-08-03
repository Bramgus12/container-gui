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
            .padding()

            Divider()

            switch model.selectedTab {
            case .overview:
                overview
            case .logs:
                logs
            case .inspect:
                inspect
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

    private var logs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Follow", isOn: $model.followsLogs)
                .toggleStyle(.switch)

                Toggle("Autoscroll", isOn: $model.autoscrollsLogs)
                    .toggleStyle(.switch)

                Spacer()

                Button(model.isLogPaused ? "Resume" : "Pause") {
                    model.toggleLogPause()
                }
                .disabled(!model.isLogStreaming)

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                .disabled(model.logText.isEmpty)

                Button("Clear") {
                    model.clearLogs()
                }
                .disabled(model.logText.isEmpty)
            }
            .controlSize(.small)
            .padding(10)

            Divider()

            if let error = model.logError {
                errorBanner(error)
            }

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(model.logText.isEmpty ? "Waiting for logs…" : model.logText)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(model.logText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                    Color.clear
                        .frame(height: 1)
                        .id("logs.bottom")
                }
                .onChange(of: model.logRevision) {
                    guard model.autoscrollsLogs else { return }
                    proxy.scrollTo("logs.bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var inspect: some View {
        switch model.inspectionState {
        case .loading:
            ProgressView("Formatting inspection JSON…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            failureView(title: "Inspection Failed", message: message) {
                Task { await model.reloadInspection() }
            }
        case .loaded(let inspection):
            ScrollView([.vertical, .horizontal]) {
                Text(inspection.formattedJSON)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
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
