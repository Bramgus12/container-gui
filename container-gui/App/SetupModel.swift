import AppKit
import Foundation
import Observation

nonisolated protocol PreflightServicing: Sendable {
    func check() async -> PreflightReadiness
    func retry() async -> PreflightReadiness
    func selectCustomExecutable(_ url: URL) async -> PreflightReadiness
    func resetCustomExecutable() async -> PreflightReadiness
    func startService() async -> PreflightReadiness
}

extension PreflightService: PreflightServicing {}

@MainActor
protocol DiagnosticsCopying {
    func copy(_ value: String)
}

@MainActor
struct SystemDiagnosticsCopier: DiagnosticsCopying {
    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
@Observable
final class SetupModel {
    private(set) var readiness: PreflightReadiness = .checking
    private(set) var isWorking = false
    private(set) var didCopyDiagnostics = false

    private let preflight: any PreflightServicing
    private let diagnosticsCopier: any DiagnosticsCopying
    private var hasChecked = false

    convenience init() {
        self.init(
            preflight: PreflightService(),
            diagnosticsCopier: SystemDiagnosticsCopier()
        )
    }

    init(
        preflight: any PreflightServicing,
        diagnosticsCopier: any DiagnosticsCopying
    ) {
        self.preflight = preflight
        self.diagnosticsCopier = diagnosticsCopier
    }

    func checkIfNeeded() async {
        guard !hasChecked else { return }
        hasChecked = true
        await perform(showCheckingState: true) {
            await preflight.check()
        }
    }

    func retry() async {
        await perform(showCheckingState: true) {
            await preflight.retry()
        }
    }

    func chooseExecutable(_ url: URL) async {
        await perform(showCheckingState: true) {
            await preflight.selectCustomExecutable(url)
        }
    }

    func resetCustomExecutable() async {
        await perform(showCheckingState: true) {
            await preflight.resetCustomExecutable()
        }
    }

    func startService() async {
        await perform(showCheckingState: false) {
            await preflight.startService()
        }
    }

    var diagnosticsText: String? {
        guard case .failure(let executableURL, let diagnostic) = readiness else {
            return nil
        }

        var lines = [
            "Container GUI setup diagnostics",
            "OS: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(PlatformSnapshot.current.architecture)",
        ]
        if let executableURL {
            lines.append("Executable: \(executableURL.path)")
        }
        lines.append("Error: \(diagnostic.summary)")
        if let invocation = diagnostic.invocation {
            lines.append("Command: \(invocation)")
        }
        if let exitCode = diagnostic.exitCode {
            lines.append("Exit code: \(exitCode)")
        }
        if let standardError = diagnostic.standardError, !standardError.isEmpty {
            lines.append("Standard error:\n\(standardError)")
        }
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        guard let diagnosticsText else { return }
        diagnosticsCopier.copy(diagnosticsText)
        didCopyDiagnostics = true
    }

    private func perform(
        showCheckingState: Bool,
        operation: () async -> PreflightReadiness
    ) async {
        guard !isWorking else { return }
        isWorking = true
        didCopyDiagnostics = false
        if showCheckingState {
            readiness = .checking
        }
        let result = await operation()
        readiness = result
        isWorking = false
    }
}
