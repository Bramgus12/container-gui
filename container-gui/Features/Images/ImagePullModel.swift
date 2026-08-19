import Foundation
import Observation

@MainActor
@Observable
final class ImagePullModel: Identifiable {
    let id = UUID()
    var reference = ""
    private(set) var isPulling = false
    private(set) var didFinish = false
    private(set) var progress = ""
    private(set) var errorMessage: String?
    private(set) var progressLabel = "Waiting to start"
    private(set) var progressFraction: Double?

    var referenceError: String? {
        do {
            _ = try ImageReference(validating: trimmedReference)
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    var canPull: Bool {
        referenceError == nil && !isPulling && !didFinish
    }

    var commandPreview: String {
        guard let reference = try? ImageReference(validating: trimmedReference) else {
            return "container image pull"
        }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.pullImage(reference: reference).arguments
        )
    }

    func pull(using appModel: AppModel) async {
        guard canPull else { return }
        isPulling = true
        progress = ""
        errorMessage = nil
        defer { isPulling = false }

        do {
            try await appModel.pullImage(reference: trimmedReference) { [weak self] event in
                self?.record(event)
            }
            didFinish = true
        } catch is CancellationError {
            errorMessage = "Pull cancelled."
        } catch CLIError.cancelled {
            errorMessage = "Pull cancelled."
        } catch {
            errorMessage = DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    private var trimmedReference: String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func record(_ event: ProcessEvent) {
        switch event {
        case .standardOutput(let output), .standardError(let output):
            progress.append(DiagnosticSanitizer.sanitize(output))
            updateParsedProgress(from: output)
        case .terminated(let exitCode):
            progress.append("Process exited with status \(exitCode).\n")
        }
        if progress.count > 65_536 {
            progress = String(progress.suffix(65_536))
        }
    }

    private func updateParsedProgress(from output: String) {
        guard let line = output.split(whereSeparator: \.isNewline).last.map(String.init),
              !line.isEmpty else { return }
        progressLabel = DiagnosticSanitizer.sanitize(line)

        let pattern = #"(\d+)\s*/\s*(\d+)"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ),
        let completedRange = Range(match.range(at: 1), in: line),
        let totalRange = Range(match.range(at: 2), in: line),
        let completed = Double(line[completedRange]),
        let total = Double(line[totalRange]), total > 0 else {
            progressFraction = nil
            return
        }
        progressFraction = min(1, max(0, completed / total))
    }
}
