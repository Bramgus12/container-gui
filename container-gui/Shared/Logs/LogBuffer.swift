import Foundation

nonisolated struct LogSnapshot: Equatable, Sendable {
    let text: String
    let firstLogicalLineNumber: Int

    static let empty = LogSnapshot(text: "", firstLogicalLineNumber: 1)
}

/// A bounded collection of logical source lines. A line is created only when
/// source text arrives, so a trailing newline does not manufacture an extra
/// numbered line.
nonisolated struct LogBuffer: Sendable {
    private struct Line: Sendable {
        let number: Int
        var text: String
        var isTerminated: Bool

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

    var snapshot: LogSnapshot {
        let visibleLines = lines[firstLineIndex...]
        var text = ""
        text.reserveCapacity(storedByteCount)
        for line in visibleLines {
            text.append(line.text)
            if line.isTerminated {
                text.append("\n")
            }
        }
        return LogSnapshot(
            text: text,
            firstLogicalLineNumber: visibleLines.first?.number ?? nextLogicalLineNumber
        )
    }

    mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }

        var remainder = chunk[...]
        while let newline = remainder.firstIndex(of: "\n") {
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
