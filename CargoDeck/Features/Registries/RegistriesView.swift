import SwiftUI

struct RegistriesView: View {
    private static let columns: [DSTableColumn<RegistrySummary>] = [
        DSTableColumn("host", "Registry") {
            $0.host.localizedStandardCompare($1.host) == .orderedAscending
        },
    ]

    @Bindable var model: RegistryModel
    @State private var loginModel: RegistryLoginModel?
    @State private var pendingLogout: RegistrySummary?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Registries").font(.dsScreenTitle)
                Text("\(model.registries.count) logged in")
                    .foregroundStyle(Color.dsTextSecondary)
                Spacer()
            }
            .padding(DSMetrics.spacing16)
            .background(Color.dsSurface)

            DSTable(
                rows: model.filteredRegistries,
                columns: Self.columns,
                selection: $model.selectedRegistryID
            ) { registry in
                MonoText(value: registry.host, truncation: .middle, selectable: false)
                    .dsColumn(Self.columns[0])
                    .contextMenu {
                        Button("Log Out…", role: .destructive) { pendingLogout = registry }
                            .disabled(model.isBusy)
                    }
            }

            HStack {
                Text("Credentials are stored by the Apple Container CLI, not by this app.")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(Color.dsTextSecondary)
            .padding(.horizontal, DSMetrics.spacing12)
            .frame(minHeight: 34)
            .background(Color.dsSurfaceRaised)
            .overlay(alignment: .top) { Rectangle().fill(Color.dsHairline).frame(height: 1) }
        }
        .background(Color.dsCanvas)
        .accessibilityIdentifier("registries.table")
        .navigationTitle("Registries")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search registries")
        .toolbar {
            ToolbarItem {
                Button {
                    loginModel = RegistryLoginModel()
                } label: {
                    Label("Log In…", systemImage: "person.badge.key")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("registries.login")
            }
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.listState == .loading || model.isBusy)
                .accessibilityIdentifier("registries.refresh")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    pendingLogout = model.selectedRegistry
                } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(model.selectedRegistry == nil || model.isBusy)
                .accessibilityIdentifier("registries.logout")
            }
        }
        .overlay { overlay }
        .safeAreaInset(edge: .bottom) { banners }
        .task { await model.loadIfNeeded() }
        .sheet(item: $loginModel) { draft in
            RegistryLoginSheet(draft: draft, model: model)
        }
        .alert(
            "Log Out of Registry?",
            isPresented: Binding(
                get: { pendingLogout != nil },
                set: { if !$0 { pendingLogout = nil } }
            ),
            presenting: pendingLogout
        ) { registry in
            Button("Log Out", role: .destructive) {
                Task { await model.logout(host: registry.host) }
                pendingLogout = nil
            }
            .accessibilityIdentifier("registries.confirmLogout")
            Button("Cancel", role: .cancel) { pendingLogout = nil }
        } message: { registry in
            Text(
                "The stored credentials for “\(registry.host)” are removed. Pulling or pushing private images from it may fail until you log in again."
            )
        }
        .accessibilityIdentifier("registries.screen")
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.listState {
        case .idle where model.registries.isEmpty,
             .loading where model.registries.isEmpty:
            ProgressView("Loading registries…").controlSize(.large)
        case .failed(let message) where model.registries.isEmpty:
            EmptyState(
                "Registries Couldn’t Be Loaded",
                systemImage: "exclamationmark.triangle",
                message: message
            ) {
                Button("Try Again") { Task { await model.refresh() } }
            }
        case .loaded where model.filteredRegistries.isEmpty:
            if model.registries.isEmpty {
                EmptyState(
                    "No Registry Logins",
                    systemImage: "person.badge.key",
                    description: "Log in to pull or push private images."
                ) {
                    Button("Log In…") { loginModel = RegistryLoginModel() }
                }
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if let failure = model.mutationFailure {
                InlineBanner(
                    message: "Registry action failed",
                    detail: failure,
                    scope: .bar,
                    severity: .error,
                    copyValue: failure,
                    onDismiss: model.dismissMutationFailure
                )
                .accessibilityIdentifier("registries.mutationError")
            }
            if case .failed(let message) = model.listState, !model.registries.isEmpty {
                InlineBanner(
                    message: "Refresh failed",
                    detail: message,
                    scope: .bar,
                    severity: .error,
                    actionTitle: "Try Again",
                    action: { Task { await model.refresh() } }
                )
                .accessibilityIdentifier("registries.refreshError")
            }
        }
    }
}
