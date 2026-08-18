import AppKit
import XCTest
@testable import Container_GUI

/// The blue ramp's dark values are not given by the design system — it names
/// dark values only for the neutrals and for the "lifted" accent. These tests
/// pin the rule the dark ramp was derived from, so the values cannot drift back
/// into being arbitrary.
final class DesignSystemColorTests: XCTestCase {
    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    // MARK: - The one dark value the design does specify

    func testDarkAccentIsTheLiftedAccentTheDesignNames() {
        // "Accent (lifted) #4A9BFF" — the whole mark sub-ramp is anchored here.
        assertColor("Blue400", in: dark, isApproximately: "#4A9BFF")
        assertColor("Blue400", in: light, isApproximately: "#1C7BF5")
        // AccentColor must agree with it, or controls drift from the palette.
        assertColor("AccentColor", in: dark, isApproximately: "#4A9BFF")
        assertColor("AccentColor", in: light, isApproximately: "#1C7BF5")
    }

    // MARK: - Sub-ramp 1: tint surfaces

    func testTintSurfacesSitJustOffSurfaceInBothAppearances() {
        // Blue100/200 back selected rows and progress rows. They must be clearly
        // distinguishable from Surface but nowhere near a mark's strength.
        for appearance in [light, dark] {
            let surface = resolve("Surface", in: appearance)
            let tint100 = resolve("Blue100", in: appearance)
            let tint200 = resolve("Blue200", in: appearance)

            let c100 = contrastRatio(tint100, surface)
            let c200 = contrastRatio(tint200, surface)

            XCTAssertGreaterThan(c100, 1.05, "Blue100 is indistinguishable from Surface")
            XCTAssertLessThan(c100, 1.30, "Blue100 is too strong to be a tint")
            XCTAssertGreaterThan(c200, c100, "Blue200 must be the stronger tint")
            XCTAssertLessThan(c200, 1.70, "Blue200 is too strong to be a tint")
        }
    }

    func testTextStaysHighlyLegibleOnATintedRow() {
        // A selected table row is Blue100 with primary text on it.
        for (appearance, textAsset) in [(light, "TextPrimary"), (dark, "TextPrimary")] {
            let ratio = contrastRatio(
                resolve("Blue100", in: appearance),
                resolve(textAsset, in: appearance)
            )
            XCTAssertGreaterThan(ratio, 7, "Selected-row text falls below AAA")
        }
        // Secondary text also lands on tinted rows, so hold it to AA.
        for appearance in [light, dark] {
            let ratio = contrastRatio(
                resolve("Blue100", in: appearance),
                resolve("TextSecondary", in: appearance)
            )
            XCTAssertGreaterThan(ratio, 4.5, "Dimmed text on a selected row falls below AA")
        }
    }

    // MARK: - Sub-ramp 2: marks

    func testMarkRampDarkensMonotonicallyInBothAppearances() {
        // 300 → 700 must never reverse, or bars and dots stop reading as a ramp.
        for appearance in [light, dark] {
            let steps = ["Blue300", "Blue400", "Blue500", "Blue700"]
                .map { luminance(resolve($0, in: appearance)) }
            for (index, pair) in zip(steps, steps.dropFirst()).enumerated() {
                XCTAssertGreaterThan(
                    pair.0,
                    pair.1,
                    "Mark ramp reverses between step \(index) and \(index + 1)"
                )
            }
        }
    }

    func testStandaloneMarksMeetNonTextContrast() {
        // Blue400 and Blue500 carry meaning on their own — state dots, the
        // selection rail, usage bars, the accent — so WCAG 1.4.11's 3:1 applies.
        for appearance in [light, dark] {
            let surface = resolve("Surface", in: appearance)
            for asset in ["Blue400", "Blue500"] {
                let ratio = contrastRatio(resolve(asset, in: appearance), surface)
                XCTAssertGreaterThan(
                    ratio,
                    3,
                    "\(asset) is not legible as a standalone mark in \(appearance.name.rawValue)"
                )
            }
        }
    }

    func testRampEndsStayVisibleEvenThoughALegendCarriesTheirMeaning() {
        // Blue300 and Blue700 appear only as segments of the stacked bar, where
        // a legend names each segment — so colour alone is not load-bearing and
        // 3:1 does not apply. They must still be plainly visible, and the
        // design's own light Blue300 (#4A9BFF on white) sits at 2.83, which is
        // why the floor here is lower than the standalone-mark test's.
        for appearance in [light, dark] {
            let surface = resolve("Surface", in: appearance)
            for asset in ["Blue300", "Blue700"] {
                let ratio = contrastRatio(resolve(asset, in: appearance), surface)
                XCTAssertGreaterThan(
                    ratio,
                    2.5,
                    "\(asset) disappears into Surface in \(appearance.name.rawValue)"
                )
            }
        }
    }

    func testAdjacentBarSegmentsAreDistinguishableFromEachOther() {
        // What actually makes a stacked bar readable is each segment differing
        // from the one beside it.
        for appearance in [light, dark] {
            let steps = ["Blue300", "Blue400", "Blue500", "Blue700"]
                .map { resolve($0, in: appearance) }
            for (index, pair) in zip(steps, steps.dropFirst()).enumerated() {
                XCTAssertGreaterThan(
                    contrastRatio(pair.0, pair.1),
                    1.2,
                    "Bar segments \(index) and \(index + 1) are too close to tell apart"
                )
            }
        }
    }

    func testStackedBarDrawsOnlyFromTheMarkRange() {
        // Regression: two segments were drawn in the tint range, which in dark
        // mode is navy on near-black.
        let data = Data("""
        {
          "containers": { "active": 1, "reclaimable": 10, "sizeInBytes": 100, "total": 2 },
          "images": { "active": 2, "reclaimable": 10, "sizeInBytes": 200, "total": 3 },
          "volumes": { "active": 1, "reclaimable": 10, "sizeInBytes": 300, "total": 1 }
        }
        """.utf8)
        let usage = try? SystemDiskUsage.decode(from: data)
        let segments = usage?.usageSegments ?? []
        XCTAssertFalse(segments.isEmpty)

        let tints = [resolve("Blue100", in: dark), resolve("Blue200", in: dark)]
        for segment in segments where segment.bytes > 0 {
            let drawn = NSColor(segment.color)
            for tint in tints {
                XCTAssertGreaterThan(
                    contrastRatio(drawn, tint),
                    1.001,
                    "Segment \(segment.id) is drawn in the tint range"
                )
            }
        }
    }

    // MARK: - Helpers

    private func resolve(_ asset: String, in appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(named: asset)?.usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }

    private func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func assertColor(
        _ asset: String,
        in appearance: NSAppearance,
        isApproximately hex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolved = resolve(asset, in: appearance)
        let value = hex.dropFirst()
        let expected = NSColor(
            srgbRed: CGFloat(Int(value.prefix(2), radix: 16)!) / 255,
            green: CGFloat(Int(value.dropFirst(2).prefix(2), radix: 16)!) / 255,
            blue: CGFloat(Int(value.suffix(2), radix: 16)!) / 255,
            alpha: 1
        )
        XCTAssertEqual(resolved.redComponent, expected.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, expected.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, expected.blueComponent, accuracy: 0.01, file: file, line: line)
    }
}
