import Darwin
import Foundation

nonisolated protocol ResolverDirectoryReading: Sendable {
    func resolverFiles() -> [ResolverFile]
    func configFileURL() -> URL
}

nonisolated protocol HostResolving: Sendable {
    func resolve(_ host: String) async -> DNSProbeResult
}

nonisolated struct SystemResolverDirectoryReader: ResolverDirectoryReading {
    private let resolverDirectory = URL(fileURLWithPath: "/etc/resolver", isDirectory: true)

    func resolverFiles() -> [ResolverFile] {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: resolverDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { url in
            guard url.lastPathComponent.hasPrefix("containerization."), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ResolverFile.parse(text, path: url)
        }
    }

    func configFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/container/config.toml")
    }
}

nonisolated struct SystemHostResolver: HostResolving {
    func resolve(_ host: String) async -> DNSProbeResult {
        await withTaskGroup(of: DNSProbeResult.self) { group in
            group.addTask { Self.lookup(host) }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return .failed("The DNS lookup timed out after 3 seconds.")
            }
            let result = await group.next() ?? .failed("The DNS lookup did not return a result.")
            group.cancelAll()
            return result
        }
    }

    private static func lookup(_ host: String) -> DNSProbeResult {
        let clock = ContinuousClock()
        let start = clock.now
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        defer { if let result { freeaddrinfo(result) } }
        guard status == 0, let address = result?.pointee.ai_addr else { return .failed(String(cString: gai_strerror(status))) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, result!.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return .failed("The resolved address could not be read.") }
        return .resolved(address: String(cString: buffer), duration: start.duration(to: clock.now))
    }
}
