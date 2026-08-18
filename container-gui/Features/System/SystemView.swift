import AppKit
import SwiftUI

struct SystemView: View {
    @Bindable var model: SystemModel
    let builder: BuilderModel?
    let updates: UpdateModel
    @State private var confirmsStop = false
    @State private var showsDiagnostics = false
    @State private var confirmsReclaim = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: DSMetrics.spacing12) {
                    ServiceCard(model: model, confirmsStop: $confirmsStop)
                    if let builder {
                        BuilderCard(model: builder)
                    }
                    UpdateCard(model: updates)
                }
                SystemDiskUsageSection(model: model, reclaim: { confirmsReclaim = true })
                SystemLogsSection(model: model)
                UpdateSection(model: updates)
            }
            .padding(24)
            .frame(maxWidth: 1_000, alignment: .leading)
        }
        .navigationTitle("System")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task {
                        await model.refresh()
                        await builder?.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isWorking)
                .accessibilityIdentifier("system.refresh")

                Button {
                    showsDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("system.diagnostics")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.actionError {
                InlineBanner(
                    message: "System action failed",
                    detail: error,
                    scope: .bar,
                    severity: .error,
                    copyValue: error,
                    onDismiss: model.dismissActionError
                )
                .accessibilityIdentifier("system.actionError")
            }
        }
        .alert("Stop Container Services?", isPresented: $confirmsStop) {
            Button("Stop Service", role: .destructive) {
                Task { await model.perform(.stop) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                Running containers will stop and Container GUI will be unavailable \
                until the services are started again.
                """
            )
        }
        .alert("Reclaim Unused Resources?", isPresented: $confirmsReclaim) {
            Button("Reclaim", role: .destructive) {
                Task { await model.reclaimUnusedResources() }
            }
            .accessibilityIdentifier("system.reclaim.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(reclaimMessage)
        }
        .sheet(isPresented: $showsDiagnostics) {
            SystemDiagnosticsSheet(model: model, isPresented: $showsDiagnostics)
        }
        .task {
            if model.snapshotState == .idle {
                await model.refresh()
            }
            await builder?.loadIfNeeded()
        }
        .accessibilityIdentifier("system.screen")
    }

    private var reclaimMessage: String {
        guard let usage = model.diskUsage else {
            return "Unused images and volumes will be permanently deleted."
        }
        let images = usage.resource(named: "image")?.reclaimableBytes ?? 0
        let volumes = usage.resource(named: "volume")?.reclaimableBytes ?? 0
        return "This permanently deletes up to \(Self.formatBytes(images)) of unused images and \(Self.formatBytes(volumes)) of unused volumes."
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

}

/// The shell all three glance cards share: a section label, the state line, the
/// detail rows, and the card's own actions pinned to the bottom.
private struct SystemCard<Content: View, Actions: View>: View {
    let title: LocalizedStringResource
    let value: LocalizedStringResource
    let state: DSState
    private let content: Content
    private let actions: Actions

    init(
        title: LocalizedStringResource,
        value: LocalizedStringResource,
        state: DSState,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.value = value
        self.state = state
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
                SectionLabel(title: title)
                StateDot(state, label: value, accessibilityLabel: value)
                    .font(.dsCardHeading)
                content
                Spacer(minLength: DSMetrics.spacing8)
                HStack(spacing: DSMetrics.spacing8) { actions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SystemCardRow: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
            Spacer(minLength: DSMetrics.spacing8)
            MonoText(value: value, dimmed: true, truncation: .middle)
        }
    }
}

private struct ServiceCard: View {
    let model: SystemModel
    @Binding var confirmsStop: Bool

    var body: some View {
        SystemCard(
            title: "Service",
            value: model.status.isRunning ? "Running" : "Stopped",
            state: model.status.isRunning ? .running : .attention
        ) {
            SystemCardRow(label: "CLI", value: model.versions.cli?.version ?? "Unavailable")
            SystemCardRow(
                label: "Server",
                value: model.versions.server?.version ?? model.status.version ?? "Unavailable"
            )
            if let message = model.status.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
                    .textSelection(.enabled)
            }
        } actions: {
            if let operation = model.serviceOperation {
                ProgressView(operation.localizedDescription).controlSize(.small)
            } else if model.status.isRunning {
                Button("Stop Service…", role: .destructive) { confirmsStop = true }
                    .accessibilityIdentifier("system.stop")
            } else {
                Button("Start Service") { Task { await model.perform(.start) } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("system.start")
            }
        }
    }
}

private struct BuilderCard: View {
    let model: BuilderModel
    @State private var cpuLimit = ""
    @State private var memoryLimit = ""
    @State private var confirmsDelete = false

    var body: some View {
        SystemCard(title: "Builder", value: value, state: state) {
            switch model.loadingState {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed(let message):
                InlineBanner(
                    message: "Builder status unavailable",
                    detail: message,
                    scope: .row,
                    severity: .attention,
                    actionTitle: "Try Again",
                    action: { Task { await model.refresh() } }
                )
            case .loaded:
                if let image = model.status.image {
                    SystemCardRow(label: "Image", value: image)
                }
                if let id = model.status.id {
                    SystemCardRow(label: "ID", value: id)
                }
                if let address = model.status.address {
                    SystemCardRow(label: "Address", value: address)
                }
                if model.status.state == .absent {
                    HStack(spacing: DSMetrics.spacing8) {
                        TextField("CPUs", text: $cpuLimit)
                        TextField("Memory", text: $memoryLimit)
                    }
                    .controlSize(.small)
                }
            }
            if let error = model.actionError {
                InlineBanner(
                    message: "Builder action failed",
                    detail: error,
                    scope: .row,
                    severity: .error,
                    copyValue: error,
                    onDismiss: model.dismissActionError
                )
            }
        } actions: {
            if model.operation != nil {
                ProgressView().controlSize(.small)
            } else {
                BuilderActions(
                    state: model.status.state,
                    isBusy: model.isBusy,
                    start: {
                        Task {
                            await model.start(
                                cpuLimit: optionalTrimmed(cpuLimit),
                                memoryLimit: optionalTrimmed(memoryLimit)
                            )
                        }
                    },
                    stop: { Task { await model.stop() } },
                    delete: { confirmsDelete = true }
                )
            }
        }
        .alert("Delete Image Builder?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stopped builder container will be permanently deleted. A future image build can create it again.")
        }
    }

    private var value: LocalizedStringResource {
        switch model.status.state {
        case .running: "Running"
        case .stopped: "Stopped"
        case .absent: "Not created"
        case .unknown: "Unknown"
        }
    }

    private var state: DSState {
        switch model.status.state {
        case .running: .running
        case .stopped: .attention
        case .absent, .unknown: .idle
        }
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct UpdateCard: View {
    let model: UpdateModel

    var body: some View {
        SystemCard(
            title: "Update",
            value: model.availableRelease == nil ? "Up to date" : "Available",
            state: model.availableRelease == nil ? .running : .attention
        ) {
            SystemCardRow(label: "Installed", value: model.installedVersionDescription)
            if let release = model.availableRelease {
                SystemCardRow(label: "Latest", value: release.version.description)
            }
        } actions: {
            if model.isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button("Check Now") { Task { await model.checkNow() } }
                    .accessibilityIdentifier("system.update.checkCard")
            }
        }
    }
}

private struct BuilderActions: View {
    let state: BuilderState
    let isBusy: Bool
    let start: () -> Void
    let stop: () -> Void
    let delete: () -> Void

    var body: some View {
        switch state {
        case .absent:
            Button("Start Builder", action: start)
                .disabled(isBusy)
                .accessibilityIdentifier("system.builder.start")
        case .running:
            Button("Stop Builder", action: stop)
                .disabled(isBusy)
                .accessibilityIdentifier("system.builder.stop")
        case .stopped:
            Button("Start Builder", action: start)
                .disabled(isBusy)
                .accessibilityIdentifier("system.builder.start")
            Button("Delete Builder…", role: .destructive, action: delete)
                .disabled(isBusy)
                .accessibilityIdentifier("system.builder.delete")
        case .unknown:
            EmptyView()
        }
    }
}

private struct SystemDiskUsageSection: View {
    let model: SystemModel
    let reclaim: () -> Void

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSMetrics.spacing12) {
            HStack {
                Label("Disk Usage", systemImage: "internaldrive").font(.dsCardHeading)
                Spacer()
                if let reclaimable = model.diskUsage?.totalReclaimableBytes, reclaimable > 0 {
                    Button("Reclaim \(Self.formatBytes(reclaimable))…", action: reclaim)
                        .disabled(model.isReclaiming)
                        .accessibilityIdentifier("system.reclaim")
                }
            }
            switch model.snapshotState {
            case .idle where model.diskUsage == nil,
                 .loading where model.diskUsage == nil:
                ProgressView("Loading disk usage…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .failed(let error) where model.diskUsage == nil:
                SystemUnavailableView(
                    title: "Disk Usage Unavailable",
                    error: error,
                    model: model
                )
            default:
                if let resources = model.diskUsage?.resources {
                    if let usage = model.diskUsage {
                        Text("\(Self.formatBytes(usage.totalSizeBytes)) used · \(Self.formatBytes(usage.totalReclaimableBytes)) reclaimable")
                            .foregroundStyle(Color.dsTextSecondary)
                        StackedUsageBar(segments: usage.usageSegments, height: 10)
                        VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                            StackedUsageLegend(segments: usage.usageSegments)
                        }
                        .font(.caption)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        GridRow {
                            Text("Resource").fontWeight(.semibold)
                            Text("Total").fontWeight(.semibold)
                            Text("Active").fontWeight(.semibold)
                            Text("Size").fontWeight(.semibold)
                            Text("Reclaimable").fontWeight(.semibold)
                        }
                        Divider().gridCellColumns(5)
                        ForEach(resources) { resource in
                            GridRow {
                                Text(resource.type?.capitalized ?? "Unknown")
                                MonoText(value: resource.totalCount.map(String.init) ?? "—", tabular: true)
                                MonoText(value: resource.activeCount.map(String.init) ?? "—", tabular: true)
                                MonoText(value: Self.formatBytes(resource.sizeBytes), tabular: true)
                                MonoText(value: Self.formatBytes(resource.reclaimableBytes), tabular: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            }
        }
    }

    private static func formatBytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .file
        )
    }

}

private struct SystemLogsSection: View {
    let model: SystemModel
    @State private var isTailing = true
    @State private var jumpToLatestRequest = 0

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSMetrics.spacing12) {
            HStack {
                Label("Recent Service Logs", systemImage: "text.alignleft")
                    .font(.dsCardHeading)
                Spacer()
                Text("Last 15 minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch model.logsState {
            case .idle where model.logs.isEmpty,
                 .loading where model.logs.isEmpty:
                ProgressView("Loading recent logs…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .failed(let error) where model.logs.isEmpty:
                SystemUnavailableView(
                    title: "Service Logs Unavailable",
                    error: error,
                    model: model
                )
            default:
                if model.logs.isEmpty {
                    Text("No service log messages were found in the last 15 minutes.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Spacer()
                            LogJumpToLatestButton(
                                isAtLatest: isTailing,
                                action: jumpToLatest
                            )
                            .accessibilityIdentifier("system.logs.jumpToLatest")

                            LogCopyButton(
                                hasLogs: !model.logs.isEmpty,
                                action: copyLogs
                            )
                                .accessibilityIdentifier("system.logs.copy")
                        }
                        .controlSize(.small)
                        .padding(10)

                        Divider()

                        LogViewer(
                            snapshot: LogSnapshot(
                                text: model.logs,
                                firstLogicalLineNumber: 1
                            ),
                            jumpToLatestRequest: jumpToLatestRequest
                        ) { value in
                            Task { @MainActor in
                                isTailing = value
                            }
                        }
                    }
                    .frame(minHeight: 180, maxHeight: 360)
                }
            }
            }
        }
        .onChange(of: model.logsState) { _, state in
            guard state == .loaded, !model.logs.isEmpty else { return }
            jumpToLatest()
        }
    }

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.logs, forType: .string)
    }

    private func jumpToLatest() {
        jumpToLatestRequest &+= 1
        isTailing = true
    }
}

private struct SystemDiagnosticsSheet: View {
    let model: SystemModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diagnostics")
                    .font(.title2.bold())
                Spacer()
                Button(model.didCopyDiagnostics ? "Copied" : "Copy") {
                    model.copyDiagnostics()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(model.diagnosticsText)
                    .font(DSFont.mono(size: 12.5, relativeTo: .callout))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .accessibilityIdentifier("system.diagnosticsSheet")
    }
}

private struct SystemUnavailableView: View {
    let title: LocalizedStringResource
    let error: String
    let model: SystemModel

    var body: some View {
        EmptyState(title, systemImage: "exclamationmark.triangle", message: error) {
            Button("Try Again") {
                Task { await model.refresh() }
            }
        }
    }
}
