import Foundation
import Observation

struct BuildKeyValueDraft: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

enum ImageBuildOutcome: Equatable {
    case succeeded
    case failed
    case cancelled
}

@MainActor
@Observable
final class ImageBuildModel: Identifiable {
    let id = UUID()
    var tag = ""
    var contextDirectory = ""
    var dockerfile = ""
    var buildArguments: [BuildKeyValueDraft] = []
    var labels: [BuildKeyValueDraft] = []
    var noCache = false
    var pull = false
    var target = ""
    var platform = ""
    var operatingSystem = ""
    var architecture = ""
    var cpuLimit = ""
    var memoryLimit = ""
    var exportsOutput = false
    var outputType: BuildOutputType = .oci
    var outputDestination = ""

    private(set) var isBuilding = false
    private(set) var progress = ""
    private(set) var errorMessage: String?

    var tagError: String? {
        validationMessage { _ = try ImageReference(validating: trimmed(tag)) }
    }

    var contextError: String? {
        validationMessage {
            _ = try LocalPath(validating: trimmed(contextDirectory), field: "Build context directory")
        }
    }

    var dockerfileError: String? {
        optionalValidation(dockerfile) {
            _ = try LocalPath(validating: $0, field: "Dockerfile path")
        }
    }

    var platformError: String? {
        optionalValidation(platform) { _ = try BuildPlatform(validating: $0) }
    }

    var targetError: String? {
        optionalValidation(target) { _ = try BuildConfiguration.validatedToken($0, field: "Build target") }
    }

    var operatingSystemError: String? {
        optionalValidation(operatingSystem) { _ = try BuildConfiguration.validatedToken($0, field: "Build OS") }
    }

    var architectureError: String? {
        optionalValidation(architecture) { _ = try BuildConfiguration.validatedToken($0, field: "Build architecture") }
    }

    var cpuLimitError: String? {
        optionalValidation(cpuLimit) { _ = try CPULimit($0) }
    }

    var memoryLimitError: String? {
        optionalValidation(memoryLimit) { _ = try MemoryLimit($0) }
    }

    var outputDestinationError: String? {
        guard exportsOutput else { return nil }
        return optionalValidation(outputDestination) {
            _ = try LocalPath(validating: $0, field: "Build output destination")
        }
    }

    func argumentError(for draft: BuildKeyValueDraft) -> String? {
        keyValueError(for: draft, in: buildArguments, field: "Build argument")
    }

    func labelError(for draft: BuildKeyValueDraft) -> String? {
        keyValueError(for: draft, in: labels, field: "Build label")
    }

    var configuration: BuildConfiguration? { try? makeConfiguration() }
    var canBuild: Bool { configuration != nil && !isBuilding }

    var commandPreview: String {
        guard let configuration else { return "container build" }
        return ProcessContainerCLI.displayInvocation(
            executable: "container",
            arguments: ContainerCommand.build(configuration).arguments
        )
    }

    var advancedSetCount: Int {
        [noCache, pull, exportsOutput].count(where: { $0 })
            + [dockerfile, target, platform, operatingSystem, architecture, cpuLimit, memoryLimit, outputDestination]
                .count { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            + buildArguments.count
            + labels.count
    }

    func addBuildArgument() { buildArguments.append(BuildKeyValueDraft()) }
    func removeBuildArgument(id: UUID) { buildArguments.removeAll { $0.id == id } }
    func addLabel() { labels.append(BuildKeyValueDraft()) }
    func removeLabel(id: UUID) { labels.removeAll { $0.id == id } }

    func build(using appModel: AppModel) async -> ImageBuildOutcome {
        guard let configuration, !isBuilding else { return .failed }
        isBuilding = true
        progress = ""
        errorMessage = nil
        defer { isBuilding = false }
        do {
            try await appModel.buildImage(configuration) { [weak self] event in
                self?.record(event)
            }
            return .succeeded
        } catch is CancellationError {
            await appModel.reconcileAfterCancelledBuild()
            return .cancelled
        } catch CLIError.cancelled {
            await appModel.reconcileAfterCancelledBuild()
            return .cancelled
        } catch {
            errorMessage = DiagnosticSanitizer.sanitize(error.localizedDescription)
            return .failed
        }
    }

    private func makeConfiguration() throws -> BuildConfiguration {
        try BuildConfiguration(
            tag: trimmed(tag),
            contextDirectory: trimmed(contextDirectory),
            dockerfile: optionalTrimmed(dockerfile),
            buildArguments: try buildArguments.map(makeKeyValue),
            labels: try labels.map(makeKeyValue),
            noCache: noCache,
            target: optionalTrimmed(target),
            platform: optionalTrimmed(platform),
            operatingSystem: optionalTrimmed(operatingSystem),
            architecture: optionalTrimmed(architecture),
            cpuLimit: optionalTrimmed(cpuLimit),
            memoryLimit: optionalTrimmed(memoryLimit),
            output: exportsOutput
                ? try BuildOutput(
                    type: outputType,
                    destination: optionalTrimmed(outputDestination)
                )
                : nil,
            pull: pull
        )
    }

    private func makeKeyValue(_ draft: BuildKeyValueDraft) throws -> BuildKeyValue {
        try BuildKeyValue(key: trimmed(draft.key), value: draft.value)
    }

    private func keyValueError(
        for draft: BuildKeyValueDraft,
        in rows: [BuildKeyValueDraft],
        field: String
    ) -> String? {
        let key = trimmed(draft.key)
        if !key.isEmpty, rows.filter({ trimmed($0.key) == key }).count > 1 {
            return "Duplicate \(field.lowercased()) key."
        }
        return validationMessage { _ = try makeKeyValue(draft) }
    }

    private func optionalValidation(
        _ value: String,
        operation: (String) throws -> Void
    ) -> String? {
        guard let value = optionalTrimmed(value) else { return nil }
        return validationMessage { try operation(value) }
    }

    private func validationMessage(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch {
            return DiagnosticSanitizer.sanitize(error.localizedDescription)
        }
    }

    private func record(_ event: ProcessEvent) {
        let text: String
        switch event {
        case .standardOutput(let output), .standardError(let output): text = output
        case .terminated(let exitCode): text = "Process exited with status \(exitCode).\n"
        }
        progress.append(DiagnosticSanitizer.sanitize(text))
        if progress.count > 65_536 { progress = String(progress.suffix(65_536)) }
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
