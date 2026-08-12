import AppKit
import SwiftUI

struct SystemView: View {
    @Bindable var model: SystemModel
    let builder: BuilderModel?
    let updates: UpdateModel
    @State private var confirmsStop = false
    @State private var showsDiagnostics = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                SystemHealthSection(model: model, confirmsStop: $confirmsStop)
                if let builder {
                    SystemBuilderSection(model: builder)
                }
                SystemDiskUsageSection(model: model)
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
                HStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") {
                        model.dismissActionError()
                    }
                }
                .padding(10)
                .background(.bar)
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

}

private struct SystemBuilderSection: View {
    let model: BuilderModel
    @State private var cpuLimit = ""
    @State private var memoryLimit = ""
    @State private var confirmsDelete = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Image Builder", systemImage: "hammer")
                        .font(.headline)
                    Spacer()
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
                Divider()
                switch model.loadingState {
                case .idle, .loading:
                    ProgressView("Loading builder status…")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Try Again") { Task { await model.refresh() } }
                case .loaded:
                    BuilderStatusGrid(status: model.status)
                    if model.status.state == .absent {
                        Divider()
                        HStack {
                            TextField("CPUs (optional)", text: $cpuLimit).frame(width: 150)
                            TextField("Memory (optional, e.g. 4G)", text: $memoryLimit)
                                .frame(width: 230)
                        }
                    }
                }
                if let error = model.actionError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { model.dismissActionError() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Delete Image Builder?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stopped builder container will be permanently deleted. A future image build can create it again.")
        }
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct BuilderStatusGrid: View {
    let status: BuilderStatus

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Label(statusLabel, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
            }
            if let id = status.id {
                GridRow {
                    Text("ID").foregroundStyle(.secondary)
                    Text(id).textSelection(.enabled)
                }
            }
            if let image = status.image {
                GridRow {
                    Text("Image").foregroundStyle(.secondary)
                    Text(image).textSelection(.enabled)
                }
            }
            if let address = status.address {
                GridRow {
                    Text("Address").foregroundStyle(.secondary)
                    Text(address).textSelection(.enabled)
                }
            }
        }
    }

    private var statusLabel: LocalizedStringResource {
        switch status.state {
        case .absent: "Not created"
        case .running: "Running"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        }
    }

    private var statusIcon: String {
        switch status.state {
        case .absent: "minus.circle"
        case .running: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch status.state {
        case .running: .green
        case .stopped: .orange
        case .absent, .unknown: .secondary
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

private struct SystemHealthSection: View {
    let model: SystemModel
    @Binding var confirmsStop: Bool

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Text("Service")
                        .foregroundStyle(.secondary)
                    if model.status.isRunning {
                        Label("Running", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Stopped", systemImage: "stop.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                GridRow {
                    Text("CLI version").foregroundStyle(.secondary)
                    Text(model.versions.cli?.version ?? "Unavailable")
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Server version").foregroundStyle(.secondary)
                    Text(model.versions.server?.version ?? model.status.version ?? "Unavailable")
                        .textSelection(.enabled)
                }
                if let message = model.status.message, !message.isEmpty {
                    GridRow {
                        Text("Message").foregroundStyle(.secondary)
                        Text(message).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Label("Service Health", systemImage: "heart.text.square")
                    .font(.headline)
                Spacer()
                if let operation = model.serviceOperation {
                    ProgressView(operation.localizedDescription)
                        .controlSize(.small)
                } else if model.status.isRunning {
                    Button("Stop Service…", role: .destructive) {
                        confirmsStop = true
                    }
                    .accessibilityIdentifier("system.stop")
                } else {
                    Button("Start Service") {
                        Task { await model.perform(.start) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("system.start")
                }
            }
        }
    }
}

private struct SystemDiskUsageSection: View {
    let model: SystemModel

    var body: some View {
        GroupBox {
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
                                Text(resource.totalCount.map(String.init) ?? "—")
                                Text(resource.activeCount.map(String.init) ?? "—")
                                Text(Self.formatBytes(resource.sizeBytes))
                                Text(Self.formatBytes(resource.reclaimableBytes))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            Label("Disk Usage", systemImage: "internaldrive")
                .font(.headline)
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
        GroupBox {
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
        } label: {
            HStack {
                Label("Recent Service Logs", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Text("Last 15 minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .font(.system(.callout, design: .monospaced))
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
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(error).textSelection(.enabled)
        } actions: {
            Button("Try Again") {
                Task { await model.refresh() }
            }
        }
    }
}
