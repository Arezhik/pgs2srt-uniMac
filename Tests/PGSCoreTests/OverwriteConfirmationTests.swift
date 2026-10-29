import XCTest
import PGSCore

final class OverwriteConfirmationTests: XCTestCase {
    func testDefaultStaysOverwriteAndAnExistingFileAsks() {
        XCTAssertEqual(ConversionPreferences.default.existingFile, .overwrite)
        let planned = SRTOutputPath.plan(
            sourcePath: "/films/Movie.sup",
            preferences: .default,
            fileExists: { $0 == "/films/Movie.srt" },
            directoryExists: { $0 == "/films" }
        )
        XCTAssertEqual(planned, .write("/films/Movie.srt"))
        XCTAssertEqual(
            OverwriteConfirmation.resolve(
                planned: planned,
                setting: .overwrite,
                fileExists: { $0 == "/films/Movie.srt" },
                remembered: nil
            ),
            .ask("/films/Movie.srt")
        )
    }

    func testMissingFileAndOtherSettingsDoNotAsk() {
        let missing = OutputDestination.write("/films/Movie.srt")
        XCTAssertEqual(
            OverwriteConfirmation.resolve(
                planned: missing,
                setting: .overwrite,
                fileExists: { _ in false },
                remembered: nil
            ),
            .ready(missing)
        )

        let numbered = OutputDestination.write("/films/Movie 2.srt")
        XCTAssertEqual(
            OverwriteConfirmation.resolve(
                planned: numbered,
                setting: .addNumber,
                fileExists: { $0 == "/films/Movie.srt" },
                remembered: nil
            ),
            .ready(numbered)
        )

        let skipped = OutputDestination.skipBecauseExists("/films/Movie.srt")
        XCTAssertEqual(
            OverwriteConfirmation.resolve(
                planned: skipped,
                setting: .skip,
                fileExists: { _ in true },
                remembered: nil
            ),
            .ready(skipped)
        )

        let rejected = OutputDestination.reject("Choose an output folder in Settings, or save next to the source file.")
        XCTAssertEqual(
            OverwriteConfirmation.resolve(
                planned: rejected,
                setting: .overwrite,
                fileExists: { _ in true },
                remembered: nil
            ),
            .ready(rejected)
        )
    }

    func testRememberedReplaceWritesAndRememberedSkipLeavesTheFile() {
        let planned = OutputDestination.write("/films/Movie.srt")
        XCTAssertEqual(
            OverwriteConfirmation.resolve(
                planned: planned,
                setting: .overwrite,
                fileExists: { _ in true },
                remembered: .replace
            ),
            .ready(.write("/films/Movie.srt"))
        )
        XCTAssertEqual(
            OverwriteConfirmation.resolve(
                planned: planned,
                setting: .overwrite,
                fileExists: { _ in true },
                remembered: .skip
            ),
            .ready(.skipBecauseExists("/films/Movie.srt"))
        )
    }

    func testApplyToAllIsRememberedAndCancelIsNot() {
        XCTAssertEqual(OverwriteConfirmation.remember(.replace(applyToAll: true)), .replace)
        XCTAssertEqual(OverwriteConfirmation.remember(.skip(applyToAll: true)), .skip)
        XCTAssertNil(OverwriteConfirmation.remember(.replace(applyToAll: false)))
        XCTAssertNil(OverwriteConfirmation.remember(.skip(applyToAll: false)))
        XCTAssertNil(OverwriteConfirmation.remember(.cancel))
    }
}
