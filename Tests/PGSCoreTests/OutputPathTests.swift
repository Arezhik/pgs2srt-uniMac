import XCTest
import PGSCore

final class OutputPathTests: XCTestCase {
    func testNextToTheSourceAndAChosenFolder() {
        XCTAssertEqual(
            plan("/films/Movie.SUP", preferences: .default),
            .write("/films/Movie.srt")
        )
        XCTAssertEqual(
            plan("/films/Movie.mkv", preferences: .default),
            .write("/films/Movie.srt")
        )
        XCTAssertEqual(
            plan("/films/Movie.MKV", preferences: .default),
            .write("/films/Movie.srt")
        )
        let folder = ConversionPreferences(
            placement: .folder("/out"),
            language: "en-US",
            existingFile: .overwrite,
            concurrency: 4,
            experimentalItalics: false
        )
        XCTAssertEqual(
            plan("/films/Movie.sup", preferences: folder, directories: ["/out"]),
            .write("/out/Movie.srt")
        )
        XCTAssertEqual(
            SRTOutputPath.numbered("/films/Movie.srt", number: 2),
            "/films/Movie 2.srt"
        )
        XCTAssertEqual(SRTOutputPath.numbered("Movie.srt", number: 3), "Movie 3.srt")
        XCTAssertEqual(SRTOutputPath.numbered("/films/Movie.srt", number: 1), "/films/Movie.srt")
    }

    func testOverwriteReplacesAFileAlreadyOnDisk() {
        let preferences = preferences(existing: .overwrite)
        XCTAssertEqual(
            plan("/films/Movie.sup", preferences: preferences, files: ["/films/Movie.srt"]),
            .write("/films/Movie.srt")
        )
    }

    func testOverwriteDoesNotClobberAnotherFileInTheSameBatch() {
        let preferences = preferences(existing: .overwrite, folder: "/out")
        XCTAssertEqual(
            plan(
                "/b/Movie.sup",
                preferences: preferences,
                directories: ["/out"],
                reserved: ["/out/Movie.srt"]
            ),
            .write("/out/Movie 2.srt")
        )
    }

    func testAddNumberSkipsNamesThatExistOrAreReserved() {
        let preferences = preferences(existing: .addNumber, folder: "/out")
        XCTAssertEqual(
            plan(
                "/a/Movie.sup",
                preferences: preferences,
                files: ["/out/Movie.srt", "/out/Movie 2.srt"],
                directories: ["/out"],
                reserved: ["/out/Movie 3.srt"]
            ),
            .write("/out/Movie 4.srt")
        )
    }

    func testSkipWhenTheFileExistsOrAnotherJobClaimedIt() {
        let preferences = preferences(existing: .skip)
        XCTAssertEqual(
            plan("/films/Movie.sup", preferences: preferences, files: ["/films/Movie.srt"]),
            .skipBecauseExists("/films/Movie.srt")
        )
        XCTAssertEqual(
            plan("/films/Movie.sup", preferences: preferences, reserved: ["/films/Movie.srt"]),
            .skipBecauseReserved("/films/Movie.srt")
        )
    }

    func testMissingOutputFolderIsAClearFailure() {
        let empty = preferences(existing: .overwrite, folder: "  ")
        XCTAssertEqual(
            plan("/films/Movie.sup", preferences: empty, directories: []),
            .reject("Choose an output folder in Settings, or save next to the source file.")
        )
        let missing = preferences(existing: .overwrite, folder: "/gone")
        XCTAssertEqual(
            plan("/films/Movie.sup", preferences: missing, directories: []),
            .reject("The output folder is missing. Choose it again in Settings.")
        )
    }

    func testFailureTextUsesTheDecoderWording() {
        XCTAssertEqual(
            ConversionFailureText.message(for: PGSError.emptyInput),
            "The PGS file is empty."
        )
        XCTAssertEqual(
            ConversionFailureText.message(for: CancellationError()),
            "Cancelled."
        )
        XCTAssertEqual(
            ConversionFailureText.message(for: PlainFailure()),
            ConversionFailureText.generic
        )
        XCTAssertEqual(
            ConversionFailureText.message(for: FriendlyFailure()),
            "The picture could not be read."
        )
    }

    func testBatchNotificationCounts() {
        XCTAssertEqual(
            BatchOutcome(done: 3, failed: 1, cancelled: 0, skipped: 0).notificationBody,
            "Finished. 3 done, 1 failed."
        )
        XCTAssertEqual(
            BatchOutcome(done: 1, failed: 0, cancelled: 2, skipped: 1).notificationBody,
            "Finished. 1 done, 0 failed, 2 cancelled, 1 skipped."
        )
    }

    private func preferences(
        existing: ExistingSubtitleAction,
        folder: String? = nil
    ) -> ConversionPreferences {
        ConversionPreferences(
            placement: folder.map(OutputPlacement.folder) ?? .nextToSource,
            language: "en-US",
            existingFile: existing,
            concurrency: 4,
            experimentalItalics: false
        )
    }

    private func plan(
        _ source: String,
        preferences: ConversionPreferences,
        files: Set<String> = [],
        directories: Set<String> = ["/films", "/a", "/b", "/out"],
        reserved: Set<String> = []
    ) -> OutputDestination {
        SRTOutputPath.plan(
            sourcePath: source,
            preferences: preferences,
            fileExists: { files.contains($0) },
            directoryExists: { directories.contains($0) },
            reserved: reserved
        )
    }
}

private struct PlainFailure: Error {}

private struct FriendlyFailure: Error, LocalizedError {
    var errorDescription: String? { "The picture could not be read." }
}
