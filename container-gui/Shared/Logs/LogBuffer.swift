import Foundation

nonisolated enum LogSeverity: Int, CaseIterable, Equatable, Sendable {
    case plain
    case warning
    case error

    static func classify(_ text: String) -> LogSeverity {
        let value = text.lowercased()
        if value.contains("error") || value.contains("fatal") || value.contains("failed") {
            return .error
        }
        if value.contains("warn") {
            return .warning
        }
        return .plain
    }
}

nonisolated enum LogFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case warning
    case error

    var id: Self { self }

    func includes(_ severity: LogSeverity) -> Bool {
        switch self {
        case .all: true
        case .warning: severity == .warning
        case .error: severity == .error
        }
    }
}

nonisolated struct LogCounts: Equatable, Sendable {
    let all: Int
    let warnings: Int
    let errors: Int
}

nonisolated struct LogSnapshot: Equatable, Sendable {
    let text: String
    let firstLogicalLineNumber: Int
    let logicalLineNumbers: [Int]
    let severities: [LogSeverity]

    init(
        text: String,
        firstLogicalLineNumber: Int,
        logicalLineNumbers: [Int]? = nil,
        severities: [LogSeverity]? = nil
    ) {
        self.text = text
        self.firstLogicalLineNumber = firstLogicalLineNumber
        let lines = Self.sourceLines(in: text)
        self.logicalLineNumbers = logicalLineNumbers
            ?? Array(firstLogicalLineNumber..<(firstLogicalLineNumber + lines.count))
        self.severities = severities ?? lines.map(LogSeverity.classify)
    }

    static let empty = LogSnapshot(text: "", firstLogicalLineNumber: 1)

    private static func sourceLines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}

/// A bounded collection of logical source lines. A line is created only when
/// source text arrives, so a trailing newline does not manufacture an extra
/// numbered line.
nonisolated struct LogBuffer: Sendable {
    private struct Line: Sendable {
        let number: Int
        var text: String
        var isTerminated: Bool

        var severity: LogSeverity { LogSeverity.classify(text) }

        var byteCount: Int {
            text.utf8.count + (isTerminated ? 1 : 0)
        }
    }

    private let maximumLines: Int
    private let maximumBytes: Int
    private var lines: [Line] = []
    private var firstLineIndex = 0
    private var storedByteCount = 0
    private(set) var nextLogicalLineNumber = 1

    init(maximumLines: Int = 5_000, maximumBytes: Int = 1_024 * 1_024) {
        self.maximumLines = max(1, maximumLines)
        self.maximumBytes = max(1, maximumBytes)
    }

    var snapshot: LogSnapshot { snapshot(filter: .all) }

    var counts: LogCounts {
        let visibleLines = lines[firstLineIndex...]
        return LogCounts(
            all: visibleLines.count,
            warnings: visibleLines.count { $0.severity == .warning },
            errors: visibleLines.count { $0.severity == .error }
        )
    }

    func snapshot(filter: LogFilter, matching query: String = "") -> LogSnapshot {
        let visibleLines = lines[firstLineIndex...]
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = ""
        text.reserveCapacity(storedByteCount)
        var numbers: [Int] = []
        var severities: [LogSeverity] = []
        for line in visibleLines where filter.includes(line.severity)
            && (query.isEmpty || line.text.localizedCaseInsensitiveContains(query)) {
            text.append(line.text)
            if line.isTerminated {
                text.append("\n")
            }
            numbers.append(line.number)
            severities.append(line.severity)
        }
        return LogSnapshot(
            text: text,
            firstLogicalLineNumber: numbers.first ?? nextLogicalLineNumber,
            logicalLineNumbers: numbers,
            severities: severities
        )
    }

    mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }

        var remainder = chunk[...]
        // TextKit renders every Unicode newline as a visual line break. Parse the
        // same set here so the logical line model and ruler cannot drift apart.
        // Swift treats CRLF as one Character, avoiding a phantom blank line.
        while let newline = remainder.firstIndex(where: \.isNewline) {
            appendText(remainder[..<newline])
            ensureOpenLine()
            lines[lines.count - 1].isTerminated = true
            storedByteCount += 1
            remainder = remainder[remainder.index(after: newline)...]
        }
        if !remainder.isEmpty {
            appendText(remainder)
        }
        enforceLimits()
    }

    /// Clears the current stream without reusing numbers already shown.
    mutating func clear() {
        lines.removeAll(keepingCapacity: true)
        firstLineIndex = 0
        storedByteCount = 0
    }

    /// Begins a new CLI stream session, whose numbering starts at one.
    mutating func startNewSession() {
        clear()
        nextLogicalLineNumber = 1
    }

    private mutating func appendText(_ text: Substring) {
        guard !text.isEmpty else { return }
        ensureOpenLine()
        lines[lines.count - 1].text.append(contentsOf: text)
        storedByteCount += text.utf8.count
    }

    private mutating func ensureOpenLine() {
        if let last = lines.last, !last.isTerminated {
            return
        }
        lines.append(Line(
            number: nextLogicalLineNumber,
            text: "",
            isTerminated: false
        ))
        nextLogicalLineNumber += 1
    }

    private mutating func enforceLimits() {
        while visibleLineCount > maximumLines {
            evictFirstLine()
        }
        while storedByteCount > maximumBytes, visibleLineCount > 1 {
            evictFirstLine()
        }
        if storedByteCount > maximumBytes, firstLineIndex < lines.count {
            trimFirstLineToByteLimit()
        }
        compactStorageIfNeeded()
    }

    private var visibleLineCount: Int {
        lines.count - firstLineIndex
    }

    private mutating func evictFirstLine() {
        storedByteCount -= lines[firstLineIndex].byteCount
        firstLineIndex += 1
    }

    private mutating func trimFirstLineToByteLimit() {
        let index = firstLineIndex
        let newlineBytes = lines[index].isTerminated ? 1 : 0
        let allowedTextBytes = max(0, maximumBytes - newlineBytes)
        let oldByteCount = lines[index].text.utf8.count
        guard oldByteCount > allowedTextBytes else { return }

        let data = Data(lines[index].text.utf8)
        var suffix = Data(data.suffix(allowedTextBytes))
        while let first = suffix.first, first & 0b1100_0000 == 0b1000_0000 {
            suffix.removeFirst()
        }
        lines[index].text = String(decoding: suffix, as: UTF8.self)
        storedByteCount -= oldByteCount - lines[index].text.utf8.count
    }

    private mutating func compactStorageIfNeeded() {
        guard firstLineIndex >= 1_024, firstLineIndex * 2 >= lines.count else { return }
        lines.removeFirst(firstLineIndex)
        firstLineIndex = 0
    }
}
