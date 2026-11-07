import XCTest

final class HelloWorldUITests: XCTestCase {

    override func setUpWithError() throws {
        // Stop the test at the first failure instead of clicking on blindly.
        continueAfterFailure = false
    }

    func testAppOpensToDropScreen() throws {
        let app = XCUIApplication()
        app.launch()

        // The big title on the drop screen.
        XCTAssertTrue(app.staticTexts["PGS2SRT"].waitForExistence(timeout: 10),
                      "The drop screen title never showed up")

        // The toolbar button. The name uses the single "…" character, not three dots.
        XCTAssertTrue(app.buttons["Open…"].exists, "The Open… button is missing")
    }
}
