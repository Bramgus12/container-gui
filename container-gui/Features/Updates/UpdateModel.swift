import Foundation
import Observation

nonisolated protocol UpdateChecking: Sendable {
    func latestRelease() async throws -> AppRelease
}

actor GitHubUpdateService: UpdateChecking {
    private let session: URLSession
    private let url: URL

    init(
        url: URL = AppDistribution.latestReleaseAPIURL,
        session: URLSession? = nil
    ) {
        self.url = url
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.httpAdditionalHeaders = [
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "Container-GUI/\(AppVersion.current)",
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    func latestRelease() async throws -> AppRelease {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw UpdateCheckError.unreachable(reason: error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                break
            case 403, 429:
                throw UpdateCheckError.rateLimited
            case 404:
                throw UpdateCheckError.notFound
            default:
                throw UpdateCheckError.invalidResponse(status: http.statusCode)
            }
        }

        let dto: GitHubReleaseDTO
        do {
            dto = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        } catch {
            throw UpdateCheckError.invalidRelease(
                reason: "The response could not be decoded."
            )
        }
        return try AppRelease(dto: dto)
    }
}

nonisolated protocol UpdatePreferencesStoring: Sendable {
    func automaticChecksEnabled() async -> Bool
    func setAutomaticChecksEnabled(_ enabled: Bool) async
    func lastCheckDate() async -> Date?
    func setLastCheckDate(_ date: Date) async
    func skippedVersion() async -> SemanticVersion?
    func setSkippedVersion(_ version: SemanticVersion?) async
}

actor UserDefaultsUpdatePreferences: UpdatePreferencesStoring {
    static let automaticChecksKey = "updateAutomaticChecksEnabled"
    static let lastCheckDateKey = "updateLastCheckDate"
    static let skippedVersionKey = "updateSkippedVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func automaticChecksEnabled() -> Bool {
        // Absent means "not configured yet", which is on by default.
        defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticChecksKey)
    }

    func lastCheckDate() -> Date? {
        defaults.object(forKey: Self.lastCheckDateKey) as? Date
    }

    func setLastCheckDate(_ date: Date) {
        defaults.set(date, forKey: Self.lastCheckDateKey)
    }

    func skippedVersion() -> SemanticVersion? {
        guard let value = defaults.string(forKey: Self.skippedVersionKey) else {
            return nil
        }
        return try? SemanticVersion(value)
    }

    func setSkippedVersion(_ version: SemanticVersion?) {
        if let version {
            defaults.set(version.description, forKey: Self.skippedVersionKey)
        } else {
            defaults.removeObject(forKey: Self.skippedVersionKey)
        }
    }
}

nonisolated enum UpdateCheckState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(AppRelease)
    case failed(String)

    var release: AppRelease? {
        guard case .available(let release) = self else { return nil }
        return release
    }
}

@MainActor
@Observable
final class UpdateModel {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var state: UpdateCheckState = .idle
    private(set) var automaticChecksEnabled = true
    private(set) var lastCheckDate: Date?
    private(set) var skippedVersion: SemanticVersion?
    private(set) var didCopyInstallCommand = false

    /// Set when a check the user asked for finishes, so the result can be
    /// presented from any screen rather than only the System screen.
    var pendingManualResult: UpdateCheckState?

    let installedVersion: SemanticVersion?

    private let service: any UpdateChecking
    private let preferences: any UpdatePreferencesStoring
    private let installCommandCopier: any DiagnosticsCopying
    private let now: @Sendable () -> Date
    private var isLoaded = false

    init(
        service: any UpdateChecking,
        preferences: any UpdatePreferencesStoring = UserDefaultsUpdatePreferences(),
        installCommandCopier: (any DiagnosticsCopying)? = nil,
        installedVersion: SemanticVersion? = AppVersion.semantic(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.preferences = preferences
        self.installCommandCopier = installCommandCopier ?? SystemDiagnosticsCopier()
        self.installedVersion = installedVersion
        self.now = now
    }

    var isChecking: Bool {
        state == .checking
    }

    var installedVersionDescription: String {
        installedVersion?.description ?? AppVersion.current
    }

    /// The release the System screen should surface. A skipped version stays
    /// hidden until the user checks manually.
    var availableRelease: AppRelease? {
        guard case .available(let release) = state else { return nil }
        if let skippedVersion, release.version <= skippedVersion {
            return nil
        }
        return release
    }

    func loadPreferences() async {
        guard !isLoaded else { return }
        isLoaded = true
        automaticChecksEnabled = await preferences.automaticChecksEnabled()
        lastCheckDate = await preferences.lastCheckDate()
        skippedVersion = await preferences.skippedVersion()
    }

    /// Called at launch. Does nothing unless automatic checks are on and the
    /// last check is at least a day old.
    func checkIfNeeded() async {
        await loadPreferences()
        guard automaticChecksEnabled, !isChecking else { return }
        if let lastCheckDate,
           now().timeIntervalSince(lastCheckDate) < Self.checkInterval {
            return
        }
        await check(isManual: false)
    }

    /// Called from the menu item and the Check Now button. Always checks and
    /// always reports what it found.
    func checkNow() async {
        await loadPreferences()
        guard !isChecking else { return }
        await check(isManual: true)
    }

    func skipCurrentVersion() async {
        guard let release = state.release else { return }
        skippedVersion = release.version
        await preferences.setSkippedVersion(release.version)
    }

    func clearSkippedVersion() async {
        skippedVersion = nil
        await preferences.setSkippedVersion(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) async {
        automaticChecksEnabled = enabled
        await preferences.setAutomaticChecksEnabled(enabled)
    }

    func copyInstallCommand() {
        installCommandCopier.copy(AppDistribution.installCommand)
        didCopyInstallCommand = true
    }

    func dismissManualResult() {
        pendingManualResult = nil
    }

    func resetCopyConfirmation() {
        didCopyInstallCommand = false
    }

    private func check(isManual: Bool) async {
        state = .checking
        didCopyInstallCommand = false

        do {
            let release = try await service.latestRelease()
            let checkedAt = now()
            lastCheckDate = checkedAt
            await preferences.setLastCheckDate(checkedAt)

            if let installedVersion, release.version <= installedVersion {
                state = .upToDate(checkedAt: checkedAt)
            } else {
                state = .available(release)
            }
        } catch is CancellationError {
            state = .idle
            return
        } catch {
            state = .failed(DiagnosticSanitizer.sanitize(error.localizedDescription))
        }

        if isManual {
            pendingManualResult = state
        }
    }
}
