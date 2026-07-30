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
            case .images, .system, .settings:
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
                        Task { await model.refreshContainers() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.containerListState == .loading)
                    .accessibilityIdentifier("containers.refresh")
                }
            }
            .overlay {
                overlay
            }
            .safeAreaInset(edge: .bottom) {
                refreshErrorBanner
            }
    }

    private var table: some View {
        Table(model.filteredContainers, selection: $model.selectedContainerID) {
            TableColumn("ID / Name", value: \.id)
            TableColumn("Image") { container in
                Text(container.image ?? "—")
            }
            TableColumn("State") { container in
                Label(container.state.displayName, systemImage: container.state.systemImage)
                    .foregroundStyle(container.state.tint)
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
}

private extension ContainerState {
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
