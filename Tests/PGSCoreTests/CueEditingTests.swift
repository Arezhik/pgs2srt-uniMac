import XCTest
import PGSCore

final class CueEditingTests: XCTestCase {
    func testFailureStaysOutOfTheFieldAndSRTUsesThePlaceholderUntilItIsEdited() throws {
        let failure = CueRecognitionFailure(cueIndex: 0, startPTS: 0, endPTS: 90_000, message: "no text recognized")
        let result = TranscriptionResult(
            cues: [
                SRTCue(startPTS: 0, endPTS: 90_000, text: failure.placeholder),
                SRTCue(startPTS: 90_000, endPTS: 180_000, text: "Hold on!")
            ],
            failures: [failure],
            srt: "ignored"
        )
        var document = CueDocument.fromTranscription(result)
        XCTAssertEqual(document.cues[0].text, "")
        XCTAssertFalse(document.cues[0].text.contains("[OCR failed"))
        XCTAssertTrue(document.cues[0].showsOCRFailure)
        XCTAssertEqual(document.cues[0].listPrimaryText, "OCR failed · no text recognized")
        XCTAssertEqual(document.ocrFailedCount, 1)
        XCTAssertEqual(ReviewProblemBadge.make(ocrFailed: 1, lowConfidence: 0), .failed(1))

        var written = try document.srtText()
        XCTAssertTrue(written.contains("[OCR failed: no text recognized]"))
        XCTAssertTrue(written.contains("Hold on!"))

        document.setText(id: document.cues[0].id, text: "Amos, talk to me.")
        XCTAssertFalse(document.cues[0].showsOCRFailure)
        XCTAssertTrue(document.cues[0].isEdited)
        written = try document.srtText()
        XCTAssertTrue(written.contains("Amos, talk to me."))
        XCTAssertFalse(written.contains("[OCR failed"))
        XCTAssertEqual(document.ocrFailedCount, 0)
        XCTAssertNil(ReviewProblemBadge.make(ocrFailed: 0, lowConfidence: 0))
    }

    func testTypingIsOneUndoAndEscapeDropsIt() throws {
        let id = UUID()
        var document = CueDocument.recognized([
            ReviewCue(id: id, startPTS: 0, endPTS: 90_000, text: "Hello")
        ])
        XCTAssertFalse(document.hasUnsavedEdits)
        XCTAssertTrue(document.needsWriting)

        document.setText(id: id, text: "H")
        document.setText(id: id, text: "He")
        document.setText(id: id, text: "Hey")
        XCTAssertTrue(document.hasUnsavedEdits)
        XCTAssertEqual(document.editedCount, 1)
        document.undo()
        XCTAssertEqual(document.cues[0].text, "Hello")
        XCTAssertFalse(document.cues[0].isEdited)
        XCTAssertFalse(document.canUndo)
        document.redo()
        XCTAssertEqual(document.cues[0].text, "Hey")

        document.undo()
        document.setText(id: id, text: "Hey")
        document.revertCoalescedText()
        XCTAssertEqual(document.cues[0].text, "Hello")
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.canRedo)

        document.setText(id: id, text: "Hey")
        document.endTextCoalescing()
        document.setText(id: id, text: "Hey!")
        document.undo()
        XCTAssertEqual(document.cues[0].text, "Hey")
        document.undo()
        XCTAssertEqual(document.cues[0].text, "Hello")
    }

    func testRetimeRejectsAnEndBeforeTheStartAndUndoRestoresIt() throws {
        let id = UUID()
        var document = CueDocument.recognized([
            ReviewCue(id: id, startPTS: 90_000, endPTS: 180_000, text: "Hello")
        ])
        try document.setTiming(id: id, startPTS: 0, endPTS: 270_000)
        XCTAssertEqual(document.cues[0].startPTS, 0)
        XCTAssertEqual(document.cues[0].durationPTS, 270_000)
        XCTAssertTrue(document.cues[0].isEdited)
        let moved = try document.srtText()
        XCTAssertTrue(moved.contains("00:00:00,000 --> 00:00:03,000"))

        XCTAssertThrowsError(try document.setTiming(id: id, startPTS: 1_000, endPTS: 10)) { error in
            XCTAssertEqual(error as? CueEditError, .endBeforeStart)
        }
        XCTAssertEqual(document.cues[0].startPTS, 0)
        XCTAssertEqual(document.cues[0].endPTS, 270_000)

        document.undo()
        XCTAssertEqual(document.cues[0].startPTS, 90_000)
        XCTAssertEqual(document.cues[0].endPTS, 180_000)
        XCTAssertFalse(document.cues[0].isEdited)
        document.redo()
        XCTAssertEqual(document.cues[0].endPTS, 270_000)
    }

    func testDeleteRenumbersTheSRTAndUndoPutsTheCueBack() throws {
        let ids = [UUID(), UUID(), UUID()]
        var document = CueDocument.recognized([
            ReviewCue(id: ids[0], startPTS: 0, endPTS: 90_000, text: "One"),
            ReviewCue(id: ids[1], startPTS: 90_000, endPTS: 180_000, text: "Two"),
            ReviewCue(id: ids[2], startPTS: 180_000, endPTS: 270_000, text: "Three")
        ])
        XCTAssertTrue(document.delete(ids: [ids[1]]))
        XCTAssertEqual(document.cues.map(\.text), ["One", "Three"])
        let written = try document.srtText()
        XCTAssertTrue(written.hasPrefix("1\r\n"))
        XCTAssertTrue(written.contains("\r\n\r\n2\r\n"))
        XCTAssertFalse(written.contains("Two"))
        XCTAssertFalse(written.contains("\r\n3\r\n"))

        document.undo()
        XCTAssertEqual(document.cues.map(\.text), ["One", "Two", "Three"])
        XCTAssertTrue(try document.srtText().contains("\r\n3\r\n"))
    }

    func testWordByWordMergeKeepsTheFinalTextAndTheOuterTimes() throws {
        var document = revealDocument()
        let group = try XCTUnwrap(document.wordByWordGroups().first)
        XCTAssertEqual(document.wordByWordGroups().count, 1)
        XCTAssertEqual(group.cueIDs.count, 3)
        XCTAssertNil(document.group(containing: document.cues[3].id))

        let mergedID = try XCTUnwrap(document.merge(ids: group.cueIDs))
        XCTAssertEqual(document.cues.count, 2)
        XCTAssertEqual(document.cues[0].id, mergedID)
        XCTAssertEqual(document.cues[0].text, "I can save them.")
        XCTAssertEqual(document.cues[0].startPTS, 0)
        XCTAssertEqual(document.cues[0].endPTS, 270_000)
        XCTAssertTrue(document.cues[0].isEdited)
        XCTAssertTrue(document.cues[0].mergedFromWordByWord)
        XCTAssertEqual(document.cues[1].text, "Go!")

        let written = try document.srtText()
        XCTAssertTrue(written.contains("I can save them."))
        XCTAssertTrue(written.contains("00:00:00,000 --> 00:00:03,000"))
        XCTAssertFalse(written.contains("I can save\r\n"))
        XCTAssertTrue(written.contains("\r\n2\r\n"))
        XCTAssertFalse(written.contains("\r\n3\r\n"))

        document.undo()
        XCTAssertEqual(document.cues.map(\.text), ["I can", "I can save", "I can save them.", "Go!"])
        XCTAssertEqual(document.cues[0].startPTS, 0)
        XCTAssertEqual(document.cues[2].endPTS, 270_000)
        XCTAssertFalse(document.cues[0].isEdited)
    }

    func testMergeAllGroupsIsASingleUndoAndOtherMergesJoinLines() throws {
        let cues = revealDocument().cues + [
            ReviewCue(startPTS: 500_000, endPTS: 590_000, text: "Go"),
            ReviewCue(startPTS: 590_000, endPTS: 680_000, text: "Go now")
        ]
        var document = CueDocument.recognized(cues)
        XCTAssertEqual(document.wordByWordGroups().count, 2)
        XCTAssertEqual(document.mergeAllWordByWordGroups(), 2)
        XCTAssertEqual(document.cues.map(\.text), ["I can save them.", "Go!", "Go now"])
        XCTAssertEqual(document.cues[0].endPTS, 270_000)
        XCTAssertEqual(document.cues[2].startPTS, 500_000)
        XCTAssertEqual(document.cues[2].endPTS, 680_000)
        document.undo()
        XCTAssertEqual(document.cues.count, 6)
        XCTAssertFalse(document.canUndo)

        let joined = try XCTUnwrap(document.merge(ids: [document.cues[3].id, document.cues[4].id]))
        XCTAssertEqual(document.cues.first { $0.id == joined }?.text, "Go!\nGo")
        let written = try document.srtText()
        XCTAssertTrue(written.contains("Go!\r\nGo"))
    }

    func testAPrefixThatIsNotANewWordIsNotAReveal() {
        let cues = [
            ReviewCue(startPTS: 0, endPTS: 90_000, text: "I"),
            ReviewCue(startPTS: 90_000, endPTS: 180_000, text: "I'll be right behind you.")
        ]
        XCTAssertTrue(WordByWordDetection.groups(in: cues).isEmpty)
        XCTAssertFalse(WordByWordDetection.textExtends("I", "I'll"))
        XCTAssertTrue(WordByWordDetection.textExtends("I can", "I can save"))

        let gapped = [
            ReviewCue(startPTS: 0, endPTS: 90_000, text: "I can"),
            ReviewCue(startPTS: 200_000, endPTS: 290_000, text: "I can save")
        ]
        XCTAssertTrue(WordByWordDetection.groups(in: gapped).isEmpty)
    }

    func testSaveSnapshotUndoAndDiscard() throws {
        let id = UUID()
        var document = CueDocument.recognized([
            ReviewCue(id: id, startPTS: 0, endPTS: 90_000, text: "Hello")
        ])
        document.noteSaved()
        XCTAssertFalse(document.needsWriting)
        document.setText(id: id, text: "Hello there")
        XCTAssertTrue(document.needsWriting)
        XCTAssertTrue(document.hasUnsavedEdits)
        document.noteSaved()
        XCTAssertFalse(document.hasUnsavedEdits)
        document.undo()
        XCTAssertEqual(document.cues[0].text, "Hello")
        XCTAssertTrue(document.needsWriting)
        document.discardUnsavedEdits()
        XCTAssertEqual(document.cues[0].text, "Hello there")
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.needsWriting)
    }

    func testLowConfidenceIsStoredWithoutBecomingAFailure() {
        var cue = ReviewCue(startPTS: 0, endPTS: 90_000, text: "Renember Eros.", confidence: 0.41, lowConfidencePercent: 41)
        XCTAssertTrue(cue.showsLowConfidence)
        XCTAssertFalse(cue.showsOCRFailure)
        XCTAssertEqual(cue.listPrimaryText, "Renember Eros.")
        XCTAssertEqual(ReviewProblemBadge.make(ocrFailed: 2, lowConfidence: 3), .toCheck(5))
        XCTAssertEqual(ReviewProblemBadge.make(ocrFailed: 2, lowConfidence: 3)?.label, "5 to check")
        XCTAssertEqual(ReviewProblemBadge.make(ocrFailed: 1, lowConfidence: 0)?.accessibilityLabel, "1 OCR failed")
        cue.lowConfidencePercent = nil
        XCTAssertFalse(cue.showsLowConfidence)
        XCTAssertFalse(ReviewCue(startPTS: 0, endPTS: 1, text: "Hi", confidence: 0.2).showsLowConfidence)
    }

    func testBatchOrderSkipsCleanSavedFilesAndWritePlanReusesApproval() {
        let first = UUID()
        let clean = UUID()
        let held = UUID()
        let entries = [
            ReviewQueueEntry(id: first, needsReview: true),
            ReviewQueueEntry(id: clean, needsReview: false),
            ReviewQueueEntry(id: held, needsReview: true)
        ]
        XCTAssertEqual(ReviewBatchOrder.position(of: first, in: entries)?.index, 1)
        XCTAssertEqual(ReviewBatchOrder.position(of: first, in: entries)?.total, 2)
        XCTAssertNil(ReviewBatchOrder.position(of: clean, in: entries))
        XCTAssertEqual(ReviewBatchOrder.nextReviewFile(after: first, in: entries), held)
        XCTAssertEqual(ReviewBatchOrder.nextReviewFile(after: held, in: entries), first)
        XCTAssertEqual(ReviewBatchOrder.nextReviewFile(after: clean, in: entries), first)
        XCTAssertNil(ReviewBatchOrder.nextReviewFile(after: first, in: [entries[0]]))
        XCTAssertTrue(ReviewBatchOrder.needsReview(problemCount: 0, needsWriting: true))
        XCTAssertTrue(ReviewBatchOrder.needsReview(problemCount: 1, needsWriting: false))
        XCTAssertFalse(ReviewBatchOrder.needsReview(problemCount: 0, needsWriting: false))

        let exists: (String) -> Bool = { $0 == "/films/Other.srt" }
        XCTAssertEqual(
            ReviewWritePlanner.plan(path: "/films/Movie.srt", plannedPath: "/films/Movie.srt", savedPath: nil, fileExists: exists),
            .write
        )
        XCTAssertEqual(
            ReviewWritePlanner.plan(path: "/films/Movie.srt", plannedPath: "/films/Movie.srt", savedPath: "/films/Movie.srt", fileExists: exists),
            .write
        )
        XCTAssertEqual(
            ReviewWritePlanner.plan(path: "/films/Other.srt", plannedPath: "/films/Movie.srt", savedPath: "/films/Movie.srt", fileExists: exists),
            .confirmReplace
        )
        XCTAssertEqual(
            ReviewWritePlanner.plan(path: "/films/New.srt", plannedPath: "/films/Movie.srt", savedPath: nil, fileExists: exists),
            .write
        )
    }

    func testClockParsesSRTTimesAndStepsByATenthOfASecond() {
        XCTAssertEqual(CueClock.parse("00:00:01,000"), 90_000)
        XCTAssertEqual(CueClock.parse("00:00:01.500"), 135_000)
        XCTAssertEqual(CueClock.parse("01:02:03,004"), CueClock.parse(SRTWriter.timestamp(pts: CueClock.parse("01:02:03,004")!)))
        XCTAssertNil(CueClock.parse("tomorrow"))
        XCTAssertNil(CueClock.parse("00:60:00,000"))
        XCTAssertEqual(CueClock.nudging(0, bySteps: -2), 0)
        XCTAssertEqual(CueClock.nudging(0, bySteps: 1), CueClock.stepPTS)
        XCTAssertEqual(CueClock.end(start: 90_000, duration: 90_000), 180_000)
    }

    func testPicturesRoundTripInATempFolderAndAreRemovedWithTheSession() throws {
        let image = SubtitleImage(
            width: 2,
            height: 1,
            rgba: [1, 2, 3, 255, 4, 5, 6, 128],
            originX: 8,
            originY: 9,
            videoWidth: 1920,
            videoHeight: 1080
        )
        let pictureID = UUID()
        let directory = try XCTUnwrap(CuePictureFiles.write([pictureID: image]))
        XCTAssertEqual(CuePictureFiles.read(id: pictureID, from: directory), image)

        let foreign = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-review-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: foreign)
        CuePictureFiles.remove(foreign.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        try FileManager.default.removeItem(at: foreign)

        var session: CuePictureSession? = CuePictureSession()
        let itemID = UUID()
        session?.store(directory, for: itemID)
        XCTAssertEqual(session?.directory(for: itemID), directory)
        session = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testKeptPicturesAreSpilledAndAFailureFieldStaysEmpty() async throws {
        let failedImage = SubtitleImage(
            width: 1, height: 1, rgba: [1, 0, 0, 255],
            originX: 1, originY: 2, videoWidth: 10, videoHeight: 10
        )
        let okImage = SubtitleImage(
            width: 1, height: 1, rgba: [2, 0, 0, 255],
            originX: 3, originY: 4, videoWidth: 10, videoHeight: 10
        )
        let pipeline = TranscriptionPipeline(keepPictures: true)
        let result = try await pipeline.transcribe(
            cues: [
                SubtitleCue(startPTS: 0, endPTS: 90_000, image: failedImage, forced: false, endReason: .clearingDisplaySet),
                SubtitleCue(startPTS: 90_000, endPTS: 180_000, image: okImage, forced: false, endReason: .clearingDisplaySet)
            ],
            recognizer: PixelRecognizer()
        )
        XCTAssertTrue(result.cues[0].text.contains("[OCR failed"))
        XCTAssertEqual(result.captured[0].text, "")
        XCTAssertEqual(result.captured[0].failureMessage, TranscriptionPipeline.noTextMessage)
        XCTAssertEqual(result.captured[1].text, "Hello")
        XCTAssertNil(result.captured[1].failureMessage)
        XCTAssertEqual(result.captured[1].confidence, 0.95)
        XCTAssertTrue(result.captured[0].alternatives.isEmpty)

        let packed = ReviewArchive.pack(result)
        let directory = try XCTUnwrap(packed.pictureDirectory)
        defer { CuePictureFiles.remove(directory) }
        XCTAssertEqual(packed.document.cues[0].text, "")
        XCTAssertTrue(packed.document.cues[0].showsOCRFailure)
        XCTAssertEqual(packed.document.cues[1].text, "Hello")
        let storedID = try XCTUnwrap(packed.document.cues[1].pictureID)
        XCTAssertEqual(CuePictureFiles.read(id: storedID, from: directory), okImage)
        let written = try packed.document.srtText()
        XCTAssertTrue(written.contains("[OCR failed: no text recognized]"))
        XCTAssertTrue(written.contains("Hello"))
        XCTAssertFalse(packed.document.cues[0].text.contains("Hello"))
    }

    func testFifteenHundredCuesStayEditable() throws {
        var cues: [ReviewCue] = []
        cues.reserveCapacity(1_500)
        for index in 0..<1_500 {
            let start = UInt32(index) * 90_000
            let text = index < 3 ? ["I can", "I can save", "I can save them."][index] : "Cue \(index)"
            cues.append(ReviewCue(startPTS: start, endPTS: start + 90_000, text: text))
        }
        var document = CueDocument.recognized(cues)
        let started = Date()
        let group = try XCTUnwrap(document.wordByWordGroups().first)
        _ = document.merge(ids: group.cueIDs)
        document.setText(id: document.cues[10].id, text: "Edited cue")
        try document.setTiming(id: document.cues[10].id, startPTS: document.cues[10].startPTS, endPTS: document.cues[10].endPTS + 9_000)
        _ = document.delete(ids: [document.cues[20].id])
        document.undo()
        document.undo()
        document.undo()
        document.undo()
        let written = try document.srtText()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(document.cues.count, 1_500)
        XCTAssertTrue(written.contains("I can save them."))
        XCTAssertTrue(written.contains("Cue 1499"))
        XCTAssertFalse(written.isEmpty)
    }

    private func revealDocument() -> CueDocument {
        CueDocument.recognized([
            ReviewCue(startPTS: 0, endPTS: 90_000, text: "I can"),
            ReviewCue(startPTS: 90_000, endPTS: 180_000, text: "I can save"),
            ReviewCue(startPTS: 180_000, endPTS: 270_000, text: "I can save them."),
            ReviewCue(startPTS: 360_000, endPTS: 450_000, text: "Go!")
        ])
    }
}

private struct PixelRecognizer: SubtitleRecognizing {
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        if image.rgba.first == 1 {
            return OCRResult(text: "", confidence: 0.1)
        }
        return OCRResult(
            text: "Hello",
            confidence: 0.95,
            lines: [RecognizedLine(text: "Hello", confidence: 0.95, top: 0, left: 0, height: 1)]
        )
    }
}
