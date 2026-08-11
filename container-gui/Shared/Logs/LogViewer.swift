import AppKit
import SwiftUI

struct LogLineMap: Equatable {
    let firstLogicalLineNumber: Int
    let characterIndexes: [Int]

    init(snapshot: LogSnapshot) {
        firstLogicalLineNumber = snapshot.firstLogicalLineNumber
        guard !snapshot.text.isEmpty else {
            characterIndexes = []
            return
        }

        let text = snapshot.text as NSString
        var indexes = [0]
        for index in 0..<text.length where text.character(at: index) == 0x0A {
            let nextIndex = index + 1
            if nextIndex < text.length {
                indexes.append(nextIndex)
            }
        }
        characterIndexes = indexes
    }

    var lastLogicalLineNumber: Int {
        firstLogicalLineNumber + max(0, characterIndexes.count - 1)
    }

    func lineNumber(atCharacterIndex index: Int) -> Int? {
        guard let offset = characterIndexes.firstIndex(of: index) else { return nil }
        return firstLogicalLineNumber + offset
    }
}

struct LogTextUpdate: Equatable {
    let removedPrefixLength: Int
    let insertedRange: NSRange?
}

enum LogTextStorageUpdater {
    static func update(
        _ textStorage: NSTextStorage,
        from oldSnapshot: LogSnapshot,
        to newSnapshot: LogSnapshot
    ) -> LogTextUpdate {
        let oldText = textStorage.string
        let newText = newSnapshot.text
        guard oldText != newText else {
            return LogTextUpdate(removedPrefixLength: 0, insertedRange: nil)
        }

        if newText.hasPrefix(oldText) {
            let insertedText = String(newText.dropFirst(oldText.count))
            let range = NSRange(location: (oldText as NSString).length, length: 0)
            textStorage.replaceCharacters(in: range, with: insertedText)
            return LogTextUpdate(
                removedPrefixLength: 0,
                insertedRange: NSRange(
                    location: range.location,
                    length: (insertedText as NSString).length
                )
            )
        }

        if oldText.hasPrefix(newText) {
            let newLength = (newText as NSString).length
            textStorage.deleteCharacters(in: NSRange(
                location: newLength,
                length: textStorage.length - newLength
            ))
            return LogTextUpdate(removedPrefixLength: 0, insertedRange: nil)
        }

        let removedLineCount = newSnapshot.firstLogicalLineNumber
            - oldSnapshot.firstLogicalLineNumber
        if removedLineCount > 0,
           let prefixLength = prefixLength(
               containingLogicalLines: removedLineCount,
               in: oldText
           ) {
            let remainingText = String(oldText.dropFirstUTF16(prefixLength))
            if newText.hasPrefix(remainingText) {
                textStorage.deleteCharacters(in: NSRange(location: 0, length: prefixLength))
                let appendedText = String(newText.dropFirst(remainingText.count))
                let appendLocation = textStorage.length
                if !appendedText.isEmpty {
                    textStorage.replaceCharacters(
                        in: NSRange(location: appendLocation, length: 0),
                        with: appendedText
                    )
                }
                return LogTextUpdate(
                    removedPrefixLength: prefixLength,
                    insertedRange: appendedText.isEmpty ? nil : NSRange(
                        location: appendLocation,
                        length: (appendedText as NSString).length
                    )
                )
            }
        }

        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length),
            with: newText
        )
        return LogTextUpdate(
            removedPrefixLength: (oldText as NSString).length,
            insertedRange: newText.isEmpty ? nil : NSRange(
                location: 0,
                length: (newText as NSString).length
            )
        )
    }

    private static func prefixLength(
        containingLogicalLines lineCount: Int,
        in text: String
    ) -> Int? {
        let text = text as NSString
        var remaining = lineCount
        for index in 0..<text.length where text.character(at: index) == 0x0A {
            remaining -= 1
            if remaining == 0 {
                return index + 1
            }
        }
        return nil
    }
}

private extension String {
    func dropFirstUTF16(_ count: Int) -> Substring {
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: count)
        let index = String.Index(utf16Index, within: self) ?? endIndex
        return self[index...]
    }
}

@MainActor
struct LogViewer: NSViewRepresentable {
    let snapshot: LogSnapshot
    let jumpToLatestRequest: Int
    let onTailingChange: (Bool) -> Void

    func makeCoordinator() -> LogScrollView {
        LogScrollView(frame: .zero)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        controller.onTailingChange = onTailingChange
        controller.update(
            snapshot: snapshot,
            jumpToLatestRequest: jumpToLatestRequest
        )
        controller.didAttachToSwiftUI()
        return controller.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let controller = context.coordinator
        controller.onTailingChange = onTailingChange
        controller.update(
            snapshot: snapshot,
            jumpToLatestRequest: jumpToLatestRequest
        )
    }
}

@MainActor
final class LogClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        constrainedBounds.origin.x = 0
        return constrainedBounds
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }
}

@MainActor
final class LogScrollView: NSObject {
    private struct ViewportAnchor {
        var characterIndex: Int
        let lineOffsetFromViewportTop: CGFloat
    }

    let scrollView: NSScrollView
    let logTextView: NSTextView
    private var lineNumberRuler: LogLineNumberRuler!
    private var snapshot = LogSnapshot.empty
    private var lastJumpRequest = 0
    private(set) var isTailing = true
    private var isConfigured = false
    private var isTiling = false
    private var isSettingFrame = false
    private var isUpdatingContent = false
    private var scrollObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    var onTailingChange: ((Bool) -> Void)?

    var contentView: NSClipView { scrollView.contentView }
    var contentSize: NSSize { scrollView.contentSize }
    var hasHorizontalScroller: Bool { scrollView.hasHorizontalScroller }
    var hasVerticalScroller: Bool { scrollView.hasVerticalScroller }
    var hasVerticalRuler: Bool { scrollView.hasVerticalRuler }
    var drawsBackground: Bool { scrollView.drawsBackground }

    init(frame frameRect: NSRect) {
        scrollView = NSScrollView(frame: frameRect)
        scrollView.contentView = LogClipView(frame: frameRect)
        logTextView = NSTextView(usingTextLayoutManager: false)
        logTextView.frame = NSRect(origin: .zero, size: frameRect.size)
        scrollView.documentView = logTextView
        super.init()
        scrollView.clipsToBounds = true
        lineNumberRuler = LogLineNumberRuler(
            scrollView: scrollView,
            textView: logTextView
        )
        configure()
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
    }

    var frame: NSRect {
        get { scrollView.frame }
        set {
            let wasTailing = isTailing
            isSettingFrame = true
            scrollView.frame = newValue
            isSettingFrame = false
            tile()
            if wasTailing {
                scrollToLatest()
            }
        }
    }
    var bounds: NSRect { scrollView.bounds }
    var appearance: NSAppearance? {
        get { scrollView.appearance }
        set { scrollView.appearance = newValue }
    }

    func setFrameSize(_ size: NSSize) {
        let wasTailing = isTailing
        isSettingFrame = true
        scrollView.setFrameSize(size)
        isSettingFrame = false
        tile()
        if wasTailing {
            scrollToLatest()
        }
    }

    func layoutSubtreeIfNeeded() {
        scrollView.layoutSubtreeIfNeeded()
        tile()
    }

    func displayIfNeeded() {
        scrollView.displayIfNeeded()
    }

    func bitmapImageRepForCachingDisplay(in rect: NSRect) -> NSBitmapImageRep? {
        scrollView.bitmapImageRepForCachingDisplay(in: rect)
    }

    func cacheDisplay(in rect: NSRect, to bitmap: NSBitmapImageRep) {
        scrollView.cacheDisplay(in: rect, to: bitmap)
    }

    func viewDidChangeEffectiveAppearance() {
        guard isConfigured else { return }
        applyEffectiveAppearance()
    }

    func didAttachToSwiftUI() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyEffectiveAppearance()
            self.scrollView.layoutSubtreeIfNeeded()
            self.tile()
            self.invalidateDocumentDisplay()
        }
    }

    func tile() {
        guard isConfigured, !isTiling else {
            scrollView.tile()
            return
        }

        let shouldRemainAtLatest = isTailing
        let anchor = shouldRemainAtLatest ? nil : captureViewportAnchor()
        isTiling = true
        isUpdatingContent = true
        scrollView.tile()
        resetHorizontalOrigin()
        layoutDocumentView()
        if shouldRemainAtLatest {
            scrollToLatest()
        } else if let anchor {
            restoreViewport(anchor)
        } else {
            clampViewportToDocument()
        }
        lineNumberRuler.needsDisplay = true
        isUpdatingContent = false
        isTiling = false
    }

    func update(snapshot newSnapshot: LogSnapshot, jumpToLatestRequest: Int) {
        let shouldJump = jumpToLatestRequest != lastJumpRequest
        lastJumpRequest = jumpToLatestRequest
        let shouldTailAfterUpdate = isTailing || shouldJump
        if shouldJump {
            setTailing(true)
        }

        isUpdatingContent = true
        defer { isUpdatingContent = false }
        var anchor = shouldTailAfterUpdate ? nil : captureViewportAnchor()
        let selectedRanges = logTextView.selectedRanges
        let update = LogTextStorageUpdater.update(
            logTextView.textStorage!,
            from: snapshot,
            to: newSnapshot
        )
        applyTextAttributes(to: update.insertedRange)
        restoreSelection(selectedRanges, afterRemovingPrefix: update.removedPrefixLength)
        if var currentAnchor = anchor {
            currentAnchor.characterIndex = max(
                0,
                currentAnchor.characterIndex - update.removedPrefixLength
            )
            anchor = currentAnchor
        }
        snapshot = newSnapshot
        lineNumberRuler.lineMap = LogLineMap(snapshot: newSnapshot)
        applyParagraphStyle()
        lineNumberRuler.needsDisplay = true

        scrollView.tile()
        resetHorizontalOrigin()
        layoutDocumentView()
        if shouldTailAfterUpdate {
            scrollToLatest()
        } else if let anchor {
            restoreViewport(anchor)
        } else {
            clampViewportToDocument()
        }
    }

    func invalidateDocumentDisplay() {
        guard layoutDocumentView() else { return }
        logTextView.setNeedsDisplay(logTextView.bounds)
        lineNumberRuler.needsDisplay = true
    }

    private func configure() {
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.isRichText = false
        logTextView.importsGraphics = false
        logTextView.drawsBackground = true
        logTextView.allowsUndo = false
        logTextView.usesFindBar = true
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.minSize = .zero
        logTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        logTextView.textContainerInset = NSSize(width: 8, height: 8)
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.textContainer?.heightTracksTextView = false
        logTextView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        logTextView.textContainer?.lineFragmentPadding = 0
        logTextView.setAccessibilityIdentifier("logs.viewer")

        contentView.drawsBackground = false
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrollPositionDidChange()
            }
        }
        scrollView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSettingFrame else { return }
                self.tile()
            }
        }
        isConfigured = true
        applyEffectiveAppearance()
        scrollView.needsLayout = true
    }

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.firstLineHeadIndent = lineNumberRuler.ruleThickness
        style.headIndent = lineNumberRuler.ruleThickness
        return style
    }

    private func applyParagraphStyle() {
        guard let textStorage = logTextView.textStorage, textStorage.length > 0 else {
            return
        }
        textStorage.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: textStorage.length)
        )
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        return [
            .font: NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize(for: .small),
                weight: .regular
            ),
            .foregroundColor: effectiveColors.foreground,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func applyEffectiveAppearance() {
        let colors = effectiveColors
        let background = colors.background
        scrollView.backgroundColor = background
        contentView.backgroundColor = .clear
        logTextView.backgroundColor = background
        logTextView.textColor = colors.foreground
        if let textStorage = logTextView.textStorage, textStorage.length > 0 {
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.foreground,
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        lineNumberRuler.needsDisplay = true
        scrollView.needsDisplay = true
    }

    private var effectiveColors: (foreground: NSColor, background: NSColor) {
        var foreground = NSColor.textColor
        var background = NSColor.textBackgroundColor
        scrollView.effectiveAppearance.performAsCurrentDrawingAppearance {
            foreground = NSColor.textColor.usingColorSpace(.deviceRGB) ?? .textColor
            background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)
                ?? .textBackgroundColor
        }
        return (foreground, background)
    }

    private func applyTextAttributes(to range: NSRange?) {
        guard let range, range.length > 0 else { return }
        logTextView.textStorage?.addAttributes(textAttributes, range: range)
    }

    private func restoreSelection(_ ranges: [NSValue], afterRemovingPrefix length: Int) {
        let textLength = logTextView.textStorage?.length ?? 0
        let adjusted = ranges.map { value -> NSValue in
            let range = value.rangeValue
            let oldEnd = range.location + range.length
            let location = min(textLength, max(0, range.location - length))
            let end = min(textLength, max(location, oldEnd - length))
            return NSValue(range: NSRange(location: location, length: end - location))
        }
        logTextView.setSelectedRanges(adjusted, affinity: .downstream, stillSelecting: false)
    }

    @discardableResult
    private func layoutDocumentView() -> Bool {
        resetHorizontalOrigin()
        let viewportSize = contentView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0,
              let layoutManager = logTextView.layoutManager,
              let textContainer = logTextView.textContainer
        else { return false }

        let width = viewportSize.width
        let containerWidth = max(0, width - (logTextView.textContainerInset.width * 2))
        logTextView.setFrameSize(NSSize(
            width: width,
            height: max(viewportSize.height, logTextView.frame.height)
        ))
        textContainer.containerSize = NSSize(
            width: containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: logTextView.textStorage?.length ?? 0),
            actualCharacterRange: nil
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let height = max(
            viewportSize.height,
            ceil(usedRect.maxY + (logTextView.textContainerInset.height * 2))
        )
        logTextView.setFrameSize(NSSize(width: width, height: height))
        // The representable is commonly populated while its bounds are still
        // zero. NSTextStorage then invalidates an empty drawing region, and
        // AppKit will happily display the later ruler update without ever
        // repainting the glyphs. Always invalidate the document after it has a
        // real viewport and its wrapping geometry is final.
        layoutManager.invalidateDisplay(
            forCharacterRange: NSRange(
                location: 0,
                length: logTextView.textStorage?.length ?? 0
            )
        )
        logTextView.needsDisplay = true
        resetHorizontalOrigin()
        return true
    }

    private func resetHorizontalOrigin() {
        guard contentView.bounds.origin.x != 0 else { return }
        contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(contentView)
    }

    private func captureViewportAnchor() -> ViewportAnchor? {
        guard !snapshot.text.isEmpty,
              let layoutManager = logTextView.layoutManager,
              let textContainer = logTextView.textContainer,
              layoutManager.numberOfGlyphs > 0
        else { return nil }

        layoutManager.ensureLayout(for: textContainer)
        let visibleTop = logTextView.visibleRect.minY
        let containerPoint = NSPoint(
            x: 0,
            y: max(0, visibleTop - logTextView.textContainerOrigin.y)
        )
        let glyphIndex = min(
            layoutManager.numberOfGlyphs - 1,
            layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        )
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil
        )
        let lineY = lineRect.minY + logTextView.textContainerOrigin.y
        return ViewportAnchor(
            characterIndex: characterIndex,
            lineOffsetFromViewportTop: lineY - visibleTop
        )
    }

    private func restoreViewport(_ anchor: ViewportAnchor) {
        guard let layoutManager = logTextView.layoutManager,
              let textContainer = logTextView.textContainer,
              layoutManager.numberOfGlyphs > 0
        else {
            clampViewportToDocument()
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let maximumCharacterIndex = max(0, (logTextView.textStorage?.length ?? 1) - 1)
        let characterIndex = min(anchor.characterIndex, maximumCharacterIndex)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        let glyphIndex = min(glyphRange.location, layoutManager.numberOfGlyphs - 1)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil
        )
        let lineY = lineRect.minY + logTextView.textContainerOrigin.y
        scrollVertically(to: lineY - anchor.lineOffsetFromViewportTop)
    }

    private func clampViewportToDocument() {
        scrollVertically(to: contentView.bounds.origin.y)
    }

    private func scrollVertically(to proposedY: CGFloat) {
        let maximumY = max(0, logTextView.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(maximumY, max(0, proposedY))))
        scrollView.reflectScrolledClipView(contentView)
    }

    private func scrollPositionDidChange() {
        guard !isUpdatingContent else { return }
        // AppKit can reset the clip-view origin just before it tiles a resized
        // scroll view. Evaluate on the next run-loop turn so that transient
        // layout movement is not mistaken for the user scrolling away.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isUpdatingContent else { return }
            if self.scrollView.inLiveResize, self.isTailing {
                self.scrollToLatest()
                return
            }
            let maximumY = max(
                0,
                self.logTextView.frame.height - self.contentView.bounds.height
            )
            let atLatest = self.contentView.bounds.origin.y >= maximumY - 2
            self.setTailing(atLatest)
        }
    }

    private func scrollToLatest() {
        guard layoutDocumentView() else { return }
        let maximumY = max(0, logTextView.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(contentView)
        setTailing(true)
    }

    private func setTailing(_ value: Bool) {
        guard value != isTailing else { return }
        isTailing = value
        onTailingChange?(value)
    }
}

@MainActor
final class LogLineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var lineMap = LogLineMap(snapshot: .empty) {
        didSet {
            let digits = max(3, String(lineMap.lastLogicalLineNumber).count)
            ruleThickness = CGFloat(digits * 8 + 18)
        }
    }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(
            scrollView: scrollView,
            orientation: .verticalRuler
        )
        clientView = textView
        ruleThickness = 42
        setAccessibilityElement(true)
        setAccessibilityLabel(String(localized: "Line numbers"))
        setAccessibilityIdentifier("logs.lineNumbers")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              !lineMap.characterIndexes.isEmpty
        else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] _, usedRect, _, fragmentGlyphRange, _ in
            guard let self, fragmentGlyphRange.location < layoutManager.numberOfGlyphs else {
                return
            }
            let characterIndex = layoutManager.characterIndexForGlyph(
                at: fragmentGlyphRange.location
            )
            guard let number = self.lineMap.lineNumber(atCharacterIndex: characterIndex) else {
                return
            }

            let string = String(number) as NSString
            let size = string.size(withAttributes: attributes)
            let textOrigin = textView.textContainerOrigin
            let pointInTextView = NSPoint(
                x: 0,
                y: usedRect.minY + textOrigin.y
            )
            let point = self.convert(pointInTextView, from: textView)
            string.draw(
                at: NSPoint(
                    x: self.ruleThickness - size.width - 8,
                    y: point.y
                ),
                withAttributes: attributes
            )
        }
    }
}
