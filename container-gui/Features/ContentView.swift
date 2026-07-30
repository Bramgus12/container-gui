import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel())
    }

    init(model: AppModel) {
        _model = State(initialValue: model)
    }

    init(model: SetupModel) {
        _model = State(initialValue: AppModel(setup: model))
    }

    var body: some View {
        Group {
            if case .ready(let context) = model.setup.readiness {
                MainNavigationView(model: model, context: context)
            } else {
                SetupView(model: model.setup)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            await model.setup.checkIfNeeded()
        }
    }
}

private struct SetupView: View {
    let model: SetupModel
    @State private var isChoosingExecutable = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 32)

            Image(systemName: symbolName)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.largeTitle.bold())
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            stateDetails
                .frame(maxWidth: 620)

            actionButtons

            Spacer(minLength: 32)
        }
        .padding(40)
        .overlay(alignment: .topTrailing) {
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding()
                    .accessibilityLabel("Setup operation in progress")
            }
        }
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
                VStack(alignment: .leading, spacing: 10) {
                    Label("Expected location: /usr/local/bin/container", systemImage: "terminal")
                    if let customURL {
                        Text("The saved executable is no longer available at \(customURL.path).")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Link(
                        "Open Apple Container installation instructions",
                        destination: URL(string: "https://github.com/apple/container/releases/latest")!
                    )
                    .accessibilityIdentifier("setup.installationInstructions")
                }
            }

        case .unsupportedVersion(let detected, let supported, let url, _):
            detailCard {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Detected version", value: detected)
                    LabeledContent("Supported versions", value: supported.displayValue)
                    LabeledContent("Executable", value: url.path)
                }
                .textSelection(.enabled)
            }

        case .serviceStopped(let context):
            detailCard {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("CLI version", value: context.versions.cli?.version ?? "Unknown")
                    LabeledContent("Executable", value: context.executableURL.path)
                    if let serviceMessage = context.status.message, !serviceMessage.isEmpty {
                        Text(serviceMessage)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }

        case .failure(let executableURL, let diagnostic):
            detailCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(diagnostic.summary)
                    if let executableURL {
                        LabeledContent("Executable", value: executableURL.path)
                    }
                    if let exitCode = diagnostic.exitCode {
                        LabeledContent("Exit code", value: String(exitCode))
                    }
                    if let standardError = diagnostic.standardError, !standardError.isEmpty {
                        DisclosureGroup("Standard error") {
                            ScrollView {
                                Text(standardError)
                                    .font(.system(.callout, design: .monospaced))
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
                Button("Start Service") {
                    Task { await model.startService() }
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
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var title: String {
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

    private var message: String {
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
        case .checking: .accentColor
        case .serviceStopped: .orange
        case .ready: .green
        case .missingCLI: .accentColor
        case .unsupportedPlatform, .unsupportedVersion, .failure: .red
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

    private func platformIssueText(_ issue: PlatformIssue) -> String {
        switch issue {
        case .requiresAppleSilicon(let architecture):
            "Detected architecture: \(architecture). An Apple silicon Mac is required."
        case .requiresMacOS(let minimum, let detected):
            "Detected macOS \(detected.major).\(detected.minor).\(detected.patch). macOS \(minimum) or later is required."
        }
    }
}

private struct MainNavigationView: View {
    @Bindable var model: AppModel
    let context: PreflightContext

    var body: some View {
        NavigationSplitView {
            List(AppDestination.allCases, selection: $model.destination) { destination in
                Label(destination.rawValue, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("Container GUI")
        } detail: {
            switch model.destination {
            case .containers:
                ContainerListView(model: model)
            case .images:
                ImageListView(model: model)
            case .system:
                SystemView(model: model.makeSystemModel(context: context))
            case .settings:
                placeholder
            case nil:
                ContentUnavailableView(
                    "Select a Section",
                    systemImage: "sidebar.left"
                )
            }
        }
        .task(id: context.executableURL) {
            await model.activate(context)
        }
        .accessibilityIdentifier("main.navigation")
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label(
                model.destination?.rawValue ?? "Container GUI",
                systemImage: model.destination?.systemImage ?? "shippingbox"
            )
        } description: {
            Text("Apple Container \(context.versions.cli?.version ?? "") is ready.")
        }
    }
}

private struct ContainerListView: View {
    @Bindable var model: AppModel
    @State private var pendingDeletion: PendingContainerDeletion?
    @State private var runContainerModel: RunContainerModel?

    var body: some View {
        table
            .navigationTitle("Containers")
            .searchable(
                text: $model.searchText,
                placement: .toolbar,
                prompt: "Search containers"
            )
            .toolbar {
                ToolbarItem {
                    Picker("State", selection: $model.containerFilter) {
                        ForEach(ContainerFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                ToolbarItem {
                    Button {
                        runContainerModel = RunContainerModel()
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
                    Text("This immediately stops and permanently deletes “\(deletion.containerID)”. This action cannot be undone.")
                } else {
                    Text("This permanently deletes “\(deletion.containerID)”. This action cannot be undone.")
                }
            }
            .sheet(item: $runContainerModel) { runModel in
                RunContainerSheet(model: runModel, appModel: model)
            }
            .inspector(
                isPresented: Binding(
                    get: { model.selectedContainerID != nil },
                    set: { if !$0 { model.selectedContainerID = nil } }
                )
            ) {
                if let containerID = model.selectedContainerID {
                    ContainerDetailHost(appModel: model, containerID: containerID)
                        .id(containerID)
                        .inspectorColumnWidth(min: 360, ideal: 440, max: 620)
                }
            }
    }

    private var table: some View {
        Table(model.filteredContainers, selection: $model.selectedContainerID) {
            TableColumn("ID / Name", value: \.id)
            TableColumn("Image") { container in
                Text(container.image ?? "—")
            }
            TableColumn("State") { container in
                if let mutation = model.mutationInProgress(for: container.id) {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(mutation.displayName)…")
                    }
                } else {
                    Label(container.state.displayName, systemImage: container.state.systemImage)
                        .foregroundStyle(container.state.tint)
                }
            }
            TableColumn("Architecture") { container in
                Text(container.architecture ?? "—")
            }
            TableColumn("Address") { container in
                Text(container.address ?? "—")
            }
            TableColumn("Created") { container in
                if let createdAt = container.createdAt {
                    Text(
                        createdAt,
                        format: .dateTime
                            .year()
                            .month(.abbreviated)
                            .day()
                            .hour()
                            .minute()
                    )
                } else {
                    Text("—")
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let container = model.containers.first(where: { selection.contains($0.id) }) {
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
                    pendingDeletion = PendingContainerDeletion(
                        containerID: container.id,
                        mutation: .delete(force: false)
                    )
                }
                .disabled(!model.canPerform(.delete(force: false), on: container))

                Button("Force Delete…", role: .destructive) {
                    pendingDeletion = PendingContainerDeletion(
                        containerID: container.id,
                        mutation: .delete(force: true)
                    )
                }
                .disabled(!model.canPerform(.delete(force: true), on: container))
            }
        }
        .accessibilityIdentifier("containers.table")
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.containerListState {
        case .idle where model.containers.isEmpty,
             .loading where model.containers.isEmpty:
            ProgressView("Loading containers…")
                .controlSize(.large)

        case .failed(let message) where model.containers.isEmpty:
            ContentUnavailableView {
                Label("Containers Couldn’t Be Loaded", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    .textSelection(.enabled)
            } actions: {
                Button("Try Again") {
                    Task { await model.refreshContainers() }
                }
                .keyboardShortcut(.defaultAction)
            }

        case .loaded where model.filteredContainers.isEmpty:
            if model.containers.isEmpty {
                ContentUnavailableView(
                    "No Containers",
                    systemImage: "shippingbox",
                    description: Text("Containers you create will appear here.")
                )
            } else if model.searchText.isEmpty {
                ContentUnavailableView(
                    "No \(model.containerFilter.rawValue) Containers",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Choose another state filter to see more containers.")
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
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .lineLimit(2)
                Spacer()
                Button("Try Again") {
                    Task { await model.refreshContainers() }
                }
            }
            .padding(10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var mutationErrorBanner: some View {
        if let failure = model.mutationFailure {
            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(failure.mutation.displayName) failed for \(failure.containerID)")
                            .fontWeight(.semibold)
                        Text(failure.message)
                            .textSelection(.enabled)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                Spacer()
                Button("Dismiss") {
                    model.dismissMutationFailure()
                }
            }
            .padding(10)
            .background(.bar)
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
        pendingDeletion = PendingContainerDeletion(
            containerID: selectedContainer.id,
            mutation: .delete(force: force)
        )
    }
}

private struct PendingContainerDeletion: Equatable {
    let containerID: String
    let mutation: ContainerMutation
}

extension ContainerState {
    var displayName: String {
        switch self {
        case .created: "Created"
        case .running: "Running"
        case .stopped: "Stopped"
        case .paused: "Paused"
        case .unknown(let value): value.capitalized
        }
    }

    var systemImage: String {
        switch self {
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .created: "circle.dotted"
        case .stopped: "stop.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .paused: .orange
        case .created, .stopped, .unknown: .secondary
        }
    }
}

#Preview("Missing CLI") {
    ContentView()
}
