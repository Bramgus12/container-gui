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
