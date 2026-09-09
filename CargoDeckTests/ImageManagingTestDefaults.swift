import Foundation
@testable import CargoDeck

/// A stream that terminates successfully with no output.
nonisolated func emptyProcessEventStream() -> AsyncThrowingStream<ProcessEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(.terminated(exitCode: 0))
        continuation.finish()
    }
}

/// Test-only defaults, so a stub that exists to answer `listImages` does not
/// have to spell out six streaming operations it never exercises. A stub that
/// does exercise one declares it and takes over.
///
/// This lives in the test target only: every production conformance implements
/// the full protocol itself, so nothing here can mask a missing implementation.
extension ImageManaging {
    func pullImage(
        _ configuration: ImagePullConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        emptyProcessEventStream()
    }

    func pushImage(
        _ configuration: ImagePushConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        emptyProcessEventStream()
    }

    func tagImage(_ configuration: ImageTagConfiguration) async throws {}

    func saveImages(
        _ configuration: ImageSaveConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        emptyProcessEventStream()
    }

    func loadImages(
        _ configuration: ImageLoadConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        emptyProcessEventStream()
    }

    func deleteImages(
        _ configuration: ImageDeleteConfiguration
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        emptyProcessEventStream()
    }

    func pruneImages(all: Bool) -> AsyncThrowingStream<ProcessEvent, Error> {
        emptyProcessEventStream()
    }
}
