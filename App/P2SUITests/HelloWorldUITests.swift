import XCTest

final class HelloWorldUITests: XCTestCase {
    private var fixtures: UITestFixtureBuilder!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtures = try UITestFixtureBuilder()
        // A valid .sup in UITEST_INPUT_DIR is ingested like a drop and conversion
        // starts immediately (including OCR). A 0-byte dummy still appears in the
        // queue and fails quickly on an empty stream.
        try fixtures.createDummyFile(in: fixtures.input, named: "sample.sup")
    }

    override func tearDownWithError() throws {
        fixtures?.cleanup()
        fixtures = nil
    }

    func testAppOpensToDropScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = [
            "UITEST_INPUT_DIR": fixtures.input.path,
            "UITEST_OUTPUT_DIR": fixtures.output.path,
        ]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5),
                      "The main application window never showed up")

        // The title stays in the header after the queue replaces the drop screen.
        XCTAssertTrue(app.staticTexts["PGS2SRT"].waitForExistence(timeout: 10),
                      "The window title never showed up")

        // The toolbar button. The name uses the single "…" character, not three dots.
        XCTAssertTrue(app.buttons["Open…"].exists, "The Open… button is missing")

        let item = app.staticTexts["sample.sup"]
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "The seeded sample.sup row never showed up")

        let summary = app.descendants(matching: .any)["settingsSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "The settings summary never showed up")
        XCTAssertTrue(summary.label.contains("output"),
                      "The output folder was not seeded from UITEST_OUTPUT_DIR: \(summary.label)")
    }
}
