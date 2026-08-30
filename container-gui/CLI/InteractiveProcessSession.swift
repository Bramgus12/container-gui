import Foundation
import Darwin

/// The size of the terminal handed to a child process. Requesting a size is what
/// makes a session allocate a pseudo-terminal; without one the child gets plain
/// pipes.
nonisolated struct TerminalSize: Equatable, Sendable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) throws {
        guard (1...9_999).contains(columns) else {
            throw CommandValidationError.outOfRange(field: "Terminal columns", value: columns)
        }
        guard (1...9_999).contains(rows) else {
            throw CommandValidationError.outOfRange(field: "Terminal rows", value: rows)
        }
        self.columns = columns
        self.rows = rows
    }

    private init(uncheckedColumns columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    static let `default` = TerminalSize(uncheckedColumns: 80, rows: 24)

    fileprivate var winsize: Darwin.winsize {
        Darwin.winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
    }
}

/// A running child process whose standard input stays open. `stream(_:)` covers
/// the fire-and-forget case; this covers `exec`, where the user types after the
/// process has started.
nonisolated protocol InteractiveProcessSession: Sendable {
    var events: AsyncThrowingStream<ProcessEvent, Error> { get }

    /// Writes UTF-8 bytes to the child's standard input.
    func send(_ text: String)

    /// Signals end of input: Ctrl-D on a terminal, closing the pipe otherwise.
    func sendEndOfFile()

    /// No-op for sessions without a terminal.
    func resize(to size: TerminalSize)

    func terminate()
}

nonisolated struct InteractiveSessionRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let terminalSize: TerminalSize?
}

// MARK: - Pseudo-terminal

/// Runs the child behind a pseudo-terminal so that `container exec --tty` sees a
/// real TTY. The local side is put in raw mode: the terminal inside the
/// container does the echoing, and doubling it here would show every keystroke
/// twice.
nonisolated final class PseudoTerminalSession: InteractiveProcessSession, @unchecked Sendable {
    let events: AsyncThrowingStream<ProcessEvent, Error>

    private let queue = DispatchQueue(label: "PseudoTerminalSession")
    private let continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation
    private let lock = NSLock()
    private var masterDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var processIdentifier: pid_t = -1
    private var isFinished = false
    /// The tail of a UTF-8 sequence the last read cut in half.
    private var carriedBytes: [UInt8] = []

    init(request: InteractiveSessionRequest, size: TerminalSize) throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ProcessEvent.self,
            throwing: Error.self
        )
        events = stream
        self.continuation = continuation

        var master: Int32 = -1
        var slave: Int32 = -1
        var terminal = Self.rawTerminalSettings()
        var windowSize = size.winsize
        guard openpty(&master, &slave, nil, &terminal, &windowSize) == 0 else {
            let message = String(cString: strerror(errno))
            continuation.finish(throwing: CLIError.launchFailed(message: message))
            throw CLIError.launchFailed(message: "A pseudo-terminal could not be opened: \(message)")
        }
        masterDescriptor = master

        guard let slaveName = ttyname(slave) else {
            close(master)
            close(slave)
            masterDescriptor = -1
            let failure = CLIError.launchFailed(message: "The pseudo-terminal has no device name.")
            continuation.finish(throwing: failure)
            throw failure
        }
        let slavePath = String(cString: slaveName)

        // The raw mode and window size openpty applied last only as long as the
        // device stays open: closing the final slave descriptor resets the line
        // discipline, so a child opening the device afterwards would find a 0x0
        // terminal with echo switched back on. The parent holds the slave open
        // across the spawn for that reason, and closes it immediately after —
        // holding it any longer would stop the master from ever reporting the
        // end of the session.
        do {
            processIdentifier = try Self.spawn(
                request: request,
                slavePath: slavePath,
                slaveDescriptor: slave,
                masterDescriptor: master
            )
            close(slave)
        } catch {
            close(slave)
            close(master)
            masterDescriptor = -1
            continuation.finish(throwing: error)
            throw error
        }

        startReading(from: master)
        watchForExit(of: processIdentifier)
        continuation.onTermination = { [weak self] _ in
            self?.terminate()
        }
    }

    /// `Process` cannot start a new session, and without one the child has no
    /// controlling terminal: it would never receive SIGWINCH on a resize, and
    /// Ctrl-C would not raise SIGINT. Spawning directly with
    /// `POSIX_SPAWN_SETSID`, then opening the terminal device as the child's
    /// first descriptor, makes it the session leader and adopts that device as
    /// its controlling terminal.
    private static func spawn(
        request: InteractiveSessionRequest,
        slavePath: String,
        slaveDescriptor: Int32,
        masterDescriptor: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_addclose(&fileActions, masterDescriptor)
        // The child opens the device by name; the parent's descriptor for it is
        // only being kept alive to preserve the terminal settings.
        posix_spawn_file_actions_addclose(&fileActions, slaveDescriptor)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // An ignored or blocked signal is inherited across exec. The app cannot
        // assume its own disposition for SIGTERM is the default one, and a child
        // that inherited SIG_IGN would survive every attempt to terminate it, so
        // the child starts from a clean slate.
        var defaultedSignals = sigset_t()
        sigfillset(&defaultedSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultedSignals)
        var unblockedSignals = sigset_t()
        sigemptyset(&unblockedSignals)
        posix_spawnattr_setsigmask(&attributes, &unblockedSignals)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID)
                | Int16(POSIX_SPAWN_SETSIGDEF)
                | Int16(POSIX_SPAWN_SETSIGMASK)
        )

        let executablePath = request.executableURL.path
        let environment = request.environment.merging(["TERM": "xterm-256color"]) { _, new in new }
        let argumentStrings = [executablePath] + request.arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }

        var argv = argumentStrings.map { strdup($0) }
        argv.append(nil)
        var envp = environmentStrings.map { strdup($0) }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var identifier: pid_t = -1
        let status = posix_spawn(&identifier, executablePath, &fileActions, &attributes, argv, envp)
        guard status == 0 else {
            throw CLIError.launchFailed(message: String(cString: strerror(status)))
        }
        return identifier
    }

    private static func rawTerminalSettings() -> termios {
        var settings = termios()
        cfmakeraw(&settings)
        return settings
    }

    private func watchForExit(of identifier: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: identifier,
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(identifier, &status, 0)
            self.finish(exitCode: Self.exitCode(from: status))
        }
        lock.withLock { exitSource = source }
        source.resume()
    }

    /// Mirrors the shell convention `Process.terminationStatus` uses: a signal
    /// becomes 128 plus the signal number.
    private static func exitCode(from status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7F
        if terminatingSignal == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + terminatingSignal
    }

    private func startReading(from descriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let text = self.decode(buffer[0..<count])
                if !text.isEmpty {
                    self.continuation.yield(.standardOutput(text))
                }
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                // A closed pseudo-terminal reports EIO rather than end of file.
                // The exit code arrives separately through the termination
                // handler, so reading simply stops here.
                self.stopReading()
            }
        }
        lock.withLock { readSource = source }
        source.resume()
    }

    /// Reads land on arbitrary byte boundaries, so a multi-byte character can be
    /// split between two of them. Decoding each read on its own would turn every
    /// such character into U+FFFD — visible as soon as anything draws a box or
    /// prints an accent. The incomplete tail is held back and prefixed onto the
    /// next read instead.
    ///
    /// Only a *trailing* truncated sequence is deferred. Invalid bytes anywhere
    /// else still decode to U+FFFD, which is what a terminal should show for
    /// genuinely malformed output rather than swallowing it.
    private func decode(_ bytes: ArraySlice<UInt8>) -> String {
        var pending = lock.withLock {
            let carried = carriedBytes
            carriedBytes = []
            return carried
        }
        pending.append(contentsOf: bytes)

        let tail = Self.incompleteSuffixLength(of: pending)
        guard tail > 0 else { return String(decoding: pending, as: UTF8.self) }

        let split = pending.count - tail
        lock.withLock { carriedBytes = Array(pending[split...]) }
        return String(decoding: pending[..<split], as: UTF8.self)
    }

    /// The number of trailing bytes that begin a UTF-8 sequence the read did not
    /// finish delivering, or zero when the buffer ends on a character boundary.
    static func incompleteSuffixLength(of bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        // A sequence is at most four bytes, so only the last three can be the
        // start of a truncated one.
        for offset in 1...min(3, bytes.count) {
            let byte = bytes[bytes.count - offset]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continue // A continuation byte: keep walking back to the leader.
            }
            let expected: Int
            switch byte {
            case 0x00...0x7F: expected = 1
            case 0xC0...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF7: expected = 4
            default: return 0 // Not a valid leader — let the decoder mark it.
            }
            return expected > offset ? offset : 0
        }
        return 0
    }

    private func stopReading() {
        let source = lock.withLock {
            let source = readSource
            readSource = nil
            return source
        }
        source?.cancel()
    }

    private func finish(exitCode: Int32) {
        // The terminal may still hold buffered output the read source has not
        // delivered; draining on the same queue keeps it ahead of the exit
        // event.
        queue.async { [weak self] in
            guard let self else { return }
            let shouldFinish = self.lock.withLock {
                guard !self.isFinished else { return false }
                self.isFinished = true
                return true
            }
            guard shouldFinish else { return }

            self.drainRemainingOutput()
            self.stopReading()
            self.closeMaster()
            self.continuation.yield(.terminated(exitCode: exitCode))
            self.continuation.finish()
        }
    }

    private func drainRemainingOutput() {
        let descriptor = lock.withLock { masterDescriptor }
        guard descriptor >= 0 else { return }

        var flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            let text = decode(buffer[0..<count])
            if !text.isEmpty {
                continuation.yield(.standardOutput(text))
            }
        }
        // Nothing more is coming, so a sequence still held back was genuinely
        // truncated by the child. Emit it rather than dropping output.
        let remainder = lock.withLock {
            let carried = carriedBytes
            carriedBytes = []
            return carried
        }
        if !remainder.isEmpty {
            continuation.yield(.standardOutput(String(decoding: remainder, as: UTF8.self)))
        }
        if flags >= 0 {
            flags = fcntl(descriptor, F_SETFL, flags)
        }
    }

    private func closeMaster() {
        let descriptor = lock.withLock {
            let descriptor = masterDescriptor
            masterDescriptor = -1
            return descriptor
        }
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let descriptor = self.lock.withLock { self.masterDescriptor }
            guard descriptor >= 0 else { return }
            bytes.withUnsafeBufferPointer { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && (errno == EINTR || errno == EAGAIN) {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    func sendEndOfFile() {
        send("\u{4}")
    }

    func resize(to size: TerminalSize) {
        queue.async { [weak self] in
            guard let self else { return }
            let descriptor = self.lock.withLock { self.masterDescriptor }
            guard descriptor >= 0 else { return }
            var windowSize = size.winsize
            _ = ioctl(descriptor, TIOCSWINSZ, &windowSize)
        }
    }

    /// Signals the whole process group. The child is a session leader, so its
    /// own children — the shell's foreground job, typically — are signalled too
    /// rather than being left behind holding the terminal open.
    func terminate() {
        let identifier = lock.withLock { processIdentifier }
        guard identifier > 0 else { return }
        if killpg(identifier, SIGTERM) != 0 {
            kill(identifier, SIGTERM)
        }
    }
}

// MARK: - Pipes

/// Standard input stays open through a pipe, without a terminal. Used for
/// `exec --interactive` without `--tty`, where standard output and standard
/// error remain separate streams.
nonisolated final class PipeInteractiveSession: InteractiveProcessSession, @unchecked Sendable {
    let events: AsyncThrowingStream<ProcessEvent, Error>

    private let process = Process()
    private let standardInput = Pipe()
    private let queue = DispatchQueue(label: "PipeInteractiveSession")
    private let continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation
    private let lock = NSLock()
    private var inputIsClosed = false

    init(request: InteractiveSessionRequest) throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ProcessEvent.self,
            throwing: Error.self
        )
        events = stream
        self.continuation = continuation

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            continuation.yield(.standardOutput(String(decoding: data, as: UTF8.self)))
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            continuation.yield(.standardError(String(decoding: data, as: UTF8.self)))
        }

        process.terminationHandler = { [weak self] process in
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            if let remaining = try? standardOutput.fileHandleForReading.readToEnd(),
               !remaining.isEmpty {
                continuation.yield(.standardOutput(String(decoding: remaining, as: UTF8.self)))
            }
            if let remaining = try? standardError.fileHandleForReading.readToEnd(),
               !remaining.isEmpty {
                continuation.yield(.standardError(String(decoding: remaining, as: UTF8.self)))
            }
            self?.closeInput()
            continuation.yield(.terminated(exitCode: process.terminationStatus))
            continuation.finish()
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            let failure = CLIError.launchFailed(message: error.localizedDescription)
            continuation.finish(throwing: failure)
            throw failure
        }

        continuation.onTermination = { [weak self] _ in
            self?.terminate()
        }
    }

    func send(_ text: String) {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.lock.withLock({ self.inputIsClosed }) else { return }
            try? self.standardInput.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func sendEndOfFile() {
        queue.async { [weak self] in
            self?.closeInput()
        }
    }

    func resize(to size: TerminalSize) {
        // No terminal to resize.
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func closeInput() {
        let shouldClose = lock.withLock {
            guard !inputIsClosed else { return false }
            inputIsClosed = true
            return true
        }
        guard shouldClose else { return }
        try? standardInput.fileHandleForWriting.close()
    }
}
