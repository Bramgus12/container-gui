import Foundation

nonisolated protocol ExecutableBookmarkStoring: Sendable {
    func load() async throws -> URL?
    func save(_ url: URL) async throws
    func reset() async
}

actor UserDefaultsExecutableBookmarkStore: ExecutableBookmarkStoring {
    static let bookmarkKey = "customContainerExecutableBookmark"

    private let defaults: UserDefaults
    private let bookmarkKey: String

    init(
        defaults: UserDefaults = .standard,
        bookmarkKey: String = UserDefaultsExecutableBookmarkStore.bookmarkKey
    ) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
    }

    func load() throws -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            try save(url)
        }
        return url
    }

    func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: bookmarkKey)
    }

    func reset() {
        defaults.removeObject(forKey: bookmarkKey)
    }
}
