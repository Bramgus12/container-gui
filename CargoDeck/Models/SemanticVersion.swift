import Foundation

nonisolated struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ value: String) throws {
        // `split` drops empty subsequences, so values such as "", "-", and "+"
        // yield no elements at all. Take the first element defensively rather
        // than subscripting, which traps on those inputs.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = (trimmed.split(separator: "-", maxSplits: 1).first ?? "")
            .split(separator: "+", maxSplits: 1).first ?? ""
        let components = core.split(separator: ".", omittingEmptySubsequences: false)

        guard (2...3).contains(components.count),
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = components.count == 3 ? Int(components[2]) : 0,
              major >= 0, minor >= 0, patch >= 0
        else {
            throw SemanticVersionError.invalid(value)
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

nonisolated enum SemanticVersionError: Error, Equatable, Sendable {
    case invalid(String)
}
