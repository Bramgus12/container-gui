import AppKit
import XCTest
@testable import Container_GUI

final class ContainerLogBufferTests: XCTestCase {
    func testChunkSplitLinesKeepOneLogicalNumber() {
        var buffer = ContainerLogBuffer()

        buffer.append("hel")
        buffer.append("lo\nwor")
        buffer.append("ld")

        XCTAssertEqual(buffer.snapshot, ContainerLogSnapshot(
            text: "hello\nworld",
            firstLogicalLineNumber: 1
        ))
        XCTAssertEqual(
            ContainerLogLineMap(snapshot: buffer.snapshot).characterIndexes,
            [0, 6]
        )
    }

    func testBlankLinesAndTrailingNewlineHaveNoPhantomLine() {
        var buffer = ContainerLogBuffer()
        buffer.append("\n\nlast\n")

        XCTAssertEqual(buffer.snapshot.text, "\n\nlast\n")
        let lineMap = ContainerLogLineMap(snapshot: buffer.snapshot)
        XCTAssertEqual(lineMap.characterIndexes, [0, 1, 2])
        XCTAssertEqual(lineMap.lineNumber(atCharacterIndex: 0), 1)
        XCTAssertEqual(lineMap.lineNumber(atCharacterIndex: 1), 2)
        XCTAssertEqual(lineMap.lineNumber(atCharacterIndex: 2), 3)
        XCTAssertNil(lineMap.lineNumber(atCharacterIndex: 7))
    }

    func testLineLimitEvictionAdvancesFirstNumberMonotonically() {
        var buffer = ContainerLogBuffer(maximumLines: 3, maximumBytes: 1_024)
        buffer.append("one\ntwo\nthree\nfour\n")

        XCTAssertEqual(buffer.snapshot, ContainerLogSnapshot(
            text: "two\nthree\nfour\n",
            firstLogicalLineNumber: 2
        ))

        buffer.append("five\n")
        XCTAssertEqual(buffer.snapshot.firstLogicalLineNumber, 3)
        XCTAssertEqual(buffer.snapshot.text, "three\nfour\nfive\n")
    }

    func testUTF8ByteLimitTrimsOnlyAtAValidScalarBoundary() {
        var buffer = ContainerLogBuffer(maximumLines: 10, maximumBytes: 4)
        buffer.append("abc😀")

        XCTAssertEqual(buffer.snapshot.text, "😀")
        XCTAssertLessThanOrEqual(buffer.snapshot.text.utf8.count, 4)
        XCTAssertEqual(buffer.snapshot.firstLogicalLineNumber, 1)
    }

    func testByteLimitEvictsWholeOlderLinesAndAdvancesNumber() {
        var buffer = ContainerLogBuffer(maximumLines: 10, maximumBytes: 6)
        buffer.append("one\ntwo\n")

        XCTAssertEqual(buffer.snapshot.text, "two\n")
        XCTAssertEqual(buffer.snapshot.firstLogicalLineNumber, 2)
        XCTAssertLessThanOrEqual(buffer.snapshot.text.utf8.count, 6)
    }

    func testClearKeepsNextNumberAndNewSessionResetsIt() {
        var buffer = ContainerLogBuffer()
        buffer.append("one\ntwo")
        buffer.clear()

        XCTAssertEqual(buffer.snapshot.firstLogicalLineNumber, 3)
        buffer.append("three")
        XCTAssertEqual(buffer.snapshot.firstLogicalLineNumber, 3)

        buffer.startNewSession()
        buffer.append("replacement")
        XCTAssertEqual(buffer.snapshot, ContainerLogSnapshot(
            text: "replacement",
            firstLogicalLineNumber: 1
        ))
    }
}

@MainActor
final class ContainerLogViewerTests: XCTestCase {
    func testViewerWrapsAndHasNoHorizontalScroller() {
        let scrollView = ContainerLogScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 240,
            height: 120
        ))

        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.logTextView.isHorizontallyResizable)
        XCTAssertTrue(scrollView.logTextView.isVerticallyResizable)
        XCTAssertTrue(scrollView.logTextView.textContainer?.widthTracksTextView == true)
        XCTAssertTrue(scrollView.logTextView.isSelectable)
        XCTAssertFalse(scrollView.logTextView.isEditable)
        XCTAssertTrue(scrollView.hasVerticalRuler)

        scrollView.update(
            snapshot: ContainerLogSnapshot(
                text: String(repeating: "long log output ", count: 50),
                firstLogicalLineNumber: 1
            ),
            jumpToLatestRequest: 0
        )
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            scrollView.logTextView.frame.width,
            scrollView.contentSize.width + 1
        )
        XCTAssertGreaterThan(scrollView.logTextView.frame.width, 100)
        XCTAssertTrue(scrollView.scrollView.clipsToBounds)
        XCTAssertFalse(scrollView.drawsBackground)
        XCTAssertFalse(scrollView.contentView.drawsBackground)
        XCTAssertTrue(scrollView.logTextView.drawsBackground)
    }

    func testZeroSizedRepresentableLaysOutTextAfterSwiftUIAssignsAFrame() {
        let scrollView = ContainerLogScrollView(frame: .zero)
        let text = "The log text must remain visible after zero-sized creation.\nSecond line."

        scrollView.update(
            snapshot: ContainerLogSnapshot(text: text, firstLogicalLineNumber: 1),
            jumpToLatestRequest: 0
        )
        XCTAssertEqual(scrollView.logTextView.string, text)

        scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: 120)
        scrollView.layoutSubtreeIfNeeded()
        scrollView.tile()

        XCTAssertGreaterThan(scrollView.contentView.bounds.width, 100)
        XCTAssertEqual(
            scrollView.logTextView.frame.width,
            scrollView.contentView.bounds.width,
            accuracy: 1
        )
        let usedRect = scrollView.logTextView.layoutManager?.usedRect(
            for: scrollView.logTextView.textContainer!
        ) ?? .zero
        XCTAssertGreaterThan(usedRect.width, 20)
        XCTAssertGreaterThan(usedRect.height, 20)
    }

    func testWrappedFragmentsStartAfterLineNumberRuler() throws {
        let scrollView = ContainerLogScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 240,
            height: 120
        ))
        scrollView.update(
            snapshot: ContainerLogSnapshot(
                text: String(repeating: "wrapped fragment text ", count: 20),
                firstLogicalLineNumber: 1
            ),
            jumpToLatestRequest: 0
        )
        scrollView.layoutSubtreeIfNeeded()

        let layoutManager = try XCTUnwrap(scrollView.logTextView.layoutManager)
        let rulerThickness = try XCTUnwrap(
            scrollView.scrollView.verticalRulerView
        ).ruleThickness
        var fragmentMinimumXs: [CGFloat] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        ) { _, usedRect, _, _, _ in
            fragmentMinimumXs.append(usedRect.minX)
        }

        XCTAssertGreaterThan(fragmentMinimumXs.count, 1)
        XCTAssertTrue(
            fragmentMinimumXs.allSatisfy { $0 >= rulerThickness - 0.5 },
            "Every wrapped fragment must begin to the right of the line-number ruler."
        )
    }

    func testLiveResizeRewrapsDocumentWithoutCollapsingItsWidth() {
        let scrollView = ContainerLogScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 360,
            height: 120
        ))
        let text = String(repeating: "resizable log content ", count: 40)
        scrollView.update(
            snapshot: ContainerLogSnapshot(text: text, firstLogicalLineNumber: 1),
            jumpToLatestRequest: 0
        )
        scrollView.layoutSubtreeIfNeeded()
        let wideHeight = scrollView.logTextView.frame.height

        scrollView.setFrameSize(NSSize(width: 180, height: 120))
        scrollView.layoutSubtreeIfNeeded()
        scrollView.tile()

        XCTAssertGreaterThan(scrollView.logTextView.frame.width, 50)
        XCTAssertEqual(
            scrollView.logTextView.frame.width,
            scrollView.contentView.bounds.width,
            accuracy: 1
        )
        XCTAssertGreaterThan(scrollView.logTextView.frame.height, wideHeight)
        XCTAssertTrue(scrollView.isTailing)
    }

    func testTextForegroundTracksTheEffectiveLightAndDarkAppearance() throws {
        let scrollView = ContainerLogScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 240,
            height: 120
        ))
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.update(
            snapshot: ContainerLogSnapshot(text: "visible log", firstLogicalLineNumber: 1),
            jumpToLatestRequest: 0
        )

        let darkColor = try XCTUnwrap(
            scrollView.logTextView.textStorage?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        ).usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(try XCTUnwrap(darkColor).redComponent, 0.5)

        scrollView.appearance = NSAppearance(named: .aqua)
        scrollView.viewDidChangeEffectiveAppearance()
        let lightColor = try XCTUnwrap(
            scrollView.logTextView.textStorage?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        ).usingColorSpace(.deviceRGB)
        XCTAssertLessThan(try XCTUnwrap(lightColor).redComponent, 0.5)
    }

    func testDarkModeBitmapActuallyContainsPaintedLogGlyphs() throws {
        let scrollView = ContainerLogScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 320,
            height: 120
        ))
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.update(
            snapshot: ContainerLogSnapshot(
                text: "Painted log text must be visible.\nAnd so must this line.",
                firstLogicalLineNumber: 1
            ),
            jumpToLatestRequest: 0
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds)
        )
        scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)

        var lightPixelCount = 0
        let minimumX = min(bitmap.pixelsWide - 1, 55)
        let maximumX = max(minimumX, bitmap.pixelsWide - 20)
        let maximumY = min(bitmap.pixelsHigh, 70)
        for y in 0..<maximumY {
            for x in minimumX..<maximumX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                if color.redComponent > 0.65,
                   color.greenComponent > 0.65,
                   color.blueComponent > 0.65,
                   color.alphaComponent > 0.5 {
                    lightPixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(
            lightPixelCount,
            50,
            "The text area should contain visibly painted light glyph pixels in dark mode."
        )
    }

    func testTextStorageUpdatesByAppendingAndTrimming() {
        let storage = NSTextStorage(string: "one\ntwo\nthree\n")
        let oldSnapshot = ContainerLogSnapshot(
            text: storage.string,
            firstLogicalLineNumber: 1
        )
        let appendedSnapshot = ContainerLogSnapshot(
            text: "one\ntwo\nthree\nfour\n",
            firstLogicalLineNumber: 1
        )

        let append = ContainerLogTextStorageUpdater.update(
            storage,
            from: oldSnapshot,
            to: appendedSnapshot
        )
        XCTAssertEqual(storage.string, appendedSnapshot.text)
        XCTAssertEqual(append.removedPrefixLength, 0)
        XCTAssertEqual(append.insertedRange?.location, 14)

        let trimmedSnapshot = ContainerLogSnapshot(
            text: "two\nthree\nfour\n",
            firstLogicalLineNumber: 2
        )
        let trim = ContainerLogTextStorageUpdater.update(
            storage,
            from: appendedSnapshot,
            to: trimmedSnapshot
        )
        XCTAssertEqual(storage.string, trimmedSnapshot.text)
        XCTAssertEqual(trim.removedPrefixLength, 4)
    }

    func testSelectionSurvivesAppendAndMovesWithEvictedPrefix() {
        let scrollView = ContainerLogScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 300,
            height: 120
        ))
        let first = ContainerLogSnapshot(
            text: "one\ntwo\nthree\n",
            firstLogicalLineNumber: 1
        )
        scrollView.update(snapshot: first, jumpToLatestRequest: 0)
        scrollView.logTextView.setSelectedRange(NSRange(location: 4, length: 3))

        let appended = ContainerLogSnapshot(
            text: "one\ntwo\nthree\nfour\n",
            firstLogicalLineNumber: 1
        )
        scrollView.update(snapshot: appended, jumpToLatestRequest: 0)
        XCTAssertEqual(scrollView.logTextView.selectedRange(), NSRange(location: 4, length: 3))

        let trimmed = ContainerLogSnapshot(
            text: "two\nthree\nfour\n",
            firstLogicalLineNumber: 2
        )
        scrollView.update(snapshot: trimmed, jumpToLatestRequest: 0)
        XCTAssertEqual(scrollView.logTextView.selectedRange(), NSRange(location: 0, length: 3))
    }

    func testScrollingAwayDisengagesTailingAndJumpResumesIt() {
        let scrollView = ContainerLogScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 240,
            height: 80
        ))
        let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
        scrollView.update(
            snapshot: ContainerLogSnapshot(text: text, firstLogicalLineNumber: 1),
            jumpToLatestRequest: 0
        )
        XCTAssertTrue(scrollView.isTailing)

        scrollView.contentView.scroll(to: .zero)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        XCTAssertFalse(scrollView.isTailing)

        scrollView.update(
            snapshot: ContainerLogSnapshot(text: text, firstLogicalLineNumber: 1),
            jumpToLatestRequest: 1
        )
        XCTAssertTrue(scrollView.isTailing)
        let maximumY = max(
            0,
            scrollView.logTextView.frame.height - scrollView.contentView.bounds.height
        )
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, maximumY, accuracy: 1)
    }

    func testAppendFollowsWhenPinnedAndPreservesViewportWhenUnpinned() {
        let scrollView = ContainerLogScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 240,
            height: 80
        ))
        let originalText = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let original = ContainerLogSnapshot(
            text: originalText,
            firstLogicalLineNumber: 1
        )
        scrollView.update(snapshot: original, jumpToLatestRequest: 0)

        let appended = ContainerLogSnapshot(
            text: originalText + "\nline 101",
            firstLogicalLineNumber: 1
        )
        scrollView.update(snapshot: appended, jumpToLatestRequest: 0)
        let latestY = max(
            0,
            scrollView.logTextView.frame.height - scrollView.contentView.bounds.height
        )
        XCTAssertTrue(scrollView.isTailing)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, latestY, accuracy: 1)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        XCTAssertFalse(scrollView.isTailing)
        let heldY = scrollView.contentView.bounds.origin.y

        scrollView.update(
            snapshot: ContainerLogSnapshot(
                text: appended.text + "\nline 102",
                firstLogicalLineNumber: 1
            ),
            jumpToLatestRequest: 0
        )
        XCTAssertFalse(scrollView.isTailing)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, heldY, accuracy: 1)
    }
}
