import XCTest
import PGSCore

final class TranscriptionPipelineTests: XCTestCase {
    func testReadingOrderAndItalicTagsAndCleanup() async throws {
        let pipeline = TranscriptionPipeline(languages: ["en-US"], maxConcurrent: 1)
        let result = try await pipeline.transcribe(
            cues: [sampleCue(width: 8, start: 90_000)],
            recognizer: FixedLinesRecognizer(lines: [
                RecognizedLine(text: "bottom", confidence: 0.9, isItalic: false, top: 40, left: 0, height: 10),
                RecognizedLine(text: "right", confidence: 0.8, isItalic: false, top: 0, left: 30, height: 10),
                RecognizedLine(text: "l  am", confidence: 0.7, isItalic: true, top: 1, left: 0, height: 10),
                RecognizedLine(text: "there", confidence: 0.7, isItalic: true, top: 2, left: 12, height: 10)
            ])
        )
        XCTAssertEqual(result.cues.count, 1)
        XCTAssertEqual(result.cues[0].text, "<i>I am there</i> right\nbottom")
        XCTAssertEqual(result.cues[0].startPTS, 90_000)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(
            result.srt,
            "1\r\n00:00:01,000 --> 00:00:02,000\r\n<i>I am there</i> right\r\nbottom\r\n"
        )
    }

    func testFlatTextIsSplitCleanedAndKeptInOrder() async throws {
        let pipeline = TranscriptionPipeline()
        let result = try await pipeline.transcribe(
            cues: [sampleCue(width: 4, start: 0)],
            recognizer: FixedTextRecognizer(text: "l  am\n\nfine  .")
        )
        XCTAssertEqual(result.cues[0].text, "I am\nfine.")
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testEmptyAndFailedCuesStayInTheFile() async throws {
        let pipeline = TranscriptionPipeline(maxConcurrent: 3)
        let cues = [
            sampleCue(width: 30, start: 0),
            sampleCue(width: 1, start: 90_000),
            sampleCue(width: 2, start: 180_000)
        ]
        let result = try await pipeline.transcribe(cues: cues, recognizer: MixedRecognizer())
        XCTAssertEqual(result.cues.map(\.text), [
            "w30",
            "[OCR failed: no text recognized]",
            "[OCR failed: the picture was unreadable]"
        ])
        XCTAssertEqual(result.failures.map(\.cueIndex), [1, 2])
        XCTAssertEqual(result.failures[0].description, "Cue 2 at 00:00:01,000: no text recognized")
        XCTAssertEqual(result.cues[2].startPTS, 180_000)
        XCTAssertEqual(result.cues.count, 3)
        XCTAssertTrue(result.srt.contains("w30"))
        XCTAssertTrue(result.srt.contains("[OCR failed: no text recognized]"))
    }

    func testErrorTextIsOneShortLine() async throws {
        let pipeline = TranscriptionPipeline()
        let result = try await pipeline.transcribe(
            cues: [sampleCue(width: 3, start: 0)],
            recognizer: ThrowingRecognizer(error: MultilineFailure())
        )
        XCTAssertEqual(result.failures[0].message, "bad picture")
        let long = try await pipeline.transcribe(
            cues: [sampleCue(width: 3, start: 0)],
            recognizer: ThrowingRecognizer(error: LongFailure())
        )
        XCTAssertEqual(long.failures[0].message.count, 181)
        XCTAssertTrue(long.failures[0].message.hasSuffix("…"))
    }

    func testFrenchDoesNotApplyTheEnglishPronounFix() async throws {
        let pipeline = TranscriptionPipeline(languages: ["fr-FR"])
        let result = try await pipeline.transcribe(
            cues: [sampleCue(width: 4, start: 0)],
            recognizer: FixedTextRecognizer(text: "l pense")
        )
        XCTAssertEqual(result.cues[0].text, "l pense")
    }

    func testCustomCleanerIsKept() {
        let pipeline = TranscriptionPipeline(
            languages: ["en-US"],
            cleaner: OCRTextCleaner(fixEnglishPronounI: false)
        )
        XCTAssertFalse(pipeline.cleaner.fixEnglishPronounI)
        XCTAssertEqual(TranscriptionPipeline(maxConcurrent: 0).maxConcurrent, 1)
    }

    func testConcurrentResultsStayInCueOrderAndProgressCountsEachFinish() async throws {
        let pipeline = TranscriptionPipeline(maxConcurrent: 3)
        let cues = [
            sampleCue(width: 30, start: 0),
            sampleCue(width: 10, start: 90_000),
            sampleCue(width: 20, start: 180_000)
        ]
        let progress = ProgressBox()
        let result = try await pipeline.transcribe(cues: cues, recognizer: DelayedRecognizer()) { update in
            progress.add(update)
        }
        XCTAssertEqual(result.cues.map(\.text), ["w30", "w10", "w20"])
        XCTAssertEqual(progress.values.map(\.completed), [1, 2, 3])
        XCTAssertEqual(progress.values.map(\.total), [3, 3, 3])
        XCTAssertEqual(Set(progress.values.map(\.cueIndex)), [0, 1, 2])
    }

    func testSequentialProgressFollowsCueOrder() async throws {
        let pipeline = TranscriptionPipeline(maxConcurrent: 1)
        let progress = ProgressBox()
        _ = try await pipeline.transcribe(
            cues: [sampleCue(width: 4, start: 0), sampleCue(width: 5, start: 90_000)],
            recognizer: FixedTextRecognizer(text: "Hi"),
            progress: { progress.add($0) }
        )
        XCTAssertEqual(progress.values.map(\.cueIndex), [0, 1])
    }

    func testCancellationThrowsAndDoesNotReturnAPartialFile() async {
        let pipeline = TranscriptionPipeline(maxConcurrent: 2)
        let task = Task {
            try await pipeline.transcribe(
                cues: [sampleCue(width: 4, start: 0), sampleCue(width: 5, start: 90_000)],
                recognizer: SleepyRecognizer()
            )
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testEmptyBatchAndDecodedSup() async throws {
        let pipeline = TranscriptionPipeline()
        let empty = try await pipeline.transcribe(cues: [], recognizer: FixedTextRecognizer(text: "nope"))
        XCTAssertEqual(empty.srt, "")
        XCTAssertEqual(empty.cues.count, 0)

        let file = makeShow(pts: 90_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
            + makeClear(pts: 180_000)
        let seen = LanguageBox()
        let result = try await pipeline.transcribeFile(data: file, recognizer: seen)
        XCTAssertEqual(seen.languages, ["en-US"])
        XCTAssertEqual(result.srt, "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello world\r\n")
        XCTAssertEqual(result.cues[0].text, "Hello world")
        XCTAssertTrue(result.failures.isEmpty)
    }
}

final class ReadingOrderTests: XCTestCase {
    func testRowsRunTopToBottomAndLeftToRight() {
        let rows = ReadingOrder.rows(from: [
            RecognizedLine(text: "b", top: 20, left: 5, height: 8),
            RecognizedLine(text: "a-right", top: 1, left: 15, height: 8),
            RecognizedLine(text: "a-left", top: 0, left: 0, height: 8)
        ])
        XCTAssertEqual(rows.map { $0.map(\.text) }, [["a-left", "a-right"], ["b"]])
    }

    func testSeparatedLinesStayApart() {
        let rows = ReadingOrder.rows(from: [
            RecognizedLine(text: "one", top: 0, left: 0, height: 10),
            RecognizedLine(text: "two", top: 30, left: 0, height: 10)
        ])
        XCTAssertEqual(rows.count, 2)
    }
}

private func sampleCue(width: Int, start: UInt32) -> SubtitleCue {
    SubtitleCue(
        startPTS: start,
        endPTS: start + 90_000,
        image: SubtitleImage(
            width: width,
            height: 1,
            rgba: [UInt8](repeating: 0, count: width * 4),
            originX: 0,
            originY: 0,
            videoWidth: 100,
            videoHeight: 100
        ),
        forced: false,
        endReason: .clearingDisplaySet
    )
}

private struct FixedTextRecognizer: SubtitleRecognizing {
    var text: String
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        OCRResult(text: text)
    }
}

private struct FixedLinesRecognizer: SubtitleRecognizing {
    var lines: [RecognizedLine]
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        OCRResult(text: lines.map(\.text).joined(separator: "\n"), lines: lines)
    }
}

private struct MixedRecognizer: SubtitleRecognizing {
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        if image.width == 30 {
            try await Task.sleep(nanoseconds: 40_000_000)
            return OCRResult(text: "w30")
        }
        if image.width == 1 {
            return OCRResult(text: "   ")
        }
        throw SampleFailure()
    }
}

private struct SampleFailure: Error, LocalizedError {
    var errorDescription: String? { "the picture was unreadable" }
}

private struct MultilineFailure: Error, LocalizedError {
    var errorDescription: String? { "bad\npicture" }
}

private struct LongFailure: Error, LocalizedError {
    var errorDescription: String? { String(repeating: "a", count: 250) }
}

private struct ThrowingRecognizer: SubtitleRecognizing {
    var error: Error
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        throw error
    }
}

private struct DelayedRecognizer: SubtitleRecognizing {
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        let delay: UInt64 = image.width == 30 ? 80_000_000 : 5_000_000
        try await Task.sleep(nanoseconds: delay)
        return OCRResult(text: "w\(image.width)")
    }
}

private struct SleepyRecognizer: SubtitleRecognizing {
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        try await Task.sleep(nanoseconds: 4_000_000_000)
        return OCRResult(text: "late")
    }
}

private final class LanguageBox: SubtitleRecognizing, @unchecked Sendable {
    var languages: [String] = []
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        self.languages = languages
        return OCRResult(text: "Hello  world")
    }
}

private final class ProgressBox: @unchecked Sendable {
    var values: [TranscriptionProgress] = []
    func add(_ value: TranscriptionProgress) { values.append(value) }
}
