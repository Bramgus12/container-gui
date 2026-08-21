import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @State private var model: AppModel
    @State private var updates: UpdateModel

    init() {
        _model = State(initialValue: AppModel())
        _updates = State(initialValue: AppDependencies.makeUpdateModel())
    }

    init(model: AppModel, updates: UpdateModel? = nil) {
        _model = State(initialValue: model)
        _updates = State(initialValue: updates ?? AppDependencies.makeUpdateModel())
    }

    init(model: SetupModel) {
        _model = State(initialValue: AppModel(setup: model))
        _updates = State(initialValue: AppDependencies.makeUpdateModel())
    }

    var body: some View {
        Group {
            if case .ready(let context) = model.setup.readiness {
                MainNavigationView(model: model, updates: updates, context: context)
            } else {
                SetupView(model: model.setup)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            await model.setup.checkIfNeeded()
        }
        .task {
            await updates.checkIfNeeded()
        }
        .sheet(isPresented: Binding(
            get: { updates.pendingManualResult != nil },
            set: { isPresented in
                if !isPresented { updates.dismissManualResult() }
            }
        )) {
            if let result = updates.pendingManualResult {
                UpdateResultSheet(model: updates, result: result)
            }
        }
    }
}

private struct SetupView: View {
    private static let installationInstructionsURL = URL(
        string: "https://github.com/apple/container/releases/latest"
    )

    let model: SetupModel
    @State private var isChoosingExecutable = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 32)

            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Image(systemName: symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .background(Circle().fill(Color.dsSurface).frame(width: 24, height: 24))
                    .offset(x: 6, y: 4)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.dsDisplay)
                    .tracking(-0.56)
                Text(message)
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            stateDetails
                .frame(maxWidth: 620)

            actionButtons

            Spacer(minLength: 32)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsCanvas)
        .fileImporter(
            isPresented: $isChoosingExecutable,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                await model.chooseExecutable(url)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var stateDetails: some View {
        switch model.readiness {
        case .checking:
            ProgressView("Checking Apple Container…")
                .controlSize(.large)

        case .unsupportedPlatform(let issue):
            detailCard {
                Label(platformIssueText(issue), systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            }

        case .missingCLI(let customURL):
            detailCard {
                VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
                    SectionLabel(title: "Looked in")
                    setupRow(
                        "Documented path",
                        value: PreflightService.documentedExecutableURL.path
                    )
                    setupRow(
                        "Homebrew path",
                        value: PreflightService.homebrewExecutableURL.path
                    )
                    if let customURL {
                        SectionLabel(title: "Saved path is gone")
                        setupRow("Executable", value: customURL.path)
                    }
                    if let installationInstructionsURL = Self.installationInstructionsURL {
                        Link(
                            "Open Apple Container installation instructions",
                            destination: installationInstructionsURL
                        )
                        .accessibilityIdentifier("setup.installationInstructions")
                    }
                }
            }

        case .unsupportedVersion(let detected, let supported, let url, _):
            detailCard {
                VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
                    setupRow("Detected version", value: detected)
                    setupRow("Supported versions", value: supported.displayValue)
                    setupRow("Executable", value: url.path)
                }
            }

        case .serviceStopped(let context):
            detailCard {
                VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
                    setupRow("CLI version", value: context.versions.cli?.version ?? "Unknown")
                    setupRow("Executable", value: context.executableURL.path)
                    setupRow("Will run", value: "container system start")
                    if let serviceMessage = context.status.message, !serviceMessage.isEmpty {
                        Text(serviceMessage)
                            .font(.caption)
                            .foregroundStyle(Color.dsTextSecondary)
                            .textSelection(.enabled)
                    }
                }
            }

        case .failure(let executableURL, let diagnostic):
            detailCard {
                VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
                    Text(diagnostic.summary)
                    if let executableURL {
                        setupRow("Executable", value: executableURL.path)
                    }
                    if let exitCode = diagnostic.exitCode {
                        setupRow("Exit code", value: String(exitCode))
                    }
                    if let standardError = diagnostic.standardError, !standardError.isEmpty {
                        DisclosureGroup("Standard error") {
                            ScrollView {
                                Text(standardError)
                                    .font(DSFont.mono(size: 12.5, relativeTo: .callout))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 120)
                        }
                    }
                }
                .textSelection(.enabled)
            }

        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            switch model.readiness {
            case .checking, .unsupportedPlatform, .ready:
                EmptyView()

            case .missingCLI(let customURL):
                Button("Choose Executable…") {
                    isChoosingExecutable = true
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup.chooseExecutable")

                Button("Retry") {
                    Task { await model.retry() }
                }
                .accessibilityIdentifier("setup.retry")

                if customURL != nil {
                    Button("Forget Saved Path") {
                        Task { await model.resetCustomExecutable() }
                    }
                    .accessibilityIdentifier("setup.resetExecutable")
                }

            case .unsupportedVersion:
                Button("Choose Executable…") {
                    isChoosingExecutable = true
                }
                .accessibilityIdentifier("setup.chooseExecutable")
                Button("Retry") {
                    Task { await model.retry() }
                }
                .accessibilityIdentifier("setup.retry")

            case .serviceStopped:
                Button {
                    Task { await model.startService() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Starting Container service")
                        }
                        Text("Start Service")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
                .accessibilityIdentifier("setup.startService")

                Button("Retry") {
                    Task { await model.retry() }
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("setup.retry")

            case .failure:
                Button(model.didCopyDiagnostics ? "Copied" : "Copy Diagnostics") {
                    model.copyDiagnostics()
                }
                .accessibilityIdentifier("setup.copyDiagnostics")

                Button("Choose Executable…") {
                    isChoosingExecutable = true
                }
                .accessibilityIdentifier("setup.chooseExecutable")

                Button("Retry") {
                    Task { await model.retry() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup.retry")
            }
        }
        .disabled(model.isWorking)
    }

    private func detailCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        DSCard {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: LocalizedStringResource {
        switch model.readiness {
        case .checking: "Getting things ready"
        case .unsupportedPlatform: "This Mac isn’t supported"
        case .missingCLI: "Install Apple Container"
        case .unsupportedVersion: "Unsupported CLI version"
        case .serviceStopped: "Start the Container service"
        case .failure: "Setup couldn’t finish"
        case .ready: "Ready"
        }
    }

    private var message: LocalizedStringResource {
        switch model.readiness {
        case .checking:
            "Verifying your Mac, the container executable, and its service."
        case .unsupportedPlatform:
            "Container GUI requires Apple silicon and a supported version of macOS."
        case .missingCLI:
            "Install Apple Container, or choose an existing container executable."
        case .unsupportedVersion:
            "Choose a compatible executable before continuing."
        case .serviceStopped:
            "The CLI is valid, but its background service is not running."
        case .failure:
            "Review the diagnostic below, then retry or choose another executable."
        case .ready:
            ""
        }
    }

    private var symbolName: String {
        switch model.readiness {
        case .checking: "shippingbox"
        case .serviceStopped: "pause.circle"
        case .missingCLI: "arrow.down.app"
        case .ready: "checkmark.circle"
        case .unsupportedPlatform, .unsupportedVersion, .failure: "exclamationmark.triangle"
        }
    }

    private var symbolColor: Color {
        switch model.readiness {
        case .checking, .missingCLI: .dsBlue400
        case .serviceStopped: .dsStateAttention
        case .ready: .dsStateRunning
        case .unsupportedPlatform, .unsupportedVersion, .failure: .dsStateDestructive
        }
    }

    /// A setup detail row: our label, the CLI's value in mono.
    private func setupRow(_ label: LocalizedStringResource, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(Color.dsTextSecondary)
            Spacer(minLength: DSMetrics.spacing12)
            MonoText(value: value, truncation: .middle)
        }
    }

    private var accessibilityIdentifier: String {
        switch model.readiness {
        case .checking: "setup.checking"
        case .unsupportedPlatform: "setup.unsupportedPlatform"
        case .missingCLI: "setup.missing"
        case .unsupportedVersion: "setup.unsupportedVersion"
        case .serviceStopped: "setup.stopped"
        case .failure: "setup.failed"
        case .ready: "setup.ready"
        }
    }

    private func platformIssueText(_ issue: PlatformIssue) -> LocalizedStringResource {
        switch issue {
        case .requiresAppleSilicon(let architecture):
            "Detected architecture: \(architecture). An Apple silicon Mac is required."
        case .requiresMacOS(let minimum, let detected):
            """
            Detected macOS \(detected.major).\(detected.minor).\(detected.patch). \
            macOS \(minimum) or later is required.
            """
        }
    }
}

private struct MainNavigationView: View {
    @Bindable var model: AppModel
    let updates: UpdateModel
    let context: PreflightContext
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SidebarHeader(
                    isRunning: model.systemModel?.status.isRunning ?? context.status.isRunning,
                    version: model.systemModel?.versions.cli?.version
                        ?? context.versions.cli?.version
                        ?? "—"
                )
                List(AppDestination.allCases, selection: $model.destination) { destination in
                    SidebarRow(
                        icon: destination.systemImage,
                        title: destination.title,
                        count: model.inventoryCount(for: destination),
                        showsAttention: destination == .system && model.systemNeedsAttention
                    )
                    .tag(destination)
                    .accessibilityIdentifier("destination.\(destination.rawValue.lowercased())")
                }
                .listStyle(.sidebar)
                SidebarActivityBlock(
                    poller: model.statsPoller,
                    diskUsage: model.systemModel?.diskUsage
                ) {
                    model.destination = .system
                }
            }
        } detail: {
            switch model.destination {
            case .containers:
                ContainerListView(model: model)
            case .images:
                ImageListView(model: model)
            case .volumes:
                if let volumeModel = model.volumeModel {
                    VolumesView(model: volumeModel, inventoryIndex: model.inventoryIndex)
                        .onChange(of: volumeModel.volumes) { _, _ in
                            model.refreshInventoryIndex()
                        }
                } else {
                    ProgressView("Loading volumes…")
                }
            case .networks:
                if let networkModel = model.networkModel {
                    NetworksView(model: networkModel, inventoryIndex: model.inventoryIndex)
                        .onChange(of: networkModel.networks) { _, _ in
                            model.refreshInventoryIndex()
                        }
                } else {
                    ProgressView("Loading networks…")
                }
            case .system:
                SystemView(
                    model: model.makeSystemModel(context: context),
                    builder: model.builderModel,
                    dns: model.dnsModel,
                    updates: updates
                )
            case nil:
                EmptyState("Select a Section", systemImage: "sidebar.left")
            }
        }
        .task(id: context.executableURL) {
            await model.activate(context)
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await model.refreshSidebarData()
            }
        }
        .onAppear { model.statsPoller?.setActive(controlActiveState != .inactive) }
        .onChange(of: controlActiveState) { _, state in
            model.statsPoller?.setActive(state != .inactive)
        }
        .onDisappear { model.statsPoller?.setActive(false) }
        .accessibilityIdentifier("main.navigation")
    }
}

private struct SidebarHeader: View {
    let isRunning: Bool
    let version: String

    var body: some View {
        HStack(spacing: DSMetrics.spacing12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                Text("Container GUI").font(.dsCardHeading)
                StateDot(
                    isRunning ? .running : .attention,
                    label: isRunning ? "Service up · \(version)" : "Service stopped · \(version)",
                    accessibilityLabel: isRunning ? "Service running, version \(version)" : "Service stopped, version \(version)"
                )
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DSMetrics.spacing12)
        .padding(.bottom, DSMetrics.spacing12)
        // Clears the window controls, which now sit over the sidebar. No
        // background of its own: the header sits on the sidebar's material.
        .padding(.top, 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
        }
    }
}

/// The sidebar's glance layer: what the containers are using right now, and how
/// much disk the installation is holding. Live figures come first — disk only
/// changes when you pull or prune, so it sits underneath as one line.
private struct SidebarActivityBlock: View {
    let poller: ContainerStatsPoller?
    let diskUsage: SystemDiskUsage?
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing8) {
            HStack {
                SectionLabel(title: "Activity")
                Spacer()
                if let count = poller?.reportingContainerCount, count > 0 {
                    Text("\(count) running")
                        .font(.caption)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }

            metric(
                "Memory",
                value: poller.map { StackedUsageBar.format($0.totalMemoryBytes) },
                fraction: poller?.memoryFraction,
                tint: .dsBlue400
            )
            metric(
                "CPU",
                value: cpuDescription,
                fraction: poller?.totalCPUCores.map { min(1, $0) },
                tint: .dsBlue300
            )

            Divider()

            HStack {
                Text("Disk")
                Spacer()
                Text(diskUsage.map { StackedUsageBar.format($0.totalSizeBytes) } ?? "—")
                    .font(.cliMonoTabular)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(Color.dsTextSecondary)

            Button("Review housekeeping", action: review)
                .buttonStyle(.link)
        }
        .padding(DSMetrics.spacing12)
        .background(Color.dsSurfaceRaised, in: RoundedRectangle(cornerRadius: DSMetrics.inlineRadius))
        .padding(DSMetrics.spacing8)
        .accessibilityIdentifier("sidebar.activity")
    }

    /// Nil until the poller has two samples to derive a rate from.
    private var cpuDescription: String? {
        guard let cores = poller?.totalCPUCores else { return nil }
        return (cores * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private func metric(
        _ title: LocalizedStringResource,
        value: String?,
        fraction: Double?,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
            HStack {
                Text(title)
                Spacer()
                Text(value ?? "—")
                    .font(.cliMonoTabular)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(Color.dsTextSecondary)
            UsageBar(value: fraction ?? 0, tint: tint)
        }
    }
}

private struct ContainerListView: View {
    @Bindable var model: AppModel
    @State private var pendingDeletion: PendingContainerDeletion?
    @State private var runContainerModel: RunContainerModel?

    var body: some View {
        VStack(spacing: 0) {
            ContainerScreenHeader(
                runningCount: model.containers.count { $0.state == .running },
                totalCount: model.containers.count,
                filter: $model.containerFilter
            )
            table
            ContainerListFooter(lastRefresh: model.lastContainerRefresh)
        }
            .background(Color.dsCanvas)
            .navigationTitle("Containers")
            .searchable(
                text: $model.searchText,
                placement: .toolbar,
                prompt: "Search containers"
            )
            .toolbar {
                ToolbarItem {
                    Button {
                        runContainerModel = RunContainerModel(
                            networkModel: model.networkModel,
                            volumeModel: model.volumeModel
                        )
                    } label: {
                        Label("Run Container", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier("containers.run")
                }

                ToolbarItem {
                    Button {
                        Task { await model.refreshContainers() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.containerListState == .loading)
                    .accessibilityIdentifier("containers.refresh")
                }

                ToolbarItemGroup {
                    Button {
                        perform(.start)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(!canPerform(.start))
                    .accessibilityIdentifier("containers.start")

                    Button {
                        perform(.stop)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!canPerform(.stop))
                    .accessibilityIdentifier("containers.stop")

                    Menu {
                        Button("Delete…", role: .destructive) {
                            requestDeletion(force: false)
                        }
                        .disabled(!canPerform(.delete(force: false)))

                        Button("Force Delete…", role: .destructive) {
                            requestDeletion(force: true)
                        }
                        .disabled(!canPerform(.delete(force: true)))
                    } label: {
                        Label("More Actions", systemImage: "ellipsis.circle")
                    }
                    .disabled(selectedContainer == nil || selectedContainerIsBusy)
                    .accessibilityIdentifier("containers.moreActions")
                }
            }
            .overlay {
                overlay
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    mutationErrorBanner
                    refreshErrorBanner
                }
            }
            .alert(
                pendingDeletion?.mutation == .delete(force: true)
                    ? "Force Delete Container?"
                    : "Delete Container?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { deletion in
                Button(deletion.mutation.displayName, role: .destructive) {
                    Task {
                        await model.perform(deletion.mutation, on: deletion.containerID)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { deletion in
                if deletion.mutation == .delete(force: true) {
                    Text(
                        """
                        This immediately stops and permanently deletes “\(deletion.containerID)”. \
                        This action cannot be undone.
                        """
                    )
                } else {
                    Text("This permanently deletes “\(deletion.containerID)”. This action cannot be undone.")
                }
            }
            .sheet(item: $runContainerModel) { runModel in
                RunContainerSheet(
                    model: runModel,
                    appModel: model,
                    networkModel: model.networkModel,
                    volumeModel: model.volumeModel
                )
            }
            .inspector(isPresented: $model.isContainerInspectorPresented) {
                if let containerID = model.selectedContainerID {
                    ContainerDetailHost(appModel: model, containerID: containerID)
                        .id(containerID)
                        .inspectorColumnWidth(min: 420, ideal: 560, max: 820)
                }
            }
    }

    private static let columns: [DSTableColumn<ContainerSummary>] = [
        DSTableColumn("container", "Container") {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        },
        DSTableColumn("image", "Image") {
            ($0.image ?? "").localizedStandardCompare($1.image ?? "") == .orderedAscending
        },
        DSTableColumn("ports", "Ports", width: 150),
        DSTableColumn("memory", "Memory", width: 150),
        DSTableColumn("uptime", "Uptime", width: 110, alignment: .trailing) {
            // Most recently started first, and containers that never started last.
            ($0.startedAt ?? $0.createdAt ?? .distantPast)
                > ($1.startedAt ?? $1.createdAt ?? .distantPast)
        },
    ]

    private var table: some View {
        DSTable(
            rows: model.filteredContainers,
            columns: Self.columns,
            selection: $model.selectedContainerID
        ) { container in
            // The state is the dot and the dimming, not a word — the word is
            // carried by the accessibility label and by the mutation cell.
            HStack(spacing: DSMetrics.spacing8) {
                StateDot(
                    container.state.designState,
                    accessibilityLabel: container.state.localizedTitle
                )
                MonoText(value: container.id, truncation: .middle, selectable: false)
            }
            .opacity(container.state == .running ? 1 : 0.68)
            .dsColumn(Self.columns[0])

            MonoText(value: container.image ?? "—", dimmed: true, truncation: .middle, selectable: false)
                .opacity(container.state == .running ? 1 : 0.68)
                .dsColumn(Self.columns[1])

            MonoText(value: container.portSummary, dimmed: true, truncation: .middle, selectable: false)
                .dsColumn(Self.columns[2])

            memoryCell(for: container)
                .dsColumn(Self.columns[3])

            MonoText(
                value: RelativeUptimeFormatter().string(for: container),
                dimmed: true,
                tabular: true,
                selectable: false
            )
            .dsColumn(Self.columns[4])
            .contextMenu { rowMenu(for: container) }
        }
        .accessibilityIdentifier("containers.table")
    }

    @ViewBuilder
    private func memoryCell(for container: ContainerSummary) -> some View {
        if let mutation = model.mutationInProgress(for: container.id) {
            HStack(spacing: DSMetrics.spacing8) {
                ProgressView().controlSize(.small)
                Text("\(mutation.displayName)…")
                    .foregroundStyle(Color.dsStateAttention)
            }
        } else if container.state == .paused {
            Text(container.state.localizedTitle)
                .foregroundStyle(Color.dsStateAttention)
        } else if let stats = model.statsPoller?.statsByContainerID[container.id],
                  let usage = stats.memoryUsageBytes {
            HStack(spacing: DSMetrics.spacing8) {
                UsageBar(value: Self.memoryFraction(stats)).frame(width: 48)
                MonoText(value: Self.formatBytes(usage), dimmed: true, tabular: true, selectable: false)
            }
        } else {
            MonoText(value: "—", dimmed: true, selectable: false)
        }
    }

    @ViewBuilder
    private func rowMenu(for container: ContainerSummary) -> some View {
        Button("Start") {
            Task { await model.perform(.start, on: container.id) }
        }
        .disabled(!model.canPerform(.start, on: container))

        Button("Stop") {
            Task { await model.perform(.stop, on: container.id) }
        }
        .disabled(!model.canPerform(.stop, on: container))

        Divider()

        Button("Delete…", role: .destructive) {
            requestDeletion(of: container, force: false)
        }
        .disabled(!model.canPerform(.delete(force: false), on: container))

        Button("Force Delete…", role: .destructive) {
            requestDeletion(of: container, force: true)
        }
        .disabled(!model.canPerform(.delete(force: true), on: container))
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.containerListState {
        case .idle where model.containers.isEmpty,
             .loading where model.containers.isEmpty:
            ProgressView("Loading containers…")
                .controlSize(.large)

        case .failed(let message) where model.containers.isEmpty:
            EmptyState(
                "Containers Couldn’t Be Loaded",
                systemImage: "exclamationmark.triangle",
                message: message
            ) {
                Button("Try Again") {
                    Task { await model.refreshContainers() }
                }
                .keyboardShortcut(.defaultAction)
            }

        case .loaded where model.filteredContainers.isEmpty:
            if model.containers.isEmpty {
                EmptyState(
                    "No Containers",
                    systemImage: "shippingbox",
                    description: "Containers you create will appear here."
                )
            } else if model.searchText.isEmpty {
                EmptyState(
                    "No \(model.containerFilter.rawValue) Containers",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: "Choose another state filter to see more containers."
                )
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var refreshErrorBanner: some View {
        if case .failed(let message) = model.containerListState,
           !model.containers.isEmpty {
            InlineBanner(
                message: "Refresh failed",
                detail: message,
                scope: .bar,
                severity: .error,
                actionTitle: "Try Again",
                action: { Task { await model.refreshContainers() } }
            )
        }
    }

    @ViewBuilder
    private var mutationErrorBanner: some View {
        if let failure = model.mutationFailure {
            InlineBanner(
                message: mutationFailureTitle(failure),
                detail: failure.invocation ?? failure.message,
                scope: .bar,
                severity: .error,
                copyValue: failure.invocation ?? failure.message,
                onDismiss: model.dismissMutationFailure
            )
            .accessibilityIdentifier("containers.mutationError")
        }
    }

    private var selectedContainer: ContainerSummary? {
        guard let id = model.selectedContainerID else { return nil }
        return model.containers.first { $0.id == id }
    }

    private var selectedContainerIsBusy: Bool {
        guard let selectedContainer else { return false }
        return model.mutationInProgress(for: selectedContainer.id) != nil
    }

    private func canPerform(_ mutation: ContainerMutation) -> Bool {
        guard let selectedContainer else { return false }
        return model.canPerform(mutation, on: selectedContainer)
    }

    private func perform(_ mutation: ContainerMutation) {
        guard let selectedContainer else { return }
        Task { await model.perform(mutation, on: selectedContainer.id) }
    }

    private func requestDeletion(force: Bool) {
        guard let selectedContainer else { return }
        requestDeletion(of: selectedContainer, force: force)
    }

    private func requestDeletion(of container: ContainerSummary, force: Bool) {
        pendingDeletion = PendingContainerDeletion(
            containerID: container.id,
            mutation: .delete(force: force)
        )
    }

    private func mutationFailureTitle(
        _ failure: ContainerMutationFailure
    ) -> LocalizedStringResource {
        if let exitCode = failure.exitCode {
            return "\(failure.mutation.displayName) failed for \(failure.containerID) (exit \(exitCode))"
        }
        return "\(failure.mutation.displayName) failed for \(failure.containerID)"
    }

    private static func memoryFraction(_ stats: ContainerStats) -> Double {
        guard let usage = stats.memoryUsageBytes,
              let limit = stats.memoryLimitBytes,
              limit > 0 else { return 0 }
        return Double(usage) / Double(limit)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}

private struct ContainerScreenHeader: View {
    let runningCount: Int
    let totalCount: Int
    @Binding var filter: ContainerFilter

    var body: some View {
        HStack(spacing: DSMetrics.spacing16) {
            VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                Text("Containers").font(.dsScreenTitle)
                Text("\(runningCount) of \(totalCount) running")
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Spacer()
            Picker("State", selection: $filter) {
                ForEach(ContainerFilter.allCases) { value in Text(value.title).tag(value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(DSMetrics.spacing16)
        .frame(maxWidth: .infinity)
        .background(Color.dsSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
        }
    }
}

private struct ContainerListFooter: View {
    let lastRefresh: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: DSMetrics.spacing8) {
                Text(lastRefresh.map { "refreshed \(Self.age(from: $0, now: context.date))" } ?? "not refreshed")
                Text("·").foregroundStyle(Color.dsTextTertiary)
                MonoText(value: "container ls --all", dimmed: true)
                Spacer()
                Text("⌘R refresh  ·  ⌘N run")
            }
            .font(.caption)
            .foregroundStyle(Color.dsTextSecondary)
            .padding(.horizontal, DSMetrics.spacing12)
            .frame(minHeight: 32)
            .background(Color.dsSurfaceRaised)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.dsHairline).frame(height: DSMetrics.hairline)
            }
        }
    }

    private static func age(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

private struct PendingContainerDeletion: Equatable {
    let containerID: String
    let mutation: ContainerMutation
}

#Preview("Missing CLI") {
    ContentView()
}
