import Foundation

nonisolated protocol ImageBuilding: Sendable {
    func buildImage(
        _ configuration: BuildConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error>
}

nonisolated struct CLIImageBuildService: ImageBuilding {
    let cli: any ContainerCLI

    func buildImage(
        _ configuration: BuildConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        cli.stream(.build(configuration))
    }
}

nonisolated protocol BuilderManaging: Sendable {
    func status() async throws -> BuilderStatus
    func start(_ configuration: BuilderStartConfiguration) async throws
    func stop() async throws
    func delete() async throws
}

actor CLIBuilderService: BuilderManaging {
    private let cli: any ContainerCLI

    init(cli: any ContainerCLI) {
        self.cli = cli
    }

    func status() async throws -> BuilderStatus {
        do {
            let result = try await cli.run(.builderStatus)
            return try BuilderStatus.decode(from: Data(result.standardOutput.utf8))
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidOutput(
                description: "Builder status could not be decoded: \(error.localizedDescription)"
            )
        }
    }

    func start(_ configuration: BuilderStartConfiguration) async throws {
        _ = try await cli.run(.builderStart(configuration: configuration))
    }

    func stop() async throws {
        _ = try await cli.run(.builderStop)
    }

    func delete() async throws {
        _ = try await cli.run(.builderDelete)
    }
}
