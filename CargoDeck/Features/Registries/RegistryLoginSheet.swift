import SwiftUI

/// The login form's state.
///
/// `password` is the only place the secret exists in this app, it is `@ObservationIgnored`
/// so it is never published to observers, and submission clears it before the
/// call is made rather than after it returns.
@MainActor
@Observable
final class RegistryLoginModel: Identifiable {
    let id = UUID()
    var server = ""
    var username = ""
    @ObservationIgnored var password = ""
    var scheme: RegistryScheme = .auto
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    /// Mirrors only whether a password has been typed. The view binds its
    /// enablement to this instead of reading the secret out of the model.
    private(set) var hasPassword = false

    var serverError: String? {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try RegistryHost(validating: trimmed)
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    var usernameError: String? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try RegistryLoginConfiguration(server: "example.test", username: trimmed)
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    var configuration: RegistryLoginConfiguration? {
        try? RegistryLoginConfiguration(
            server: server.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            scheme: scheme
        )
    }

    var canSubmit: Bool { configuration != nil && hasPassword && !isSubmitting }

    /// Ends in `--password-stdin` and contains no placeholder for the secret:
    /// showing asterisks would imply the password is part of the command, which
    /// is exactly the thing this design avoids.
    var commandPreview: String {
        guard let configuration else { return "container registry login --password-stdin" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.loginRegistry(configuration: configuration).arguments
        )
    }

    /// The only way the password is written.
    ///
    /// `password` is `@ObservationIgnored` so the secret is never published to
    /// observers — which also means SwiftUI cannot see it change. `hasPassword`
    /// is the observable half, and updating both here is what keeps the Log In
    /// button's enablement correct without the secret driving any view update.
    func setPassword(_ value: String) {
        password = value
        hasPassword = !value.isEmpty
    }

    /// Returns true when the login landed, so the sheet can dismiss.
    func submit(using model: RegistryModel) async -> Bool {
        guard let configuration, !isSubmitting, hasPassword else { return false }
        isSubmitting = true
        errorMessage = nil

        // Taken and cleared before the call, so a failure, a cancellation, or a
        // sheet left open never leaves the secret sitting in the form.
        let secret = password
        password = ""
        hasPassword = false

        let succeeded = await model.login(configuration, password: secret)
        isSubmitting = false
        if !succeeded {
            errorMessage = model.mutationFailure ?? "Login failed. Check the server, user name, and password."
        }
        return succeeded
    }
}

enum RegistryLoginSection: String, SheetSection {
    case credentials
    case transport

    var isRequired: Bool { self == .credentials }

    var title: LocalizedStringResource {
        switch self {
        case .credentials: "Credentials"
        case .transport: "Transport"
        }
    }
}

struct RegistryLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: RegistryLoginModel
    let model: RegistryModel
    @State private var page: RegistryLoginSection = .credentials

    var body: some View {
        SheetScaffold(
            command: draft.commandPreview,
            commandAccessibilityID: "registries.login.preview"
        ) {
            SheetSectionPane(
                title: "Log in to registry",
                selection: $page,
                accessibilityID: "registries.login.rail"
            ) {
                switch page {
                case .credentials: credentials
                case .transport: transport
                }
            }
        } footer: {
            SheetCancelButton(accessibilityID: "registries.login.cancel") { dismiss() }
                .disabled(draft.isSubmitting)

            Spacer()

            SheetPagingButtons(
                selection: $page,
                isDisabled: draft.isSubmitting,
                accessibilityIDPrefix: "registries.login"
            )

            Button {
                Task {
                    if await draft.submit(using: model) { dismiss() }
                }
            } label: {
                if draft.isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Log In")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!draft.canSubmit)
            .accessibilityIdentifier("registries.login.submit")
        }
        .interactiveDismissDisabled(draft.isSubmitting)
    }

    /// Routes every write through `setPassword`, which is what keeps the
    /// observable `hasPassword` in step with the unobserved secret.
    private var passwordBinding: Binding<String> {
        Binding(
            get: { draft.password },
            set: { draft.setPassword($0) }
        )
    }

    @ViewBuilder
    private var credentials: some View {
        Section("Registry") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Server") {
                    TextField(text: $draft.server, prompt: Text(verbatim: "ghcr.io")) {
                        Text("Server")
                    }
                    .labelsHidden()
                    .dsMonoField()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("registries.login.server")
                }
                if let error = draft.serverError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.dsStateDestructive)
                }
                Text("A host name, optionally with a port. Do not include https://.")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }

        Section("Sign in") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("User name") {
                    TextField(text: $draft.username) { Text("User name") }
                        .labelsHidden()
                        .dsMonoField()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("registries.login.username")
                }
                if let error = draft.usernameError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.dsStateDestructive)
                }

                LabeledContent("Password or token") {
                    SecureField(text: passwordBinding) { Text("Password or token") }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("registries.login.password")
                        .accessibilityLabel("Password or token, secure text field")
                }
                Text(
                    "The password is written to the command's standard input. It is never part of the command, the command preview, or any diagnostic this app writes."
                )
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
            }

            if let error = draft.errorMessage {
                InlineBanner(
                    message: "Login failed",
                    detail: error,
                    scope: .card,
                    severity: .error,
                    copyValue: error
                )
                .accessibilityIdentifier("registries.login.error")
            }
        }
    }

    @ViewBuilder
    private var transport: some View {
        Section("Scheme") {
            Picker("Scheme", selection: $draft.scheme) {
                Text("Automatic").tag(RegistryScheme.auto)
                Text(verbatim: "HTTPS").tag(RegistryScheme.https)
                Text(verbatim: "HTTP").tag(RegistryScheme.http)
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("registries.login.scheme")

            Text(
                "Automatic omits the flag and uses whatever this CLI defaults to. The accepted values changed between supported releases, so an explicit choice is emitted only when you make one."
            )
            .font(.caption)
            .foregroundStyle(Color.dsTextSecondary)

            if draft.scheme.isUnencrypted {
                InlineBanner(
                    message: "HTTP is not encrypted",
                    detail: String(localized: "Your user name and password travel in the clear, and so do the image layers. Use HTTP only on a network you control."),
                    scope: .card,
                    severity: .attention
                )
                .accessibilityIdentifier("registries.login.httpWarning")
            }
        }
    }
}
