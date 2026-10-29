import XCTest
import PGSCore

final class RevealFollowUpTests: XCTestCase {
    private let output = "/films/out/Movie.srt"
    private let source = "/films/Movie.sup"
    private let folder = "/films/out"

    func testAnExistingSubtitleIsShown() {
        XCTAssertEqual(
            plan(files: [output], directories: [folder]),
            .showFile(output)
        )
    }

    func testFolderStillThereOffersShowFolderAndConvertAgain() {
        let alert = missing(plan(files: [source], directories: [folder]))
        XCTAssertEqual(alert.title, "“Movie.srt” can't be found.")
        XCTAssertEqual(alert.detail, "It may have been moved or deleted.")
        XCTAssertEqual(alert.buttons, [.showFolder, .convertAgain, .cancel])
        XCTAssertTrue(alert.folderExists)
        XCTAssertNil(RevealFollowUp.restoredFolder(for: alert))
    }

    func testMissingFolderOffersConvertAgainAndRestoresThatFolder() {
        let alert = missing(plan(files: [source], directories: []))
        XCTAssertEqual(alert.title, "The folder for “Movie.srt” was moved or deleted.")
        XCTAssertEqual(alert.detail, "Convert Again creates that folder and writes the subtitle there.")
        XCTAssertEqual(alert.buttons, [.convertAgain, .cancel])
        XCTAssertFalse(alert.folderExists)
        XCTAssertEqual(RevealFollowUp.restoredFolder(for: alert), folder)
    }

    func testMissingOriginalOffersOnlyOKWhenTheFolderIsGone() {
        let alert = missing(plan(files: [], directories: []))
        XCTAssertEqual(alert.title, "“Movie.srt” can't be found.")
        XCTAssertEqual(alert.detail, "The original file is gone too, so it can't be converted again.")
        XCTAssertEqual(alert.buttons, [.ok])
        XCTAssertNil(RevealFollowUp.restoredFolder(for: alert))
    }

    func testMissingOriginalStillOffersTheFolderWhenItExists() {
        let alert = missing(plan(files: [], directories: [folder]))
        XCTAssertEqual(alert.buttons, [.showFolder, .ok])
        XCTAssertEqual(alert.title, "“Movie.srt” can't be found.")
        XCTAssertTrue(alert.folderExists)
        XCTAssertNil(RevealFollowUp.restoredFolder(for: alert))
    }

    private func plan(files: Set<String>, directories: Set<String>) -> RevealPlan {
        RevealFollowUp.plan(
            outputPath: output,
            sourcePath: source,
            fileExists: { files.contains($0) },
            directoryExists: { directories.contains($0) }
        )
    }

    private func missing(_ plan: RevealPlan) -> RevealAlert {
        guard case let .alert(alert) = plan else {
            XCTFail("expected an alert, got \(plan)")
            return RevealAlert(
                title: "",
                detail: "",
                buttons: [],
                outputFolder: "",
                folderExists: false,
                sourcePath: ""
            )
        }
        return alert
    }
}
