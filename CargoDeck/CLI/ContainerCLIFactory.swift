import Foundation

nonisolated protocol ContainerCLIMaking: Sendable {
    func makeCLI(executableURL: URL) -> any ContainerCLI
}

nonisolated struct ProcessContainerCLIFactory: ContainerCLIMaking {
    func makeCLI(executableURL: URL) -> any ContainerCLI {
        ProcessContainerCLI(executableURL: executableURL)
    }
}
