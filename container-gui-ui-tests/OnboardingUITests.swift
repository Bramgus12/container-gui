import AppKit
import XCTest

final class OnboardingUITests: XCTestCase {
    func testMissingCLIShowsInstallationActions() {
        let app = launch(scenario: "missing")

        XCTAssertTrue(app.staticTexts["Install Apple Container"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Choose Executable…"].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertTrue(app.links["Open Apple Container installation instructions"].exists)
    }

    func testStoppedServiceCanEnterMainNavigationUsingMockCLI() {
        let app = launch(scenario: "stopped")

        XCTAssertTrue(app.buttons["Start Service"].waitForExistence(timeout: 3))
        app.buttons["Start Service"].click()
        XCTAssertTrue(app.staticTexts["Containers"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["demo-stopped"].waitForExistence(timeout: 3),
            "Starting the mocked service should load containers from the mocked CLI."
        )
    }

    func testFailureShowsDiagnosticsAndRecoveryActions() {
        let app = launch(scenario: "failed")

        XCTAssertTrue(app.staticTexts["Setup couldn’t finish"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["17"].exists)
        XCTAssertTrue(app.buttons["Copy Diagnostics"].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
    }

    func testReadyStateSkipsOnboardingAndUsesMockCLI() {
        let app = launch(scenario: "ready")

        XCTAssertTrue(app.staticTexts["Containers"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["demo-stopped"].waitForExistence(timeout: 3),
            "The ready scenario should load containers from the mocked CLI."
        )
        XCTAssertFalse(app.buttons["Retry"].exists)
    }

    func testMainContainerLifecycleWithFakeCLI() {
        let app = launch(scenario: "lifecycle")

        let runButton = app.buttons["containers.run"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 3))
        runButton.click()
        let runSheet = app.sheets.firstMatch
        XCTAssertTrue(runSheet.waitForExistence(timeout: 3))
        let imageField = runSheet.textFields["run.image"]
        XCTAssertTrue(imageField.waitForExistence(timeout: 3))
        imageField.click()
        imageField.typeText("alpine:3.21")
        let nameField = runSheet.textFields["run.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.click()
        nameField.typeText("created-by-ui-test")
        let submitButton = runSheet.buttons["run.submit"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 3))
        submitButton.click()
        XCTAssertTrue(
            app.staticTexts["created-by-ui-test"].waitForExistence(timeout: 3),
            "Running a container should refresh the list with the created container."
        )

        let fixture = app.staticTexts["demo-stopped"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 3))
        fixture.click()

        let start = app.buttons["containers.start"]
        XCTAssertTrue(start.isEnabled)
        start.click()
        XCTAssertTrue(waitUntil(timeout: 3) {
            app.staticTexts["Running"].exists
        })

        let stop = app.buttons["containers.stop"]
        XCTAssertTrue(stop.isEnabled)
        stop.click()
        XCTAssertTrue(waitUntil(timeout: 3) {
            app.staticTexts["Stopped"].exists
        })

        app.menuButtons["containers.moreActions"].click()
        app.menuItems["Delete…"].click()
        let deletionConfirmation = app.sheets
            .containing(.staticText, identifier: "Delete Container?")
            .firstMatch
        XCTAssertTrue(deletionConfirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(fixture.exists, "The container must remain until deletion is confirmed.")
        deletionConfirmation.buttons["Delete"].click()
        XCTAssertTrue(waitUntil(timeout: 3) { !fixture.exists })
    }

    func testContainerLogViewerShowsNumberedSelectableMockLogs() {
        let app = launch(scenario: "ready")
        let fixture = app.staticTexts["demo-stopped"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 3))
        fixture.click()

        let logsTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Logs"))
            .firstMatch
        XCTAssertTrue(logsTab.waitForExistence(timeout: 3))
        logsTab.click()

        let viewer = app.textViews["logs.viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 3))
        XCTAssertTrue(logsTab.exists, "The detail tabs must remain visible above the log viewer.")
        XCTAssertTrue(
            (viewer.value as? String)?.contains("first UI test log line") == true,
            "The native text view must expose the rendered log text."
        )
        assertLogTextIsVisiblyRendered(in: viewer)
        XCTAssertGreaterThan(viewer.frame.width, 100)
        XCTAssertGreaterThan(viewer.frame.height, 100)
        XCTAssertTrue(
            app.descendants(matching: .any)["logs.lineNumbers"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["logs.jumpToLatest"].exists)
        XCTAssertTrue(app.buttons["logs.copy"].isEnabled)

        app.buttons["logs.copy"].click()
        let copiedLogs = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copiedLogs.contains("first UI test log line"))
        XCTAssertTrue(copiedLogs.contains("final UI test log line"))
        XCTAssertFalse(copiedLogs.contains("Waiting for logs"))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Container log viewer"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        viewer.click()
        viewer.typeKey("a", modifierFlags: .command)
        viewer.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            copiedLogs,
            "The native text view should support selection and standard copy commands."
        )
    }

    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--ui-test-preflight", scenario,
        ]
        app.launch()
        return app
    }

    private func assertLogTextIsVisiblyRendered(
        in viewer: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let data = viewer.screenshot().image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data)
        else {
            XCTFail("Could not inspect the rendered log viewer.", file: file, line: line)
            return
        }

        let minimumX = min(bitmap.pixelsWide - 1, 16)
        let maximumX = max(minimumX, bitmap.pixelsWide - 20)
        let maximumY = min(bitmap.pixelsHigh, 100)
        var colorHistogram: [Int: Int] = [:]
        for y in 0..<maximumY {
            for x in minimumX..<maximumX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                let red = Int((color.redComponent * 31).rounded())
                let green = Int((color.greenComponent * 31).rounded())
                let blue = Int((color.blueComponent * 31).rounded())
                colorHistogram[(red << 10) | (green << 5) | blue, default: 0] += 1
            }
        }
        guard let backgroundKey = colorHistogram.max(by: { $0.value < $1.value })?.key
        else {
            XCTFail("Could not sample the rendered log viewer.", file: file, line: line)
            return
        }

        let backgroundRed = CGFloat((backgroundKey >> 10) & 31) / 31
        let backgroundGreen = CGFloat((backgroundKey >> 5) & 31) / 31
        let backgroundBlue = CGFloat(backgroundKey & 31) / 31
        var contrastingPixelCount = 0
        for y in 0..<maximumY {
            for x in minimumX..<maximumX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                let contrast = abs(color.redComponent - backgroundRed)
                    + abs(color.greenComponent - backgroundGreen)
                    + abs(color.blueComponent - backgroundBlue)
                if contrast > 0.6, color.alphaComponent > 0.5 {
                    contrastingPixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(
            contrastingPixelCount,
            50,
            "The populated log view should contain visibly painted text glyphs.",
            file: file,
            line: line
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return condition()
    }
}
