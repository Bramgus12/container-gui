import Foundation

nonisolated protocol ImageManaging: Sendable {
    func listImages() async throws -> [ImageSummary]
    func inspectImage(reference: String) async throws -> ImageInspection

    /// Transfers and bulk mutations stream: they outlast the bounded `run`
    /// timeout, they produce progress worth showing while it happens, and they
    /// have to be cancellable. Tag is the exception — it is one metadata write.
    func pullImage(_ configuration: ImagePullConfiguration) -> AsyncThrowingStream<ProcessEvent, Error>
    func pushImage(_ configuration: ImagePushConfiguration) -> AsyncThrowingStream<ProcessEvent, Error>
    func tagImage(_ configuration: ImageTagConfiguration) async throws
    func saveImages(_ configuration: ImageSaveConfiguration) -> AsyncThrowingStream<ProcessEvent, Error>
    func loadImages(_ configuration: ImageLoadConfiguration) -> AsyncThrowingStream<ProcessEvent, Error>
    func deleteImages(_ configuration: ImageDeleteConfiguration) -> AsyncThrowingStream<ProcessEvent, Error>
    func pruneImages(all: Bool) -> AsyncThrowingStream<ProcessEvent, Error>
}

nonisolated struct CLIImageService: ImageManaging {
    let cli: any ContainerCLI

    func listImages() async throws -> [ImageSummary] {
        let result = try await cli.run(.listImages)
        do {
            return try JSONDecoder()
                .decode([ImageDTO].self, from: Data(result.standardOutput.utf8))
                .compactMap(ImageSummary.init(dto:))
        } catch {
            throw CLIError.invalidOutput(
                description: "The image list could not be decoded as JSON: \(error.localizedDescription)"
            )
        }
    }

    func inspectImage(reference: String) async throws -> ImageInspection {
        let imageReference = try ImageReference(validating: reference)
        let result = try await cli.run(.inspectImage(reference: imageReference))
        let data = Data(result.standardOutput.utf8)
        do {
            let dtos: [ImageDTO]
            if let decoded = try? JSONDecoder().decode([ImageDTO].self, from: data) {
                dtos = decoded
            } else {
                dtos = [try JSONDecoder().decode(ImageDTO.self, from: data)]
            }
            guard let dto = dtos.first,
                  dto.containsInspectionData,
                  let inspection = ImageInspection(
                    dto: dto,
                    fallbackReference: reference,
                    rawJSON: result.standardOutput
                  ) else {
                throw CLIError.invalidOutput(description: "Image inspection returned no entries.")
            }
            return inspection
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidOutput(
                description: "Image inspection could not be decoded as JSON: \(error.localizedDescription)"
            )
        }
    }

    func pullImage(
        _ configuration: ImagePullConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        cli.stream(.pullImage(configuration: configuration))
    }

    func pushImage(
        _ configuration: ImagePushConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        cli.stream(.pushImage(configuration: configuration))
    }

    func tagImage(_ configuration: ImageTagConfiguration) async throws {
        do {
            _ = try await cli.run(.tagImage(configuration: configuration))
        } catch {
            throw sanitizedImageError(error)
        }
    }

    func saveImages(
        _ configuration: ImageSaveConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        cli.stream(.saveImages(configuration: configuration))
    }

    func loadImages(
        _ configuration: ImageLoadConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        cli.stream(.loadImages(configuration: configuration))
    }

    func deleteImages(
        _ configuration: ImageDeleteConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        cli.stream(.deleteImages(configuration: configuration))
    }

    func pruneImages(all: Bool) -> AsyncThrowingStream<ProcessEvent, Error> {
        cli.stream(.pruneImages(all: all))
    }
}

/// What a drained streaming operation produced, once it finished successfully.
nonisolated struct ImageOperationOutput: Equatable, Sendable {
    var standardOutput = ""
    var standardError = ""

    /// Both streams in the order the CLI is read, for the operations whose
    /// result is a human-readable report rather than parsed data.
    var combined: String { standardOutput + standardError }
}

/// Runs a streamed image operation to completion, forwarding every event as it
/// arrives, and turns a nonzero termination into a sanitized `CLIError` that
/// still carries the output the operation managed to produce.
///
/// Every streaming caller goes through here so a failed transfer reports the
/// same way as a failed bounded command, and so the exit-code-to-error mapping
/// exists once rather than in each of the six operations.
@discardableResult
nonisolated func drainImageOperation(
    _ events: AsyncThrowingStream<ProcessEvent, Error>,
    command: ContainerCommand,
    onEvent: (ProcessEvent) -> Void = { _ in }
) async throws -> ImageOperationOutput {
    var output = ImageOperationOutput()
    do {
        for try await event in events {
            switch event {
            case .standardOutput(let text):
                output.standardOutput.append(text)
            case .standardError(let text):
                output.standardError.append(text)
            case .terminated(let exitCode) where exitCode != 0:
                onEvent(event)
                throw sanitizedImageError(
                    CLIError.nonZeroExit(
                        invocation: ProcessContainerCLI.displayInvocation(
                            executable: "container",
                            arguments: command.arguments
                        ),
                        exitCode: exitCode,
                        standardError: output.standardError,
                        standardOutput: output.standardOutput
                    )
                )
            case .terminated:
                break
            }
            onEvent(event)
        }
    } catch let error as CLIError {
        throw sanitizedImageError(error)
    }
    return output
}

nonisolated func sanitizedImageError(_ error: Error) -> Error {
    guard let cliError = error as? CLIError else {
        return CLIError.launchFailed(
            message: DiagnosticSanitizer.sanitize(error.localizedDescription)
        )
    }
    switch cliError {
    case .nonZeroExit(let invocation, let exitCode, let standardError, let standardOutput):
        return CLIError.nonZeroExit(
            invocation: DiagnosticSanitizer.sanitize(invocation),
            exitCode: exitCode,
            standardError: DiagnosticSanitizer.sanitize(standardError),
            standardOutput: DiagnosticSanitizer.sanitize(standardOutput)
        )
    case .invalidOutput(let description):
        return CLIError.invalidOutput(description: DiagnosticSanitizer.sanitize(description))
    case .launchFailed(let message):
        return CLIError.launchFailed(message: DiagnosticSanitizer.sanitize(message))
    default:
        return cliError
    }
}
