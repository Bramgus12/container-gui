import XCTest

final class OnboardingUITests: XCTestCase {
    func testMissingCLIShowsInstallationActions() {
        let app = launch(scenario: "missing")

        XCTAssertTrue(app.staticTexts["Install Apple Container"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Choose Executable…"].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertTrue(app.links["Open Apple Container installation instructions"].exists)
    }

    func testStoppedServiceCanEnterMainNavigation() {
        let app = launch(scenario: "stopped")

        XCTAssertTrue(app.buttons["Start Service"].waitForExistence(timeout: 3))
        app.buttons["Start Service"].click()
        XCTAssertTrue(app.staticTexts["Containers"].waitForExistence(timeout: 3))
    }

    func testFailureShowsDiagnosticsAndRecoveryActions() {
        let app = launch(scenario: "failed")

        XCTAssertTrue(app.staticTexts["Setup couldn’t finish"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["17"].exists)
        XCTAssertTrue(app.buttons["Copy Diagnostics"].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
    }

    func testReadyStateSkipsOnboarding() {
        let app = launch(scenario: "ready")

        XCTAssertTrue(app.staticTexts["Containers"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Retry"].exists)
    }

    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-test-preflight", scenario,
        ]
        app.launch()
        return app
    }
}
