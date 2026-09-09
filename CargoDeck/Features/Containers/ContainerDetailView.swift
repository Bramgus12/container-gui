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
        _model = State(initialValue: appModel.makeContainerDetailModel(containerID: containerID))
    }

    var body: some View {
        if let model {
            ContainerActivityView(model: model, appModel: appModel)
        } else {
            EmptyState(
                "Details Unavailable",
                systemImage: "exclamationmark.triangle",
                description: "The container executable is not ready."
            )
        }
    }
}

@MainActor
private struct ContainerActivityView: View {
    @Bindable var model: ContainerDetailModel
    let appModel: AppModel
    @State private var showsConfiguration = false

    var body: some View {
        VStack(spacing: 0) {
            ContainerActivityHeader(
                containerID: model.containerID,
                state: state,
                isBusy: appModel.mutationInProgress(for: model.containerID) != nil,
                stop: stop,
                showConfiguration: { showsConfiguration = true }
            )

            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)

            ContainerMetricGrid(stats: model.stats, error: model.statsError)
                .padding(DSMetrics.spacing12)

            ContainerLogsSection(model: model)

            CommandStrip(
                command: "container logs -f \(model.containerID)",
                minHeight: 32
            )
        }
        // Fills the inspector and keeps its native background, the way the image
        // inspector does. Painting a canvas here left the material showing below
        // the content wherever the pane was taller than the stack.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsCanvas.ignoresSafeArea())
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.dsHairline)
                .frame(width: DSMetrics.hairline)
                .ignoresSafeArea()
        }
        .navigationTitle(model.containerID)
        .task { await model.appear() }
        .onDisappear { model.disappear() }
        .sheet(isPresented: $showsConfiguration) {
            ContainerConfigSheet(model: model)
        }
    }

    private var state: ContainerState {
        if let current = appModel.containers.first(where: { $0.id == model.containerID }) {
            return current.state
        }
        if case .loaded(let inspection) = model.inspectionState {
            return inspection.details.summary.state
        }
        return .unknown("unknown")
    }

    private func stop() {
        Task { await appModel.perform(.stop, on: model.containerID) }
    }
}

private struct ContainerActivityHeader: View {
    let containerID: String
    let state: ContainerState
    let isBusy: Bool
    let stop: () -> Void
    let showConfiguration: () -> Void

    var body: some View {
        HStack(spacing: DSMetrics.spacing12) {
            StateChip(title: state.localizedTitle, state: state.designState)
            MonoText(value: containerID, truncation: .middle)
                .font(.dsCardHeading)
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Stop", systemImage: "stop.fill", action: stop)
                .disabled(isBusy || !(state == .running || state == .paused))
            Button("Config", systemImage: "slider.horizontal.3", action: showConfiguration)
                .accessibilityIdentifier("container.detail.config")
        }
        .padding(DSMetrics.spacing12)
        .background(Color.dsCanvas)
    }
}

private struct ContainerMetricGrid: View {
    let stats: ContainerStats?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
            if let error {
                InlineBanner(message: "Stats unavailable", detail: error, scope: .row, severity: .attention)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DSMetrics.spacing8) { tiles }
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: DSMetrics.spacing8
                ) { tiles }
            }
        }
    }

    @ViewBuilder
    private var tiles: some View {
        MetricTile(
            value: stats?.memoryUsageBytes.map(Self.formatBytes) ?? "—",
            unit: nil,
            caption: "Memory"
        )
        MetricTile(
            value: stats?.cpuUsageMicroseconds.map(Self.formatCPUTime) ?? "—",
            unit: nil,
            caption: "CPU time"
        )
        MetricTile(
            value: Self.ioPair(stats?.networkReceivedBytes, stats?.networkTransmittedBytes),
            unit: nil,
            caption: "Net rx / tx"
        )
        MetricTile(
            value: Self.ioPair(stats?.blockReadBytes, stats?.blockWrittenBytes),
            unit: nil,
            caption: "Block r / w"
        )
    }

    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }

    nonisolated private static func formatCPUTime(_ microseconds: UInt64) -> String {
        let seconds = Double(microseconds) / 1_000_000
        return seconds.formatted(.number.precision(.fractionLength(0...2))) + "s"
    }

    nonisolated private static func ioPair(_ first: UInt64?, _ second: UInt64?) -> String {
        guard first != nil || second != nil else { return "—" }
        return "\(first.map(formatBytes) ?? "—") / \(second.map(formatBytes) ?? "—")"
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
                searchText: $model.logSearchText,
                filter: $model.logFilter,
                followsLogs: $model.followsLogs,
                counts: model.logCounts,
                isPaused: model.isLogPaused,
                isStreaming: model.isLogStreaming,
                hasLogs: model.logCounts.all > 0,
                isAtLatest: isTailing,
                pauseOrResume: model.toggleLogPause,
                copy: copyLogs,
                clear: model.clearLogs,
                jumpToLatest: jumpToLatest
            )

            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)

            if let error = model.logError {
                InlineBanner(message: "Log stream stopped", detail: error, scope: .bar, severity: .error)
                    .padding([.horizontal, .top], DSMetrics.spacing8)
            }

            LogViewer(snapshot: model.logSnapshot, jumpToLatestRequest: jumpToLatestRequest) { value in
                Task { @MainActor in isTailing = value }
            }
            .overlay {
                if model.logSnapshot.text.isEmpty {
                    Text(model.logCounts.all == 0 ? "Waiting for logs…" : "No matching log lines")
                        .foregroundStyle(Color.dsTextSecondary)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("logs.waiting")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("logs.viewerContainer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsSurface)
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
    @Binding var searchText: String
    @Binding var filter: LogFilter
    @Binding var followsLogs: Bool
    let counts: LogCounts
    let isPaused: Bool
    let isStreaming: Bool
    let hasLogs: Bool
    let isAtLatest: Bool
    let pauseOrResume: () -> Void
    let copy: () -> Void
    let clear: () -> Void
    let jumpToLatest: () -> Void

    var body: some View {
        VStack(spacing: DSMetrics.spacing8) {
            HStack(spacing: DSMetrics.spacing8) {
                TextField("Filter logs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("logs.filter")
                Picker("Severity", selection: $filter) {
                    Text("All \(counts.all)").tag(LogFilter.all)
                    Text("Warn \(counts.warnings)").tag(LogFilter.warning)
                    Text("Err \(counts.errors)").tag(LogFilter.error)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            HStack(spacing: DSMetrics.spacing8) {
                Toggle("Follow", isOn: $followsLogs)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("logs.follow")
                Spacer()
                LogJumpToLatestButton(isAtLatest: isAtLatest, action: jumpToLatest)
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
        }
        .controlSize(.small)
        .padding(DSMetrics.spacing8)
    }
}

/// The two pages of the configuration sheet, in the order the rail lists them.
/// They replace the segmented picker so the sheet is paged like the others.
enum ContainerConfigSection: String, SheetSection {
    case overview
    case configuration

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .configuration: "Configuration"
        }
    }
}

@MainActor
private struct ContainerConfigSheet: View {
    @Bindable var model: ContainerDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var page = ContainerConfigSection.overview

    var body: some View {
        // Nothing here runs a command, so the footer carries only Done.
        SheetScaffold {
            SheetRailPane(
                title: "Container",
                selection: $page,
                accessibilityID: "container.config.rail"
            ) {
                pane
                    .background(Color.dsCanvas)
            }
        } footer: {
            Spacer()

            SheetPagingButtons(selection: $page, accessibilityIDPrefix: "container.config")

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("container.config.done")
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch model.inspectionState {
        case .loading:
            ProgressView("Inspecting container…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyState(
                "Inspection Failed",
                systemImage: "exclamationmark.triangle",
                message: message
            ) {
                Button("Try Again") { Task { await model.reloadInspection() } }
            }
        case .loaded(let inspection):
            switch page {
            case .overview:
                ContainerOverviewView(details: inspection.details)
            case .configuration:
                ContainerConfigurationView(inspection: inspection)
            }
        }
    }
}

private struct ContainerOverviewView: View {
    let details: ContainerDetails

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSMetrics.spacing16) {
                OverviewCard(title: "Container", rows: [
                    ("ID / Name", details.id),
                    ("State", details.summary.state.localizedTitleString),
                    ("Image", details.summary.image ?? "—"),
                    ("Platform", [details.summary.operatingSystem, details.summary.architecture].compactMap { $0 }.joined(separator: " / ")),
                    ("Address", details.summary.address ?? "—"),
                ])
                OverviewCard(title: "Resources", rows: [
                    ("CPUs", details.resources?.cpus.map(String.init) ?? "Unlimited"),
                    ("Memory", details.resources?.memoryInBytes.map(ContainerMetricGrid.formatBytes) ?? "Unlimited"),
                    ("Ports", details.summary.portSummary),
                    ("Mounts", details.mounts.map { $0.source ?? $0.destination ?? "—" }.joined(separator: ", ").nilIfEmpty ?? "None"),
                ])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSMetrics.spacing16)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OverviewCard: View {
    let title: LocalizedStringResource
    let rows: [(LocalizedStringResource, String)]

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSMetrics.spacing12) {
                SectionLabel(title: title)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.0) { MonoText(value: row.1, truncation: .middle) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
