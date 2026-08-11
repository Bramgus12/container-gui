import Foundation

nonisolated struct PlatformSnapshot: Equatable, Sendable {
    let architecture: String
    let operatingSystemVersion: PlatformVersion

    static var current: PlatformSnapshot {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unsupported"
        #endif
        return PlatformSnapshot(
            architecture: architecture,
            operatingSystemVersion: PlatformVersion(
                ProcessInfo.processInfo.operatingSystemVersion
            )
        )
    }
}

nonisolated struct PlatformVersion: Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init(_ version: OperatingSystemVersion) {
        self.init(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion
        )
    }
}

nonisolated enum PlatformIssue: Equatable, Sendable {
    case requiresAppleSilicon(detectedArchitecture: String)
    case requiresMacOS(minimumMajorVersion: Int, detected: PlatformVersion)
}

nonisolated struct SupportedCLIVersions: Equatable, Sendable {
    static let current = SupportedCLIVersions(
        minimum: SemanticVersion(major: 0, minor: 12, patch: 0),
        maximumExclusive: SemanticVersion(major: 2, minor: 0, patch: 0)
    )

    let minimum: SemanticVersion
    let maximumExclusive: SemanticVersion

    func contains(_ version: SemanticVersion) -> Bool {
        version >= minimum && version < maximumExclusive
    }

    var displayValue: String {
        "\(minimum)–<\(maximumExclusive)"
    }
}

nonisolated struct PreflightContext: Equatable, Sendable {
    let executableURL: URL
    let versions: SystemVersion
    let status: SystemStatus
}

nonisolated struct PreflightDiagnostic: Equatable, Sendable {
    let summary: String
    let invocation: String?
    let standardError: String?
    let exitCode: Int32?

    init(error: Error) {
        summary = DiagnosticSanitizer.sanitize(
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
        if case .nonZeroExit(let invocation, let exitCode, let standardError, _) = error as? CLIError {
            self.invocation = invocation
            self.standardError = DiagnosticSanitizer.sanitize(standardError)
            self.exitCode = exitCode
        } else {
            invocation = nil
            standardError = nil
            exitCode = nil
        }
    }

    init(summary: String) {
        self.summary = DiagnosticSanitizer.sanitize(summary)
        invocation = nil
        standardError = nil
        exitCode = nil
    }
}

nonisolated enum DiagnosticSanitizer {
    static func sanitize(_ value: String) -> String {
        var result = value
        let replacements = [
            (
                #"(?i)\b(bearer)(\s+)([A-Za-z0-9._~+/=-]+)"#,
                "$1$2<redacted>"
            ),
            (
                #"(?i)(["'][^"']*(?:password|passwd|token|secret|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth)[^"']*["']\s*:\s*)(["'][^"']*["']|[^,\s}\]]+)"#,
                "$1\"<redacted>\""
            ),
            (
                #"(?i)([A-Za-z0-9_.-]*(?:password|passwd|token|secret|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth)[A-Za-z0-9_.-]*)(\s*[:=]\s*)([^\s,;]+)"#,
                "$1$2<redacted>"
            ),
            (
                #"(?i)(https?://)[^/@\s:]+:[^/@\s]+@"#,
                "$1<redacted>@"
            ),
            (
                #"(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#,
                "<redacted private key>"
            ),
        ]

        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }
}

nonisolated enum PreflightReadiness: Equatable, Sendable {
    case checking
    case unsupportedPlatform(PlatformIssue)
    case missingCLI(customExecutableURL: URL?)
    case unsupportedVersion(
        detected: String,
        supported: SupportedCLIVersions,
        executableURL: URL,
        versions: SystemVersion
    )
    case serviceStopped(PreflightContext)
    case failure(executableURL: URL?, diagnostic: PreflightDiagnostic)
    case ready(PreflightContext)
}

nonisolated protocol ExecutableFileChecking: Sendable {
    func isExecutableFile(at url: URL) -> Bool
}

nonisolated struct LocalExecutableFileChecker: ExecutableFileChecking {
    func isExecutableFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return url.isFileURL
            && url.path.hasPrefix("/")
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}

actor PreflightService {
    static let documentedExecutableURL = URL(fileURLWithPath: "/usr/local/bin/container")
    static let homebrewExecutableURL = URL(fileURLWithPath: "/opt/homebrew/bin/container")
    static let minimumMacOSMajorVersion = 26

    private(set) var readiness: PreflightReadiness = .checking

    private let platform: PlatformSnapshot
    private let standardExecutableURLs: [URL]
    private let bookmarkStore: any ExecutableBookmarkStoring
    private let fileChecker: any ExecutableFileChecking
    private let cliFactory: any ContainerCLIMaking
    private let supportedVersions: SupportedCLIVersions
    private let decoder: JSONDecoder

    init(
        platform: PlatformSnapshot = .current,
        standardExecutableURLs: [URL] = [
            PreflightService.documentedExecutableURL,
            PreflightService.homebrewExecutableURL,
        ],
        bookmarkStore: any ExecutableBookmarkStoring = UserDefaultsExecutableBookmarkStore(),
        fileChecker: any ExecutableFileChecking = LocalExecutableFileChecker(),
        cliFactory: any ContainerCLIMaking = ProcessContainerCLIFactory(),
        supportedVersions: SupportedCLIVersions = .current,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.platform = platform
        self.standardExecutableURLs = standardExecutableURLs
        self.bookmarkStore = bookmarkStore
        self.fileChecker = fileChecker
        self.cliFactory = cliFactory
        self.supportedVersions = supportedVersions
        self.decoder = decoder
    }

    @discardableResult
    func check() async -> PreflightReadiness {
        readiness = .checking

        if platform.architecture != "arm64" {
            return finish(.unsupportedPlatform(
                .requiresAppleSilicon(detectedArchitecture: platform.architecture)
            ))
        }
        if platform.operatingSystemVersion.major < Self.minimumMacOSMajorVersion {
            return finish(.unsupportedPlatform(.requiresMacOS(
                minimumMajorVersion: Self.minimumMacOSMajorVersion,
                detected: platform.operatingSystemVersion
            )))
        }

        let customURL: URL?
        do {
            customURL = try await bookmarkStore.load()
        } catch {
            return finish(.failure(
                executableURL: nil,
                diagnostic: PreflightDiagnostic(
                    summary: "The saved custom executable could not be resolved: \(error.localizedDescription)"
                )
            ))
        }

        let candidates = ([customURL].compactMap { $0 } + standardExecutableURLs)
            .uniqued()
        guard let executableURL = candidates.first(where: fileChecker.isExecutableFile(at:)) else {
            return finish(.missingCLI(customExecutableURL: customURL))
        }

        let cli = cliFactory.makeCLI(executableURL: executableURL)
        let versions: SystemVersion
        do {
            let result = try await cli.run(.systemVersion)
            let components = try decoder.decode(
                [SystemVersionDTO].self,
                from: Data(result.standardOutput.utf8)
            )
            versions = SystemVersion(components: components)
        } catch {
            return finish(.failure(
                executableURL: executableURL,
                diagnostic: PreflightDiagnostic(error: normalizedDecodeError(
                    error,
                    operation: "system version"
                ))
            ))
        }

        guard let cliVersionText = versions.cli?.version else {
            return finish(.failure(
                executableURL: executableURL,
                diagnostic: PreflightDiagnostic(
                    summary: "The version response did not identify the container CLI."
                )
            ))
        }

        let cliVersion: SemanticVersion
        do {
            cliVersion = try SemanticVersion(cliVersionText)
        } catch {
            return finish(.failure(
                executableURL: executableURL,
                diagnostic: PreflightDiagnostic(
                    summary: "The container CLI reported an invalid version: \(cliVersionText)."
                )
            ))
        }

        guard supportedVersions.contains(cliVersion) else {
            return finish(.unsupportedVersion(
                detected: cliVersionText,
                supported: supportedVersions,
                executableURL: executableURL,
                versions: versions
            ))
        }

        let status: SystemStatus
        do {
            let result = try await cli.run(.systemStatus)
            status = try decodeSystemStatus(result.standardOutput)
        } catch {
            if let stoppedStatus = stoppedSystemStatus(from: error) {
                let context = PreflightContext(
                    executableURL: executableURL,
                    versions: versions,
                    status: stoppedStatus
                )
                return finish(.serviceStopped(context))
            }
            return finish(.failure(
                executableURL: executableURL,
                diagnostic: PreflightDiagnostic(error: normalizedDecodeError(
                    error,
                    operation: "system status"
                ))
            ))
        }

        let context = PreflightContext(
            executableURL: executableURL,
            versions: versions,
            status: status
        )
        return finish(status.isRunning ? .ready(context) : .serviceStopped(context))
    }

    private func decodeSystemStatus(_ output: String) throws -> SystemStatus {
        let dto = try decoder.decode(
            SystemStatusDTO.self,
            from: Data(output.utf8)
        )
        guard dto.healthy != nil || dto.status != nil else {
            throw CLIError.invalidOutput(
                description: "The system status response contained no status."
            )
        }
        return SystemStatus(dto: dto)
    }

    private func stoppedSystemStatus(from error: Error) -> SystemStatus? {
        guard case .nonZeroExit(_, 1, _, let output) = error as? CLIError,
              let dto = try? decoder.decode(SystemStatusDTO.self, from: Data(output.utf8)),
              dto.healthy != true,
              let status = dto.status?.lowercased(),
              ["unregistered", "not running"].contains(status)
        else {
            return nil
        }
        return SystemStatus(dto: dto)
    }

    @discardableResult
    func retry() async -> PreflightReadiness {
        await check()
    }

    @discardableResult
    func selectCustomExecutable(_ url: URL) async -> PreflightReadiness {
        guard fileChecker.isExecutableFile(at: url) else {
            return finish(.failure(
                executableURL: url,
                diagnostic: PreflightDiagnostic(
                    summary: "The selected file is missing or is not executable."
                )
            ))
        }

        do {
            try await bookmarkStore.save(url)
        } catch {
            return finish(.failure(
                executableURL: url,
                diagnostic: PreflightDiagnostic(
                    summary: "The selected executable could not be saved: \(error.localizedDescription)"
                )
            ))
        }
        return await check()
    }

    @discardableResult
    func resetCustomExecutable() async -> PreflightReadiness {
        await bookmarkStore.reset()
        return await check()
    }

    @discardableResult
    func startService() async -> PreflightReadiness {
        guard case .serviceStopped(let context) = readiness else {
            return await check()
        }
        guard fileChecker.isExecutableFile(at: context.executableURL) else {
            return finish(.missingCLI(customExecutableURL: context.executableURL))
        }

        do {
            let cli = cliFactory.makeCLI(executableURL: context.executableURL)
            _ = try await cli.run(.systemStart)
        } catch {
            return finish(.failure(
                executableURL: context.executableURL,
                diagnostic: PreflightDiagnostic(error: error)
            ))
        }
        return await check()
    }

    private func finish(_ value: PreflightReadiness) -> PreflightReadiness {
        readiness = value
        return value
    }

    private func normalizedDecodeError(_ error: Error, operation: String) -> Error {
        if error is DecodingError {
            return CLIError.invalidOutput(
                description: "Malformed JSON from container \(operation)."
            )
        }
        return error
    }
}

nonisolated private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
