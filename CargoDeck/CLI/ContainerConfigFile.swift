import Foundation

nonisolated protocol ServiceDomainWriting: Sendable {
    /// Sets the service DNS domain in `config.toml` and returns the file it
    /// wrote, leaving every other setting, comment, and blank line as it was.
    func writeServiceDomain(_ domain: DNSDomainName) throws -> URL
}

nonisolated enum ConfigFileError: Error, Equatable, Sendable {
    /// The file states `dns` in a shape this editor cannot change without
    /// risking the rest of the file — an inline table or an array of tables.
    case unsupportedLayout(path: String)
    case unreadable(path: String, message: String)
    case notWritable(path: String, message: String)
}

extension ConfigFileError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedLayout(let path):
            "The DNS settings in \(path) are written in a form the app cannot edit safely. Set the domain by hand and re-check."
        case .unreadable(let path, let message):
            "\(path) could not be read: \(message)"
        case .notWritable(let path, let message):
            "\(path) could not be written: \(message)"
        }
    }
}

/// Edits the Apple Container `config.toml` in place.
///
/// The file belongs to the user, so nothing here needs administrator access.
/// It also holds settings the app knows nothing about — builder resources,
/// kernel URLs, registry defaults — so the edit is surgical: it rewrites the
/// one `domain` line under `[dns]` and copies every other byte through.
nonisolated struct ContainerConfigFile: ServiceDomainWriting {
    let url: URL

    init(url: URL) { self.url = url }

    func writeServiceDomain(_ domain: DNSDomainName) throws -> URL {
        let existing = try read()
        let updated = try ConfigTOML.settingServiceDomain(
            domain.rawValue,
            in: existing,
            path: url.path
        )
        guard updated != existing else { return url }
        try write(updated)
        return url
    }

    private func read() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigFileError.unreadable(path: url.path, message: error.localizedDescription)
        }
    }

    private func write(_ text: String) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic, so an interrupted write cannot leave a half-written
            // config behind for the CLI to read.
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigFileError.notWritable(path: url.path, message: error.localizedDescription)
        }
    }
}

/// The line-level TOML edit, kept separate from the file so it can be tested
/// against real config shapes without touching a disk.
nonisolated enum ConfigTOML {
    private static let tableHeader = #"^\s*\[\s*([^\[\]]+?)\s*\]\s*(#.*)?$"#
    private static let arrayOfTablesHeader = #"^\s*\[\[\s*([^\[\]]+?)\s*\]\]\s*(#.*)?$"#
    private static let domainKey = #"^\s*(domain|"domain"|'domain')\s*="#
    private static let dottedDomainKey = #"^\s*dns\s*\.\s*(domain|"domain"|'domain')\s*="#
    /// `dns = { … }` states the whole table on one line, which a line edit
    /// cannot change without rewriting the values beside it.
    private static let inlineDNS = #"^\s*(dns|"dns"|'dns')\s*="#

    static func settingServiceDomain(
        _ domain: String,
        in text: String,
        path: String
    ) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let assignment = "domain = \"\(domain)\""
        var table: String?
        var dnsHeaderIndex: Int?

        for (index, line) in lines.enumerated() {
            if let name = name(of: line, matching: arrayOfTablesHeader) {
                // `[[dns]]` would make the domain one entry of a list; the app
                // cannot tell which entry the user means.
                guard name != "dns" else { throw ConfigFileError.unsupportedLayout(path: path) }
                table = name
                continue
            }
            if let name = name(of: line, matching: tableHeader) {
                table = name
                if name == "dns", dnsHeaderIndex == nil { dnsHeaderIndex = index }
                continue
            }
            guard let table else {
                if matches(line, inlineDNS) { throw ConfigFileError.unsupportedLayout(path: path) }
                if matches(line, dottedDomainKey) {
                    lines[index] = "dns.\(assignment)"
                    return lines.joined(separator: "\n")
                }
                continue
            }
            if table == "dns", matches(line, domainKey) {
                lines[index] = assignment
                return lines.joined(separator: "\n")
            }
        }

        if let dnsHeaderIndex {
            lines.insert(assignment, at: dnsHeaderIndex + 1)
            return lines.joined(separator: "\n")
        }
        return appendingDNSTable(assignment, to: text)
    }

    private static func appendingDNSTable(_ assignment: String, to text: String) -> String {
        let table = "[dns]\n\(assignment)\n"
        guard !text.isEmpty else { return table }
        // One blank line before a new table, and never a second one.
        let separator = text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + separator + table
    }

    /// The table name a header line opens, so `[dns] # comment` and `[ "dns" ]`
    /// are recognised as the same table the CLI writes.
    private static func name(of line: String, matching pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
              ),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }
}
