import XCTest
@testable import PGSCore

final class MKVOutputNameTests: XCTestCase {
    func testASingleTrackKeepsThePlainName() {
        let track = PGSSubtitleTrack(id: 4, number: 5, language: "eng", languageIETF: "en", name: "English", forced: true, isDefault: true)
        XCTAssertEqual(MKVOutputName.suffixes(for: [track])[4], "")
        XCTAssertEqual(MKVOutputName.fileName(stem: "Movie", suffix: ""), "Movie.srt")
        XCTAssertEqual(
            MKVOutputName.savesLine(stem: "Movie", tracks: [track]),
            "1 selected · saves Movie.srt"
        )
        XCTAssertEqual(MKVOutputName.savesLine(stem: "Movie", tracks: []), "No tracks selected")
    }

    func testLanguageForcedAndDuplicates() {
        let english = PGSSubtitleTrack(id: 1, number: 2, language: "eng", languageIETF: "en", name: "English", forced: false, isDefault: true)
        let forced = PGSSubtitleTrack(id: 2, number: 3, language: "eng", languageIETF: "en", name: "English", forced: true, isDefault: false)
        let spanish = PGSSubtitleTrack(id: 3, number: 4, language: "spa", languageIETF: "es", name: "Spanish", forced: false, isDefault: false)
        let suffixes = MKVOutputName.suffixes(for: [english, forced, spanish])
        XCTAssertEqual(suffixes[1], "en")
        XCTAssertEqual(suffixes[2], "en.forced")
        XCTAssertEqual(suffixes[3], "es")
        XCTAssertEqual(
            MKVOutputName.savesLine(stem: "Movie", tracks: [english, forced]),
            "2 selected · saves Movie.en.srt and Movie.en.forced.srt"
        )

        let again = PGSSubtitleTrack(id: 4, number: 5, language: "eng", languageIETF: "en", name: "SDH", forced: false, isDefault: false)
        let dups = MKVOutputName.suffixes(for: [english, again])
        XCTAssertEqual(dups[1], "en")
        XCTAssertEqual(dups[4], "en.2")
    }

    func testANameIsUsedWhenTheLanguageIsMissing() {
        let signs = PGSSubtitleTrack(id: 8, number: 9, language: "", languageIETF: "", name: "Signs", forced: false, isDefault: false)
        let other = PGSSubtitleTrack(id: 9, number: 10, language: "und", languageIETF: "", name: "", forced: false, isDefault: false)
        let suffixes = MKVOutputName.suffixes(for: [signs, other])
        XCTAssertEqual(suffixes[8], "signs")
        XCTAssertEqual(suffixes[9], "und")
        XCTAssertEqual(MKVOutputName.stem(of: "/films/Movie.mkv"), "Movie")
    }
}

final class BatchSummaryTextTests: XCTestCase {
    func testFinishedWordingOmitsZeroCounts() {
        XCTAssertEqual(
            BatchSummaryText.finished(BatchOutcome(done: 3, failed: 1, cancelled: 0, skipped: 1), elapsed: 134),
            "3 done, 1 failed, 1 skipped in 2m 14s"
        )
        XCTAssertEqual(
            BatchSummaryText.finished(BatchOutcome(done: 5, failed: 0, cancelled: 0, skipped: 0), elapsed: 362),
            "5 done in 6m 02s"
        )
        XCTAssertEqual(
            BatchSummaryText.finished(BatchOutcome(done: 2, failed: 0, cancelled: 3, skipped: 0), elapsed: 62),
            "2 done, 3 cancelled in 1m 02s"
        )
        XCTAssertEqual(
            BatchSummaryText.finished(BatchOutcome(done: 1, failed: 0, cancelled: 0, skipped: 0), elapsed: 48),
            "1 done in 48s"
        )
        XCTAssertEqual(BatchSummaryText.running(current: 2, total: 5), "Converting 2 of 5")
        XCTAssertEqual(BatchSummaryText.duration(0.4), "0s")
    }

    func testRollupMarksFailuresInWords() {
        let pieces = TrackRollupText.pieces(for: [
            .done(cueCount: 1, unrecognizedCount: 0, outputPath: "a.srt"),
            .converting(completed: 1, total: 4),
            .waiting,
            .failed("Could not read this MKV.")
        ])
        XCTAssertEqual(
            pieces.map(\.text).joined(),
            "4 tracks · 1 done, 1 failed, 1 converting, 1 waiting"
        )
        XCTAssertTrue(pieces.contains { $0.isFailure && $0.text == "1 failed" })
    }

    func testTrackStatusLines() {
        XCTAssertEqual(TrackStatusText.line(.waiting), "Waiting")
        XCTAssertEqual(TrackStatusText.line(.converting(completed: 1, total: 4)), "Converting · 25%")
        XCTAssertEqual(TrackStatusText.line(.converting(completed: 0, total: 0)), "Converting")
        XCTAssertEqual(
            TrackStatusText.line(.done(cueCount: 3, unrecognizedCount: 0, outputPath: "/films/Movie.en.srt")),
            "Done · 3 cues · Movie.en.srt"
        )
        XCTAssertEqual(TrackStatusText.line(.awaitingReview(cueCount: 2, unrecognizedCount: 0, plannedPath: "a.srt")), "Ready to review · not saved yet")
        XCTAssertEqual(TrackStatusText.line(.failed("Nope")), "Failed · Nope")
    }
}
