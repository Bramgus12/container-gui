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

    var referenceError: String? {
        do {
            _ = try ImageReference(validating: trimmedReference)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var canPull: Bool {
        referenceError == nil && !isPulling && !didFinish
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
            errorMessage = error.localizedDescription
        }
    }

    private var trimmedReference: String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func record(_ event: ProcessEvent) {
        switch event {
        case .standardOutput(let output), .standardError(let output):
            progress.append(output)
        case .terminated(let exitCode):
            progress.append("Process exited with status \(exitCode).\n")
        }
        if progress.count > 65_536 {
            progress = String(progress.suffix(65_536))
        }
    }
}
