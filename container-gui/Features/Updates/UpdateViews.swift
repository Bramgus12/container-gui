import AppKit
import SwiftUI

struct UpdateSection: View {
    let model: UpdateModel

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSMetrics.spacing12) {
            HStack {
                Label("Updates", systemImage: "arrow.down.circle")
                    .font(.dsCardHeading)
                Spacer()
                if model.isChecking {
                    ProgressView("Checking for updates")
                        .controlSize(.small)
                } else {
                    Button("Check Now") {
                        Task { await model.checkNow() }
                    }
                    .accessibilityIdentifier("system.update.check")
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Text("Installed version").foregroundStyle(.secondary)
                    Text(model.installedVersionDescription)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("system.update.installedVersion")
                }
                if let release = model.state.release {
                    GridRow {
                        Text("Latest version").foregroundStyle(.secondary)
                        Text(release.version.description)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("system.update.latestVersion")
                    }
                }
                GridRow {
                    Text("Last checked").foregroundStyle(.secondary)
                    Text(lastCheckedDescription)
                }
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    statusLabel
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let release = model.availableRelease {
                Divider().padding(.vertical, 8)
                updateDetails(for: release)
            } else if let skipped = skippedRelease {
                Divider().padding(.vertical, 8)
                HStack(spacing: 12) {
                    Text("Version \(skipped.version.description) was skipped.")
                        .foregroundStyle(.secondary)
                    Button("Show Again") {
                        Task { await model.clearSkippedVersion() }
                    }
                    .accessibilityIdentifier("system.update.showAgain")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().padding(.vertical, 8)

            Toggle("Check automatically once a day", isOn: Binding(
                get: { model.automaticChecksEnabled },
                set: { enabled in Task { await model.setAutomaticChecks(enabled) } }
            ))
            .accessibilityIdentifier("system.update.automatic")
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await model.loadPreferences()
        }
        .accessibilityIdentifier("system.update.section")
    }

    private var skippedRelease: AppRelease? {
        guard let release = model.state.release, model.availableRelease == nil else {
            return nil
        }
        return release
    }

    private var lastCheckedDescription: String {
        guard let date = model.lastCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            Text("Checking…").foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.dsStateRunning)
                .accessibilityIdentifier("system.update.upToDate")
        case .available(let release):
            Label(
                "Version \(release.version.description) is available",
                systemImage: "arrow.down.circle.fill"
            )
            .foregroundStyle(Color.dsBlue400)
            .accessibilityIdentifier("system.update.available")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.dsStateAttention)
                .textSelection(.enabled)
                .accessibilityIdentifier("system.update.failed")
        }
    }

    @ViewBuilder
    private func updateDetails(for release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(release.name).font(.headline)

            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .accessibilityIdentifier("system.update.notes")
            }

            UpdateActions(model: model, release: release)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UpdateActions: View {
    let model: UpdateModel
    let release: AppRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Copy Install Command") {
                    model.copyInstallCommand()
                }
                .accessibilityIdentifier("system.update.copyCommand")

                Button("Release Notes…") {
                    NSWorkspace.shared.open(release.pageURL)
                }
                .accessibilityIdentifier("system.update.openRelease")

                Button("Skip This Version") {
                    Task { await model.skipCurrentVersion() }
                }
                .accessibilityIdentifier("system.update.skip")
            }

            if model.didCopyInstallCommand {
                Label(
                    "Command copied. Paste it into Terminal to upgrade in place.",
                    systemImage: "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("system.update.copied")
            } else {
                Text("Upgrade by running the install command in Terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Shown when the user asks for a check from the menu, so the answer is visible
/// from any screen.
struct UpdateResultSheet: View {
    let model: UpdateModel
    let result: UpdateCheckState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbolName)
                .font(.title3.bold())
                .foregroundStyle(symbolColor)

            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let release = result.release {
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                UpdateActions(model: model, release: release)
            }

            HStack {
                Spacer()
                Button("Done") {
                    model.dismissManualResult()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("update.result.done")
            }
        }
        .padding(24)
        .frame(minWidth: 460, maxWidth: 560)
        .accessibilityIdentifier("update.result.sheet")
    }

    private var title: String {
        switch result {
        case .available: "Update Available"
        case .upToDate: "You’re Up to Date"
        case .failed: "Update Check Failed"
        case .idle, .checking: "Checking for Updates"
        }
    }

    private var message: String {
        switch result {
        case .available(let release):
            "Container GUI \(release.version.description) is available. You have \(model.installedVersionDescription)."
        case .upToDate:
            "Container GUI \(model.installedVersionDescription) is the latest release."
        case .failed(let reason):
            reason
        case .idle, .checking:
            "Contacting GitHub…"
        }
    }

    private var symbolName: String {
        switch result {
        case .available: "arrow.down.circle.fill"
        case .upToDate: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .idle, .checking: "arrow.clockwise"
        }
    }

    private var symbolColor: Color {
        switch result {
        case .available: .blue
        case .upToDate: .green
        case .failed: .orange
        case .idle, .checking: .secondary
        }
    }
}
