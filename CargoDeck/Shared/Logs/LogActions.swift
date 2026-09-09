import SwiftUI

struct LogJumpToLatestButton: View {
    let isAtLatest: Bool
    let action: () -> Void

    var body: some View {
        Button("Jump to Latest", action: action)
            .disabled(isAtLatest)
    }
}

struct LogCopyButton: View {
    let hasLogs: Bool
    let action: () -> Void

    var body: some View {
        Button("Copy", action: action)
            .disabled(!hasLogs)
    }
}
