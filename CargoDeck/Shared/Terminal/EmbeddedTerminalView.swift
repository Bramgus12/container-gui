import AppKit
import SwiftTerm
import SwiftUI

/// Bridges SwiftTerm's `TerminalView` to `PseudoTerminalSession`.
///
/// The two halves were already separately solved: the app has owned the POSIX
/// side for a while — `openpty`, raw mode, `POSIX_SPAWN_SETSID` so the child
/// gets a controlling terminal, and SIGWINCH on resize — and SwiftTerm owns the
/// VT parsing, screen buffer, rendering and key encoding. Neither knows about
/// the other, so this is the whole of the wiring: bytes out of the session into
/// the emulator, keystrokes out of the emulator into the session, and the
/// emulator's size into `resize(to:)` so the child sees a window change.
///
/// Used by the machine run sheet and by the privileged DNS commands. It knows
/// nothing about either: it renders whatever session it is handed.
struct EmbeddedTerminalView: NSViewRepresentable {
    let session: any InteractiveProcessSession
    /// Raised when the child exits, so the sheet can offer to close or rerun.
    let onExit: (Int32) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onExit: onExit)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        context.coordinator.start(feeding: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.onExit = onExit
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: any InteractiveProcessSession
        var onExit: (Int32) -> Void
        private var pump: Task<Void, Never>?
        private weak var view: TerminalView?
        /// The child is told the size once the view has actually been laid out;
        /// SwiftTerm reports 80×24 before that, which would make the shell wrap
        /// at the wrong column.
        private var hasReportedSize = false

        init(session: any InteractiveProcessSession, onExit: @escaping (Int32) -> Void) {
            self.session = session
            self.onExit = onExit
        }

        func start(feeding view: TerminalView) {
            self.view = view
            guard pump == nil else { return }
            pump = Task { [session] in
                do {
                    for try await event in session.events {
                        switch event {
                        case .standardOutput(let text), .standardError(let text):
                            view.feed(text: text)
                        case .terminated(let exitCode):
                            self.onExit(exitCode)
                            return
                        }
                    }
                } catch {
                    // The session's own error text is the only useful thing left
                    // to show, and the terminal is where the user is looking.
                    view.feed(text: "\r\n\(DiagnosticSanitizer.sanitize(error.localizedDescription))\r\n")
                    self.onExit(-1)
                }
            }
        }

        func stop() {
            pump?.cancel()
            pump = nil
            session.terminate()
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(String(decoding: data, as: UTF8.self))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard let size = try? TerminalSize(columns: newCols, rows: newRows) else { return }
            hasReportedSize = true
            session.resize(to: size)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// OSC 52 reads are denied. A process inside a machine asking to read the
        /// user's clipboard is not something the GUI should answer silently, and
        /// SwiftTerm's own default is the same refusal.
        func clipboardRead(source: TerminalView) -> Data? { nil }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
