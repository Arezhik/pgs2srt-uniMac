import XCTest
@testable import PGSCore

final class ConversionQueueTests: XCTestCase {
    func testWaitingBecomesConvertingThenDoneWithCueCounts() async {
        let gate = Gate()
        let script = Script()
        let queue = await makeQueue(script: script) { work in
            script.record(work)
            work.progress(TranscriptionProgress(completed: 2, total: 5, cueIndex: 1))
            try await gate.wait()
            return sampleResult(cues: 5, failures: 2)
        }
        await queue.add(paths: ["/films/Movie.sup"])
        let sawProgress = await waitUntil(queue) { queue in
            queue.items.first?.status == .converting(completed: 2, total: 5)
        }
        XCTAssertTrue(sawProgress)
        gate.openAll()
        let finished = await waitUntil(queue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .done(cueCount: 5, unrecognizedCount: 2, outputPath: "/films/Movie.srt"))
        let writes = script.writes
        XCTAssertEqual(writes.map(\.0), ["/films/Movie.srt"])
        XCTAssertEqual(writes.map(\.1), [sampleResult(cues: 5, failures: 2).srt])
        let work = script.works[0]
        XCTAssertEqual(work.languages, ["en-US"])
        XCTAssertEqual(work.maxConcurrent, 4)
        XCTAssertFalse(work.italics)
    }

    func testDecoderErrorsStayReadableAndDoNotWrite() async {
        let script = Script()
        let queue = await makeQueue(script: script) { _ in
            throw PGSError.emptyInput
        }
        let outcome = await finish(queue, paths: ["/films/Bad.sup"], script: script)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .failed("The PGS file is empty."))
        XCTAssertTrue(script.writes.isEmpty)
        XCTAssertEqual(outcome, BatchOutcome(done: 0, failed: 1, cancelled: 0, skipped: 0))
    }

    func testARealEmptyFileUsesTheDecoderMessage() async {
        let script = Script()
        let queue = await makeQueue(script: script) { work in
            try await TranscriptionPipeline.run(work, recognizer: HelloRecognizer())
        }
        await queue.add(paths: ["/films/Empty.sup"])
        let finished = await waitUntil(queue) { queue in
            if case .failed = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .failed(PGSError.emptyInput.description))
    }

    func testPipelineWritesTheRecognizedCueAndLeavesItalicsOff() async {
        let script = Script(bytes: [
            "/films/Movie.sup": makeShow(pts: 90_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
                + makeClear(pts: 180_000)
        ])
        let queue = await makeQueue(script: script) { work in
            try await TranscriptionPipeline.run(work, recognizer: HelloRecognizer())
        }
        await queue.add(paths: ["/films/Movie.sup"])
        let finished = await waitUntil(queue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        let item = await queue.items[0]
        guard case let .done(cues, unrecognized, path) = item.status else {
            return XCTFail("expected done, got \(item.status)")
        }
        XCTAssertEqual(cues, 1)
        XCTAssertEqual(unrecognized, 0)
        XCTAssertEqual(path, "/films/Movie.srt")
        XCTAssertTrue(script.writes[0].1.contains("Hello"))
        XCTAssertFalse(script.writes[0].1.contains("<i>"))
    }

    func testExperimentalItalicsIsPassedThrough() async throws {
        var preferences = ConversionPreferences.default
        preferences.experimentalItalics = true
        preferences.language = " fr-FR "
        preferences.concurrency = 2
        let script = Script(bytes: [
            "/films/Movie.sup": makeShow(pts: 90_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
                + makeClear(pts: 180_000)
        ])
        let queue = await makeQueue(preferences: preferences, script: script) { work in
            script.record(work)
            return try await TranscriptionPipeline.run(work, recognizer: HelloRecognizer())
        }
        await queue.add(paths: ["/films/Movie.sup"])
        let finished = await waitUntil(queue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        let work = script.works[0]
        XCTAssertEqual(work.languages, ["fr-FR"])
        XCTAssertEqual(work.maxConcurrent, 2)
        XCTAssertTrue(work.italics)
        XCTAssertTrue(script.writes[0].1.contains("<i>Hello</i>"))
    }

    func testSkipDoesNotConvertAndNamesCollisionsInsideABatch() async {
        let script = Script(files: ["/out/Movie.srt"])
        var preferences = ConversionPreferences.default
        preferences.placement = .folder("/out")
        preferences.existingFile = .addNumber
        let queue = await makeQueue(preferences: preferences, script: script) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        let outcome = await finish(queue, paths: ["/a/Movie.sup", "/b/Movie.sup", "/c/Other.sup"], script: script)
        let items = await queue.items
        XCTAssertEqual(items.map(\.status), [
            .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/out/Movie 2.srt"),
            .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/out/Movie 3.srt"),
            .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/out/Other.srt")
        ])
        XCTAssertEqual(outcome?.done, 3)

        preferences.existingFile = .skip
        let skipping = await makeQueue(preferences: preferences, script: script) { _ in
            sampleResult()
        }
        await skipping.add(paths: ["/a/Movie.sup"])
        let skipped = await waitUntil(skipping) { queue in
            if case .skipped = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(skipped)
        let skippedItem = await skipping.items[0]
        XCTAssertEqual(
            skippedItem.status,
            .skipped("Movie.srt already exists, so this file was skipped.")
        )
        XCTAssertTrue(script.writes.filter { $0.0 == "/out/Movie.srt" }.isEmpty)
    }

    func testOverwriteKeepsBothFilesWhenTwoSourcesShareAName() async {
        let script = Script()
        var preferences = ConversionPreferences.default
        preferences.placement = .folder("/out")
        preferences.existingFile = .overwrite
        let queue = await makeQueue(preferences: preferences, script: script) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        _ = await finish(queue, paths: ["/a/Movie.sup", "/b/Movie.sup"], script: script)
        let items = await queue.items
        XCTAssertEqual(items[0].status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/out/Movie.srt"))
        XCTAssertEqual(items[1].status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/out/Movie 2.srt"))
    }

    func testCancellingAWaitingFileDoesNotConvertIt() async {
        let gate = Gate()
        defer { gate.openAll() }
        let script = Script()
        let queue = await makeQueue(script: script) { work in
            script.record(work)
            try await gate.wait()
            return sampleResult()
        }
        await queue.add(paths: ["/films/First.sup", "/films/Second.sup"])
        let started = await waitUntil(queue) { queue in
            if case .converting = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(started)
        let second = await queue.items[1].id
        await queue.cancel(id: second)
        let secondStatus = await queue.items[1].status
        XCTAssertEqual(secondStatus, .cancelled)
        XCTAssertEqual(script.works.count, 1)
        gate.openAll()
        let finished = await waitUntil(queue) { queue in
            !queue.items.contains(where: \.status.isActive)
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(script.works.count, 1)
        let firstStatus = await queue.items[0].status
        if case .done = firstStatus {} else {
            XCTFail("the first file should finish, got \(firstStatus)")
        }
    }

    func testCancelStopsTheFileThatIsRunningAndDoesNotWrite() async {
        let gate = Gate()
        defer { gate.openAll() }
        let script = Script()
        let box = OutcomeBox()
        let queue = await makeQueue(script: script) { _ in
            try await gate.wait()
            return sampleResult()
        }
        await MainActor.run {
            queue.onBatchFinished = { box.append($0) }
        }
        await queue.add(paths: ["/films/Movie.sup"])
        let started = await waitUntil(queue) { queue in
            if case .converting = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(started)
        let id = await queue.items[0].id
        await queue.cancel(id: id)
        let cancelled = await waitUntil(queue) { queue in
            queue.items.first?.status == .cancelled
        }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(script.writes.isEmpty)
        let notified = await waitUntil(queue) { _ in box.outcomes.count == 1 }
        XCTAssertTrue(notified)
        XCTAssertEqual(box.outcomes, [BatchOutcome(done: 0, failed: 0, cancelled: 1, skipped: 0)])
    }

    func testCancelAllStopsTheBatch() async {
        let gate = Gate()
        defer { gate.openAll() }
        let script = Script()
        let box = OutcomeBox()
        let queue = await makeQueue(script: script) { _ in
            try await gate.wait()
            return sampleResult()
        }
        await MainActor.run {
            queue.onBatchFinished = { box.append($0) }
        }
        await queue.add(paths: ["/films/First.sup", "/films/Second.sup"])
        _ = await waitUntil(queue) { queue in
            if case .converting = queue.items.first?.status { return true }
            return false
        }
        await queue.cancelAll()
        let finished = await waitUntil(queue) { _ in box.outcomes.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(box.outcomes, [BatchOutcome(done: 0, failed: 0, cancelled: 2, skipped: 0)])
        XCTAssertTrue(script.writes.isEmpty)
        let stillWorking = await queue.hasCancellableWork
        XCTAssertFalse(stillWorking)
    }

    func testASecondBatchDoesNotKeepTheFirstBatchCounts() async {
        let script = Script()
        let box = OutcomeBox()
        let queue = await makeQueue(script: script) { _ in
            if script.bump() == 1 {
                return sampleResult(cues: 1, failures: 0)
            }
            throw PGSError.emptyInput
        }
        await MainActor.run {
            queue.onBatchFinished = { box.append($0) }
        }
        await queue.add(paths: ["/films/One.sup"])
        let first = await waitUntil(queue) { _ in box.outcomes.count == 1 }
        XCTAssertTrue(first)
        await queue.add(paths: ["/films/Two.sup"])
        let second = await waitUntil(queue) { _ in box.outcomes.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(box.outcomes[0], BatchOutcome(done: 1, failed: 0, cancelled: 0, skipped: 0))
        XCTAssertEqual(box.outcomes[1], BatchOutcome(done: 0, failed: 1, cancelled: 0, skipped: 0))
    }

    func testMkvWithoutToolNixIsSkippedWithADownloadLink() async {
        let script = Script()
        let box = OutcomeBox()
        let queue = await makeQueue(script: script) { _ in sampleResult() }
        await MainActor.run {
            queue.onBatchFinished = { box.append($0) }
        }
        await queue.add(paths: ["/films/Movie.mkv"])
        let finished = await waitUntil(queue) { _ in box.outcomes.count == 1 }
        XCTAssertTrue(finished)
        let item = await queue.items[0]
        XCTAssertEqual(item.name, "Movie.mkv")
        XCTAssertEqual(item.status, .skipped(MKVCopy.needsToolNix))
        XCTAssertTrue(MKVCopy.needsToolNix.contains("https://mkvtoolnix.download"))
        XCTAssertEqual(box.outcomes, [BatchOutcome(done: 0, failed: 0, cancelled: 0, skipped: 1)])
        XCTAssertTrue(script.works.isEmpty)
    }

    func testFolderDropQueuesTheSupFilesInside() async {
        let script = Script(directories: [
            "/clips": ["/clips/A.sup", "/clips/nested"],
            "/clips/nested": ["/clips/nested/B.sup"]
        ])
        let queue = await makeQueue(script: script) { _ in sampleResult(cues: 1, failures: 0) }
        _ = await finish(queue, paths: ["/clips"], script: script)
        let names = await queue.items.map(\.name)
        XCTAssertEqual(names, ["A.sup", "B.sup"])
    }

    func testEmptyFolderShowsABanner() async {
        let script = Script(directories: ["/clips": []])
        let queue = await makeQueue(script: script) { _ in sampleResult() }
        await queue.add(paths: ["/clips"])
        let banners = await queue.banners
        XCTAssertEqual(banners, ["No .sup or .mkv files were found in clips."])
        let queued = await queue.items
        XCTAssertTrue(queued.isEmpty)
        await queue.dismissBanner(at: 0)
        let remaining = await queue.banners
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAnActiveFileIsNotQueuedTwice() async {
        let gate = Gate()
        defer { gate.openAll() }
        let script = Script()
        let queue = await makeQueue(script: script) { _ in
            try await gate.wait()
            return sampleResult()
        }
        await queue.add(paths: ["/films/Movie.sup"])
        _ = await waitUntil(queue) { queue in
            if case .converting = queue.items.first?.status { return true }
            return false
        }
        await queue.add(paths: ["/films/Movie.sup"])
        let whileActive = await queue.items.count
        XCTAssertEqual(whileActive, 1)
        gate.openAll()
        _ = await waitUntil(queue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        await queue.add(paths: ["/films/Movie.sup"])
        let afterDone = await queue.items.count
        XCTAssertEqual(afterDone, 2)
    }

    func testSettingsRoundTripAndDefaults() {
        XCTAssertFalse(ConversionPreferences.default.experimentalItalics)
        XCTAssertEqual(ConversionPreferences.default.language, "en-US")
        XCTAssertEqual(ConversionPreferences.default.concurrency, 4)
        XCTAssertEqual(ConversionPreferences.default.saveTiming, .immediately)
        let suite = "pgs2srt.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(ConversionPreferenceStore.load(from: defaults), .default)

        let saved = ConversionPreferences(
            placement: .folder("/subtitles"),
            language: "ja-JP",
            existingFile: .addNumber,
            concurrency: 3,
            experimentalItalics: true,
            chooseMKVTrack: true,
            saveTiming: .afterReview
        )
        ConversionPreferenceStore.save(saved, to: defaults)
        XCTAssertEqual(ConversionPreferenceStore.load(from: defaults), saved)
        XCTAssertEqual(defaults.string(forKey: ConversionPreferenceKey.placement), ConversionPreferenceKey.placementFolder)
        XCTAssertEqual(defaults.bool(forKey: ConversionPreferenceKey.italics), true)
        XCTAssertEqual(defaults.bool(forKey: ConversionPreferenceKey.chooseMKVTrack), true)
        XCTAssertEqual(defaults.string(forKey: ConversionPreferenceKey.saveTiming), SaveTiming.afterReview.rawValue)
        XCTAssertFalse(ConversionPreferences.default.chooseMKVTrack)

        defaults.set(0, forKey: ConversionPreferenceKey.concurrency)
        defaults.set("  ", forKey: ConversionPreferenceKey.language)
        defaults.set("nope", forKey: ConversionPreferenceKey.existingFile)
        let repaired = ConversionPreferenceStore.load(from: defaults)
        XCTAssertEqual(repaired.concurrency, 1)
        XCTAssertEqual(repaired.language, "en-US")
        XCTAssertEqual(repaired.existingFile, .overwrite)
        XCTAssertTrue(repaired.chooseMKVTrack)
        XCTAssertEqual(repaired.saveTiming, .afterReview)
        XCTAssertEqual(defaults.integer(forKey: ConversionPreferenceKey.concurrency), 1)
    }

    func testCancelDuringDecodeWritesNothing() async throws {
        let file = makeShow(pts: 90_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
        let script = Script(bytes: ["/films/Movie.sup": file])
        let pause = DecodePause()
        defer { pause.end() }
        let recognizer = CallCounter()
        let queue = await makeQueue(script: script) { work in
            var decoder = PGSDecoder()
            decoder.cancellationCheck = { try pause.check() }
            return try await TranscriptionPipeline().transcribeFile(
                data: work.data,
                decoder: decoder,
                recognizer: recognizer
            )
        }
        await queue.add(paths: ["/films/Movie.sup"])
        let insideDecode = await pause.waitUntilBlocked()
        XCTAssertTrue(insideDecode)
        let id = await queue.items[0].id
        await queue.cancel(id: id)
        let cancelled = await waitUntil(queue) { queue in
            queue.items.first?.status == .cancelled
        }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(script.writes.isEmpty)
        XCTAssertEqual(recognizer.count, 0)
        let stillWorking = await queue.hasCancellableWork
        XCTAssertFalse(stillWorking)
    }

    func testCancelAllDuringDecodeCancelsTheActiveFileAndTheWaitingOne() async {
        let file = makeShow(pts: 90_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
        let script = Script(bytes: [
            "/films/First.sup": file,
            "/films/Second.sup": file
        ])
        let box = OutcomeBox()
        let pause = DecodePause()
        defer { pause.end() }
        let recognizer = CallCounter()
        let queue = await makeQueue(script: script) { work in
            var decoder = PGSDecoder()
            decoder.cancellationCheck = { try pause.check() }
            return try await TranscriptionPipeline().transcribeFile(
                data: work.data,
                decoder: decoder,
                recognizer: recognizer
            )
        }
        await MainActor.run {
            queue.onBatchFinished = { box.append($0) }
        }
        await queue.add(paths: ["/films/First.sup", "/films/Second.sup"])
        let insideDecode = await pause.waitUntilBlocked()
        XCTAssertTrue(insideDecode)
        await queue.cancelAll()
        let finished = await waitUntil(queue) { _ in box.outcomes.count == 1 }
        XCTAssertTrue(finished)
        let items = await queue.items
        XCTAssertEqual(items.map(\.status), [.cancelled, .cancelled])
        XCTAssertEqual(box.outcomes, [BatchOutcome(done: 0, failed: 0, cancelled: 2, skipped: 0)])
        XCTAssertTrue(script.writes.isEmpty)
        XCTAssertEqual(recognizer.count, 0)
    }

    func testDecodeStopsWhenTheTaskIsAlreadyCancelled() async {
        let file = makeShow(pts: 90_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
        let hold = TaskHold()
        let recognizer = CallCounter()
        let task = Task {
            await hold.park()
            return try await TranscriptionPipeline().transcribeFile(data: file, recognizer: recognizer)
        }
        let parked = await hold.waitUntilParked()
        XCTAssertTrue(parked)
        task.cancel()
        hold.release()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(recognizer.count, 0)
    }

    func testSourceFileReadMatchesTheBytesAndStopsWhenCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgs2srt-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("movie.sup")
        let payload = Data((0..<64).map { UInt8($0) })
        try payload.write(to: url)
        let read = try SourceFileBytes.read(url.path)
        XCTAssertEqual(read, payload)

        let hold = TaskHold()
        let task = Task {
            await hold.park()
            return try SourceFileBytes.read(url.path)
        }
        let parked = await hold.waitUntilParked()
        XCTAssertTrue(parked)
        task.cancel()
        hold.release()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testOverwriteAsksAndSkipLeavesTheExistingFile() async {
        let script = Script(files: ["/films/Movie.srt"])
        let asks = AnswerBox(answer: .skip(applyToAll: false))
        let queue = await promptedQueue(script: script, asks: asks)
        await queue.add(paths: ["/films/Movie.sup"])
        let finished = await waitUntil(queue) { queue in
            if case .skipped = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(asks.count, 1)
        XCTAssertEqual(asks.paths, ["/films/Movie.srt"])
        XCTAssertTrue(script.writes.isEmpty)
        XCTAssertTrue(script.works.isEmpty)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .skipped("Movie.srt already exists, so this file was skipped."))
    }

    func testReplaceWritesAndApplyToAllDoesNotAskAgain() async {
        let script = Script(files: ["/films/One.srt", "/films/Two.srt"])
        let asks = AnswerBox(answer: .replace(applyToAll: true))
        let queue = await promptedQueue(script: script, asks: asks)
        await queue.add(paths: ["/films/One.sup", "/films/Two.sup"])
        let finished = await waitUntil(queue) { queue in
            queue.items.count == 2 && !queue.items.contains(where: \.status.isActive)
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(asks.count, 1)
        let items = await queue.items
        XCTAssertEqual(
            items.map(\.status),
            [
                .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/films/One.srt"),
                .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/films/Two.srt")
            ]
        )
        XCTAssertEqual(script.writes.map(\.0), ["/films/One.srt", "/films/Two.srt"])
    }

    func testSkipApplyToAllSkipsLaterExistingFilesAndStillWritesANewOne() async {
        let script = Script(files: ["/films/One.srt", "/films/Two.srt"])
        let asks = AnswerBox(answer: .skip(applyToAll: true))
        let queue = await promptedQueue(script: script, asks: asks)
        await queue.add(paths: ["/films/One.sup", "/films/Two.sup", "/films/Three.sup"])
        let finished = await waitUntil(queue) { queue in
            queue.items.count == 3 && !queue.items.contains(where: \.status.isActive)
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(asks.count, 1)
        let items = await queue.items
        XCTAssertEqual(items[0].status, .skipped("One.srt already exists, so this file was skipped."))
        XCTAssertEqual(items[1].status, .skipped("Two.srt already exists, so this file was skipped."))
        XCTAssertEqual(items[2].status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/films/Three.srt"))
        XCTAssertEqual(script.writes.map(\.0), ["/films/Three.srt"])
    }

    func testWithoutApplyToAllEachExistingFileAsks() async {
        let script = Script(files: ["/films/One.srt", "/films/Two.srt"])
        let asks = AnswerBox(answer: .skip(applyToAll: false))
        let queue = await promptedQueue(script: script, asks: asks)
        await queue.add(paths: ["/films/One.sup", "/films/Two.sup"])
        let finished = await waitUntil(queue) { queue in
            queue.items.count == 2 && !queue.items.contains(where: \.status.isActive)
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(asks.count, 2)
        XCTAssertEqual(asks.paths, ["/films/One.srt", "/films/Two.srt"])
        XCTAssertTrue(script.writes.isEmpty)
    }

    func testAddNumberAndSkipDoNotAsk() async {
        let script = Script(files: ["/films/Movie.srt"])
        let asks = AnswerBox(answer: .replace(applyToAll: false))
        var preferences = ConversionPreferences.default
        preferences.existingFile = .addNumber
        let adding = await promptedQueue(script: script, asks: asks, preferences: preferences)
        await adding.add(paths: ["/films/Movie.sup"])
        let added = await waitUntil(adding) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(added)
        XCTAssertEqual(asks.count, 0)
        let addedItem = await adding.items[0]
        XCTAssertEqual(addedItem.status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/films/Movie 2.srt"))

        preferences.existingFile = .skip
        let skipping = await promptedQueue(script: script, asks: asks, preferences: preferences)
        await skipping.add(paths: ["/films/Movie.sup"])
        let skipped = await waitUntil(skipping) { queue in
            if case .skipped = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(skipped)
        XCTAssertEqual(asks.count, 0)
        XCTAssertTrue(script.writes.filter { $0.0 == "/films/Movie.srt" }.isEmpty)
    }

    func testANewBatchAsksAgainAfterApplyToAll() async {
        let script = Script(files: ["/films/One.srt", "/films/Two.srt"])
        let asks = AnswerBox(answer: .skip(applyToAll: true))
        let box = OutcomeBox()
        let queue = await promptedQueue(script: script, asks: asks)
        await MainActor.run {
            queue.onBatchFinished = { box.append($0) }
        }
        await queue.add(paths: ["/films/One.sup"])
        let first = await waitUntil(queue) { _ in box.outcomes.count == 1 }
        XCTAssertTrue(first)
        XCTAssertEqual(asks.count, 1)
        await queue.add(paths: ["/films/Two.sup"])
        let second = await waitUntil(queue) { _ in box.outcomes.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(asks.count, 2)
        XCTAssertEqual(asks.paths, ["/films/One.srt", "/films/Two.srt"])
    }

    func testCancelWhileThePromptIsUpDoesNotWrite() async {
        let script = Script(files: ["/films/Movie.srt"])
        let started = TaskHold()
        defer { started.release() }
        let queue = await makeQueue(script: script) { work in
            script.record(work)
            return sampleResult(cues: 1, failures: 0)
        }
        await MainActor.run {
            queue.confirmReplace = { _ in
                await started.park()
                return .cancel
            }
        }
        await queue.add(paths: ["/films/Movie.sup"])
        let parked = await started.waitUntilParked()
        XCTAssertTrue(parked)
        let id = await queue.items[0].id
        await queue.cancel(id: id)
        started.release()
        let cancelled = await waitUntil(queue) { queue in
            queue.items.first?.status == .cancelled
        }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(script.writes.isEmpty)
        XCTAssertTrue(script.works.isEmpty)
    }

    func testConvertAgainCanWriteBackIntoAChosenFolderAndStillAsk() async {
        let script = Script(files: ["/restored/Movie.srt"], directories: ["/restored": []])
        let asks = AnswerBox(answer: .replace(applyToAll: false))
        let queue = await promptedQueue(script: script, asks: asks)
        await queue.add(paths: ["/films/Movie.sup"], outputFolder: "/restored")
        let finished = await waitUntil(queue) { queue in
            if case .done = queue.items.last?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(asks.paths, ["/restored/Movie.srt"])
        let item = await queue.items.last
        XCTAssertEqual(item?.status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/restored/Movie.srt"))
        XCTAssertEqual(script.writes.map(\.0), ["/restored/Movie.srt"])
    }

    func testWhichRowsCanBeRemovedOrCleared() {
        XCTAssertFalse(ConversionStatus.waiting.isRemovable)
        XCTAssertFalse(ConversionStatus.extracting.isRemovable)
        XCTAssertFalse(ConversionStatus.converting(completed: 0, total: 0).isRemovable)
        XCTAssertFalse(ConversionStatus.converting(completed: 3, total: 10).isRemovable)
        XCTAssertTrue(ConversionStatus.done(cueCount: 2, unrecognizedCount: 0, outputPath: "/films/Movie.srt").isRemovable)
        XCTAssertTrue(ConversionStatus.awaitingReview(cueCount: 2, unrecognizedCount: 1, plannedPath: "/films/Movie.srt").isRemovable)
        XCTAssertFalse(ConversionStatus.awaitingReview(cueCount: 2, unrecognizedCount: 1, plannedPath: "/films/Movie.srt").isActive)
        XCTAssertTrue(ConversionStatus.failed("The PGS file is empty.").isRemovable)
        XCTAssertTrue(ConversionStatus.cancelled.isRemovable)
        XCTAssertTrue(ConversionStatus.skipped(MKVCopy.noPGS).isRemovable)
        XCTAssertTrue(ConversionStatus.extracting.isActive)
        XCTAssertFalse(ConversionStatus.skipped(MKVCopy.noPGS).isActive)
    }

    func testClearFinishedEnabledStateAndReturnToAnEmptyQueue() async {
        let gate = Gate()
        defer { gate.openAll() }
        let script = Script()
        let queue = await makeQueue(script: script) { _ in
            try await gate.wait()
            return sampleResult(cues: 2, failures: 0)
        }

        let emptyEnabled = await queue.canClearFinished
        XCTAssertFalse(emptyEnabled)
        await queue.clearFinished()
        let emptyItems = await queue.items
        XCTAssertTrue(emptyItems.isEmpty)

        await queue.add(paths: ["/films/First.sup", "/films/Second.sup", "/films/Notes.txt"])
        let started = await waitUntil(queue) { queue in
            if case .converting = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(started)

        let whileRunning = await queue.items
        XCTAssertEqual(whileRunning.map(\.name), ["First.sup", "Second.sup", "Notes.txt"])
        XCTAssertFalse(whileRunning[0].status.isRemovable)
        XCTAssertFalse(whileRunning[1].status.isRemovable)
        XCTAssertTrue(whileRunning[2].status.isRemovable)
        let enabledForSkip = await queue.canClearFinished
        let stillWorking = await queue.hasCancellableWork
        XCTAssertTrue(enabledForSkip)
        XCTAssertTrue(stillWorking)
        let removedConverting = await queue.remove(id: whileRunning[0].id)
        let removedWaiting = await queue.remove(id: whileRunning[1].id)
        XCTAssertFalse(removedConverting)
        XCTAssertFalse(removedWaiting)

        await queue.clearFinished()
        let kept = await queue.items
        XCTAssertEqual(kept.map(\.name), ["First.sup", "Second.sup"])
        let disabledWhileActive = await queue.canClearFinished
        let stillCancellable = await queue.hasCancellableWork
        XCTAssertFalse(disabledWhileActive)
        XCTAssertTrue(stillCancellable)

        gate.openAll()
        let finished = await waitUntil(queue) { queue in
            queue.items.count == 2 && !queue.items.contains(where: \.status.isActive)
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(script.writes.map(\.0), ["/films/First.srt", "/films/Second.srt"])
        XCTAssertTrue(script.fileExists("/films/First.srt"))
        XCTAssertTrue(script.fileExists("/films/Second.srt"))
        let enabledWhenDone = await queue.canClearFinished
        XCTAssertTrue(enabledWhenDone)

        await queue.clearFinished()
        let cleared = await queue.items
        XCTAssertTrue(cleared.isEmpty)
        let disabledWhenEmpty = await queue.canClearFinished
        XCTAssertFalse(disabledWhenEmpty)
        XCTAssertEqual(script.writes.map(\.0), ["/films/First.srt", "/films/Second.srt"])
        XCTAssertTrue(script.fileExists("/films/First.srt"))
        XCTAssertTrue(script.fileExists("/films/Second.srt"))
    }

    func testRemoveAndClearFinishedDropTerminalRowsWithoutDeletingFiles() async {
        let gate = Gate()
        defer { gate.openAll() }
        let script = Script()
        let queue = await makeQueue(script: script) { _ in
            let call = script.bump()
            try await gate.wait()
            if call == 2 {
                throw PGSError.emptyInput
            }
            return sampleResult(cues: 4, failures: 0)
        }
        await queue.add(paths: [
            "/films/Good.sup",
            "/films/Stop.sup",
            "/films/Bad.sup",
            "/films/Notes.txt"
        ])
        let started = await waitUntil(queue) { queue in
            if case .converting = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(started)
        let stopID = await queue.items[1].id
        await queue.cancel(id: stopID)
        gate.openAll()
        let settled = await waitUntil(queue) { queue in
            !queue.items.contains(where: \.status.isActive)
        }
        XCTAssertTrue(settled)

        let settledItems = await queue.items
        XCTAssertEqual(settledItems.map(\.name), ["Good.sup", "Stop.sup", "Bad.sup", "Notes.txt"])
        XCTAssertEqual(
            settledItems[0].status,
            .done(cueCount: 4, unrecognizedCount: 0, outputPath: "/films/Good.srt")
        )
        XCTAssertEqual(settledItems[1].status, .cancelled)
        XCTAssertEqual(settledItems[2].status, .failed("The PGS file is empty."))
        XCTAssertEqual(settledItems[3].status, .skipped("Notes.txt is not a .sup or .mkv file, so it was skipped."))
        XCTAssertTrue(settledItems.allSatisfy(\.status.isRemovable))
        let enabled = await queue.canClearFinished
        XCTAssertTrue(enabled)
        XCTAssertEqual(script.writes.map(\.0), ["/films/Good.srt"])
        XCTAssertTrue(script.fileExists("/films/Good.srt"))

        let removedUnknown = await queue.remove(id: UUID())
        let removedFailed = await queue.remove(id: settledItems[2].id)
        let removedFailedAgain = await queue.remove(id: settledItems[2].id)
        XCTAssertFalse(removedUnknown)
        XCTAssertTrue(removedFailed)
        XCTAssertFalse(removedFailedAgain)
        let afterOne = await queue.items
        XCTAssertEqual(afterOne.map(\.name), ["Good.sup", "Stop.sup", "Notes.txt"])
        let stillEnabled = await queue.canClearFinished
        XCTAssertTrue(stillEnabled)
        XCTAssertEqual(script.writes.map(\.0), ["/films/Good.srt"])

        await queue.clearFinished()
        let cleared = await queue.items
        XCTAssertTrue(cleared.isEmpty)
        let disabled = await queue.canClearFinished
        XCTAssertFalse(disabled)
        await queue.clearFinished()
        let stillCleared = await queue.items
        XCTAssertTrue(stillCleared.isEmpty)
        XCTAssertEqual(script.writes.map(\.0), ["/films/Good.srt"])
        XCTAssertTrue(script.fileExists("/films/Good.srt"))
    }

    func testRemovingTheOnlyRowLeavesTheQueueEmpty() async {
        let script = Script()
        let queue = await makeQueue(script: script) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        await queue.add(paths: ["/films/Only.sup"])
        let finished = await waitUntil(queue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        let enabled = await queue.canClearFinished
        XCTAssertTrue(enabled)
        let id = await queue.items[0].id
        let removed = await queue.remove(id: id)
        XCTAssertTrue(removed)
        let left = await queue.items
        XCTAssertTrue(left.isEmpty)
        let disabled = await queue.canClearFinished
        XCTAssertFalse(disabled)
        XCTAssertEqual(script.writes.map(\.0), ["/films/Only.srt"])
        XCTAssertTrue(script.fileExists("/films/Only.srt"))
    }

    func testMkvLogsWhenTheTempFolderIsRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgs-log-\(UUID().uuidString)", isDirectory: true)
        defer {
            DebugLog.shared.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        DebugLog.shared.configure(directory: directory, homeDirectory: "/Users/ada")

        let mkv = MKVDouble(json: englishThenJapanese)
        let queue = await makeQueue(script: Script(), mkv: mkv.client()) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        await queue.add(paths: ["/films/Movie.mkv"])
        let sawDestination = await waitUntil(queue) { _ in !mkv.destinations.isEmpty }
        XCTAssertTrue(sawDestination)
        let destination = try XCTUnwrap(mkv.destinations.first)
        let folder = Self.tempFolderName(destination)
        let finished = await waitUntil(queue) { _ in
            DebugLog.shared.recentText().contains("Temp folder removed \(folder)")
        }
        XCTAssertTrue(finished)
        var text = DebugLog.shared.recentText()
        XCTAssertTrue(text.contains("[mkv] info Temp folder removed \(folder)"))
        let finishedAt = try XCTUnwrap(text.range(of: "Finished Movie.mkv"))
        let removedAt = try XCTUnwrap(text.range(of: "Temp folder removed \(folder)"))
        XCTAssertLessThan(finishedAt.lowerBound, removedAt.lowerBound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: (destination as NSString).deletingLastPathComponent))

        let gate = Gate()
        defer { gate.openAll() }
        let cancelling = MKVDouble(json: englishThenJapanese)
        cancelling.beforeReturn = { _ in
            try await gate.wait()
        }
        let cancelQueue = await makeQueue(script: Script(), mkv: cancelling.client()) { _ in
            sampleResult()
        }
        await cancelQueue.add(paths: ["/films/Other.mkv"])
        let extracting = await waitUntil(cancelQueue) { _ in cancelling.enteredExtract }
        XCTAssertTrue(extracting)
        let id = await cancelQueue.items[0].id
        await cancelQueue.cancel(id: id)
        let cancelDestination = try XCTUnwrap(cancelling.destinations.first)
        let cancelFolder = Self.tempFolderName(cancelDestination)
        let loggedCancel = await waitUntil(cancelQueue) { _ in
            DebugLog.shared.recentText().contains("Temp folder removed \(cancelFolder)")
        }
        XCTAssertTrue(loggedCancel)
        text = DebugLog.shared.recentText()
        XCTAssertTrue(text.contains("[mkv] info Temp folder removed \(cancelFolder)"))
        let cancelledAt = try XCTUnwrap(text.range(of: "Cancelled Other.mkv"))
        let cancelRemovedAt = try XCTUnwrap(text.range(of: "Temp folder removed \(cancelFolder)"))
        XCTAssertLessThan(cancelledAt.lowerBound, cancelRemovedAt.lowerBound)
        let status = await cancelQueue.items[0].status
        XCTAssertEqual(status, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: (cancelDestination as NSString).deletingLastPathComponent))
    }

    private static func tempFolderName(_ supPath: String) -> String {
        ((supPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    func testMkvUsesTheEnglishTrackAndNamesTheSrtAfterTheMkv() async throws {
        let mkv = MKVDouble(json: englishThenJapanese)
        let script = Script()
        let queue = await makeQueue(script: script, mkv: mkv.client()) { work in
            script.record(work)
            return sampleResult(cues: 3, failures: 0)
        }
        await queue.add(paths: ["/films/Movie.mkv"])
        let finished = await waitUntil(queue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .done(cueCount: 3, unrecognizedCount: 0, outputPath: "/films/Movie.srt"))
        XCTAssertEqual(mkv.extractedTracks, [4])
        XCTAssertEqual(script.writes.map(\.0), ["/films/Movie.srt"])
        XCTAssertEqual(script.works.first?.data, Data("PGS".utf8))
        let destination = try XCTUnwrap(mkv.destinations.first)
        let removed = await waitUntil(queue) { _ in
            !FileManager.default.fileExists(atPath: destination)
                && !FileManager.default.fileExists(atPath: (destination as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(removed)
    }

    func testMkvInAChosenFolderStillFollowsTheExistingFileSetting() async throws {
        let mkv = MKVDouble(json: englishThenJapanese)
        let script = Script(files: ["/out/Movie.srt"])
        var preferences = ConversionPreferences.default
        preferences.placement = .folder("/out")
        preferences.existingFile = .addNumber
        let queue = await makeQueue(preferences: preferences, script: script, mkv: mkv.client()) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        await queue.add(paths: ["/films/Movie.mkv"])
        let finished = await waitUntil(queue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/out/Movie 2.srt"))
        let destination = try XCTUnwrap(mkv.destinations.first)
        let removed = await waitUntil(queue) { _ in
            !FileManager.default.fileExists(atPath: destination)
        }
        XCTAssertTrue(removed)
    }

    func testMkvOverwriteAsksBeforeExtracting() async {
        let mkv = MKVDouble(json: englishThenJapanese)
        let script = Script(files: ["/films/Movie.srt"])
        let asks = AnswerBox(answer: .skip(applyToAll: false))
        let queue = await makeQueue(script: script, mkv: mkv.client()) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        await MainActor.run {
            queue.confirmReplace = { path in
                asks.next(path)
            }
        }
        await queue.add(paths: ["/films/Movie.mkv"])
        let finished = await waitUntil(queue) { queue in
            if case .skipped = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(asks.paths, ["/films/Movie.srt"])
        XCTAssertTrue(mkv.extractedTracks.isEmpty)
        XCTAssertTrue(script.writes.isEmpty)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .skipped("Movie.srt already exists, so this file was skipped."))
    }

    func testMkvWithoutPGSIsSkippedAndABadFileFails() async {
        let mkv = MKVDouble(json: Data("{\"tracks\":[{\"id\":0,\"type\":\"video\",\"codec\":\"V_MPEG4/ISO/AVC\",\"properties\":{\"codec_id\":\"V_MPEG4/ISO/AVC\"}}]}".utf8))
        let script = Script()
        let queue = await makeQueue(script: script, mkv: mkv.client()) { _ in sampleResult() }
        await queue.add(paths: ["/films/Movie.mkv"])
        let skipped = await waitUntil(queue) { queue in
            if case .skipped = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(skipped)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .skipped(MKVCopy.noPGS))
        XCTAssertTrue(mkv.extractedTracks.isEmpty)

        mkv.json = Data("not json".utf8)
        await queue.add(paths: ["/films/Other.mkv"])
        let failed = await waitUntil(queue) { queue in
            queue.items.count == 2 && !queue.items.contains(where: \.status.isActive)
        }
        XCTAssertTrue(failed)
        let failedItem = await queue.items[1]
        XCTAssertEqual(failedItem.status, .failed("Could not read the subtitle tracks in this MKV."))
    }

    func testChoosingATrackUsesThatIdAndSkipDoesNotExtract() async {
        var preferences = ConversionPreferences.default
        preferences.chooseMKVTrack = true
        let mkv = MKVDouble(json: englishThenJapanese)
        let picks = TrackBox(choice: .convert(trackID: 2))
        let script = Script()
        let queue = await makeQueue(preferences: preferences, script: script, mkv: mkv.client()) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        await MainActor.run {
            queue.chooseTrack = { name, tracks, suggested in
                picks.record(name: name, tracks: tracks, suggested: suggested)
                return picks.choice
            }
        }
        await queue.add(paths: ["/films/Movie.mkv"])
        let finished = await waitUntil(queue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(picks.names, ["Movie.mkv"])
        XCTAssertEqual(picks.suggested, [4])
        XCTAssertEqual(picks.seenTracks.first?.map(\.id), [2, 4])
        XCTAssertEqual(mkv.extractedTracks, [2])

        preferences.chooseMKVTrack = false
        let quiet = MKVDouble(json: englishThenJapanese)
        let quietPicks = TrackBox(choice: .convert(trackID: 2))
        let quietQueue = await makeQueue(preferences: preferences, script: script, mkv: quiet.client()) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        await MainActor.run {
            quietQueue.chooseTrack = { name, tracks, suggested in
                quietPicks.record(name: name, tracks: tracks, suggested: suggested)
                return quietPicks.choice
            }
        }
        await quietQueue.add(paths: ["/films/Quiet.mkv"])
        let quietDone = await waitUntil(quietQueue) { queue in
            if case .done = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(quietDone)
        XCTAssertTrue(quietPicks.names.isEmpty)
        XCTAssertEqual(quiet.extractedTracks, [4])

        picks.choice = .skip
        await queue.add(paths: ["/films/Again.mkv"])
        let skipped = await waitUntil(queue) { queue in
            queue.items.count == 2 && !queue.items.contains(where: \.status.isActive)
        }
        XCTAssertTrue(skipped)
        let skippedItem = await queue.items[1]
        XCTAssertEqual(skippedItem.status, .skipped(MKVCopy.skippedTrack))
        XCTAssertEqual(mkv.extractedTracks, [2])
    }

    func testCancelDuringExtractRemovesTheTempFileAndDoesNotConvert() async {
        let gate = Gate()
        defer { gate.openAll() }
        let mkv = MKVDouble(json: englishThenJapanese)
        mkv.beforeReturn = { _ in
            try await gate.wait()
        }
        let script = Script()
        let queue = await makeQueue(script: script, mkv: mkv.client()) { _ in
            script.record(ConversionWork(data: Data(), languages: [], maxConcurrent: 1, italics: false))
            return sampleResult()
        }
        await queue.add(paths: ["/films/Movie.mkv"])
        let extracting = await waitUntil(queue) { _ in mkv.enteredExtract }
        XCTAssertTrue(extracting)
        let sawExtracting = await waitUntil(queue) { queue in
            queue.items.first?.status == .extracting
        }
        XCTAssertTrue(sawExtracting)
        let id = await queue.items[0].id
        await queue.cancel(id: id)
        let cancelled = await waitUntil(queue) { queue in
            queue.items.first?.status == .cancelled
        }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(script.works.isEmpty)
        let destination = mkv.destinations.first
        XCTAssertNotNil(destination)
        if let destination {
            let removed = await waitUntil(queue) { _ in
                !FileManager.default.fileExists(atPath: destination)
                    && !FileManager.default.fileExists(atPath: (destination as NSString).deletingLastPathComponent)
            }
            XCTAssertTrue(removed)
        }
    }

    func testAFailedExtractAlsoRemovesTheTempFile() async throws {
        let mkv = MKVDouble(json: englishThenJapanese)
        mkv.failExtract = true
        let script = Script()
        let queue = await makeQueue(script: script, mkv: mkv.client()) { _ in sampleResult() }
        await queue.add(paths: ["/films/Movie.mkv"])
        let failed = await waitUntil(queue) { queue in
            if case .failed = queue.items.first?.status { return true }
            return false
        }
        XCTAssertTrue(failed)
        let failedItem = await queue.items[0]
        XCTAssertEqual(failedItem.status, .failed("Could not extract the PGS subtitles from this MKV."))
        let destination = try XCTUnwrap(mkv.destinations.first)
        let removed = await waitUntil(queue) { _ in
            !FileManager.default.fileExists(atPath: destination)
                && !FileManager.default.fileExists(atPath: (destination as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(removed)
        XCTAssertTrue(script.writes.isEmpty)
    }

    func testHoldForReviewWritesNothingUntilSaveAndKeepsTheFailureOutOfTheField() async throws {
        var preferences = ConversionPreferences.default
        preferences.saveTiming = .afterReview
        let script = Script()
        let queue = await makeQueue(preferences: preferences, script: script) { _ in
            sampleResult(cues: 2, failures: 1)
        }
        let outcome = await finish(queue, paths: ["/films/Movie.sup"], script: script)
        XCTAssertEqual(outcome, BatchOutcome(done: 1, failed: 0, cancelled: 0, skipped: 0))
        XCTAssertTrue(script.writes.isEmpty)
        let item = await queue.items[0]
        guard case let .awaitingReview(cues, unrecognized, path) = item.status else {
            return XCTFail("expected the file to be held, got \(item.status)")
        }
        XCTAssertEqual(cues, 2)
        XCTAssertEqual(unrecognized, 1)
        XCTAssertEqual(path, "/films/Movie.srt")
        let document = await queue.reviewDocument(for: item.id)
        XCTAssertEqual(document?.cues[0].text, "")
        XCTAssertEqual(document?.cues[0].showsOCRFailure, true)
        XCTAssertEqual(document?.cues[1].text, "Line 1")
        XCTAssertEqual(document?.needsWriting, true)
        XCTAssertEqual(document?.hasUnsavedEdits, false)
        XCTAssertFalse(document?.cues[0].srtBody.contains("Line") == true)
        XCTAssertTrue(document?.cues[0].srtBody.contains("[OCR failed: no text recognized]") == true)

        var edited = try XCTUnwrap(document)
        edited.setText(id: edited.cues[1].id, text: "Line 1\nSecond line")
        try edited.setTiming(id: edited.cues[1].id, startPTS: 90_000, endPTS: 270_000)
        await queue.setReviewDocument(edited, for: item.id)
        try await queue.saveReview(id: item.id, to: path)

        XCTAssertEqual(script.writes.map(\.0), ["/films/Movie.srt"])
        let written = script.writes[0].1
        XCTAssertTrue(written.contains("[OCR failed: no text recognized]"))
        XCTAssertTrue(written.contains("Line 1\r\nSecond line"))
        XCTAssertTrue(written.contains("00:00:01,000 --> 00:00:03,000"))
        XCTAssertFalse(written.contains("[OCR failed: no text recognized]\r\nLine 1\r\nSecond"))
        let saved = await queue.items[0]
        XCTAssertEqual(saved.status, .done(cueCount: 2, unrecognizedCount: 1, outputPath: path))
        let after = await queue.reviewDocument(for: item.id)
        XCTAssertEqual(after?.needsWriting, false)
        XCTAssertEqual(after?.cues[1].text, "Line 1\nSecond line")
    }

    func testSaveImmediatelyStillWritesAndKeepsACleanReview() async {
        let script = Script()
        let queue = await makeQueue(script: script) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        _ = await finish(queue, paths: ["/films/Movie.sup"], script: script)
        let item = await queue.items[0]
        XCTAssertEqual(item.status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/films/Movie.srt"))
        XCTAssertEqual(script.writes.map(\.0), ["/films/Movie.srt"])
        let document = await queue.reviewDocument(for: item.id)
        XCTAssertEqual(document?.needsWriting, false)
        XCTAssertEqual(document?.hasUnsavedEdits, false)
        XCTAssertEqual(document?.cues.first?.text, "Line 0")
        await queue.clearFinished()
        let cleared = await queue.reviewDocument(for: item.id)
        XCTAssertNil(cleared)
    }

    func testAFolderQueuesSupAndMkvTogether() async {
        let mkv = MKVDouble(json: englishThenJapanese)
        let script = Script(directories: [
            "/clips": ["/clips/A.sup", "/clips/nested", "/clips/Notes.txt"],
            "/clips/nested": ["/clips/nested/B.mkv"]
        ])
        let queue = await makeQueue(script: script, mkv: mkv.client()) { _ in
            sampleResult(cues: 1, failures: 0)
        }
        let outcome = await finish(queue, paths: ["/clips"], script: script)
        let items = await queue.items
        XCTAssertEqual(items.map(\.name), ["A.sup", "B.mkv"])
        XCTAssertEqual(items[0].status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/clips/A.srt"))
        XCTAssertEqual(items[1].status, .done(cueCount: 1, unrecognizedCount: 0, outputPath: "/clips/nested/B.srt"))
        XCTAssertEqual(outcome?.done, 2)
        XCTAssertEqual(mkv.extractedTracks, [4])
    }
}

private let englishThenJapanese = Data(
    """
    {"tracks":[
      {"id":2,"type":"subtitles","codec":"HDMV PGS","properties":{"codec_id":"S_HDMV/PGS","language":"jpn","language_ietf":"ja","number":3,"track_name":"Japanese","forced_track":true,"default_track":true}},
      {"id":4,"type":"subtitles","codec":"HDMV PGS","properties":{"codec_id":"S_HDMV/PGS","language":"und","language_ietf":"en","number":5,"track_name":"English","forced_track":false,"default_track":false}}
    ]}
    """.utf8
)

/// Stand-in for mkvmerge and mkvextract. Writes a tiny `.sup` into the temp path the queue chose.
private final class MKVDouble: @unchecked Sendable {
    var json: Data
    var failExtract = false
    var beforeReturn: (@Sendable (String) async throws -> Void)?
    private let lock = NSLock()
    private var tracks: [Int] = []
    private var dests: [String] = []
    private var entered = false

    init(json: Data) {
        self.json = json
    }

    var extractedTracks: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return tracks
    }

    var destinations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return dests
    }

    var enteredExtract: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func currentJSON() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return json
    }

    func client() -> MKVClient {
        MKVClient(
            locate: {
                MKVToolPaths(mkvmerge: "/usr/bin/mkvmerge", mkvextract: "/usr/bin/mkvextract")
            },
            identify: { _, _ in
                self.currentJSON()
            },
            extract: { _, _, track, destination in
                let shouldFail = self.note(track, destination)
                try Data("PGS".utf8).write(to: URL(fileURLWithPath: destination))
                if shouldFail {
                    throw MKVFailure.extractFailed
                }
                if let beforeReturn = self.beforeReturn {
                    try await beforeReturn(destination)
                }
            }
        )
    }

    private func note(_ track: Int, _ destination: String) -> Bool {
        lock.lock()
        tracks.append(track)
        dests.append(destination)
        entered = true
        let shouldFail = failExtract
        lock.unlock()
        return shouldFail
    }
}

private final class TrackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedChoice: MKVTrackChoice
    private var storedNames: [String] = []
    private var storedSuggested: [Int] = []
    private var storedTracks: [[PGSSubtitleTrack]] = []

    init(choice: MKVTrackChoice) {
        storedChoice = choice
    }

    var choice: MKVTrackChoice {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedChoice
        }
        set {
            lock.lock()
            storedChoice = newValue
            lock.unlock()
        }
    }

    func record(name: String, tracks: [PGSSubtitleTrack], suggested: Int) {
        lock.lock()
        storedNames.append(name)
        storedSuggested.append(suggested)
        storedTracks.append(tracks)
        lock.unlock()
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedNames
    }

    var suggested: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedSuggested
    }

    var seenTracks: [[PGSSubtitleTrack]] {
        lock.lock()
        defer { lock.unlock() }
        return storedTracks
    }
}

private func promptedQueue(
    script: Script,
    asks: AnswerBox,
    preferences: ConversionPreferences = .default
) async -> ConversionQueue {
    let queue = await makeQueue(preferences: preferences, script: script) { work in
        script.record(work)
        return sampleResult(cues: 1, failures: 0)
    }
    await MainActor.run {
        queue.confirmReplace = { path in
            asks.next(path)
        }
    }
    return queue
}

private final class AnswerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OverwriteAnswer
    private var calls = 0
    private var seen: [String] = []

    init(answer: OverwriteAnswer) {
        stored = answer
    }

    func next(_ path: String) -> OverwriteAnswer {
        lock.lock()
        calls += 1
        seen.append(path)
        let answer = stored
        lock.unlock()
        return answer
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

private func makeQueue(
    preferences: ConversionPreferences = .default,
    script: Script,
    mkv: MKVClient = .unavailable,
    convert: @escaping @Sendable (ConversionWork) async throws -> TranscriptionResult
) async -> ConversionQueue {
    let listing = script.listing
    let services = ConversionServices(
        read: { path in
            if let data = script.bytes[path] { return data }
            if FileManager.default.fileExists(atPath: path) {
                return (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            }
            return Data()
        },
        write: { path, text in
            script.noteWrite(path, text)
        },
        fileExists: { script.fileExists($0) },
        directoryExists: { script.directoryExists($0) },
        listing: listing,
        convert: convert,
        mkv: mkv
    )
    return await ConversionQueue(preferences: preferences, services: services)
}

private func finish(
    _ queue: ConversionQueue,
    paths: [String],
    script: Script
) async -> BatchOutcome? {
    let box = OutcomeBox()
    await MainActor.run {
        queue.onBatchFinished = { box.append($0) }
    }
    await queue.add(paths: paths)
    _ = await waitUntil(queue) { _ in box.outcome != nil }
    return box.outcome
}

private func waitUntil(
    _ queue: ConversionQueue,
    timeoutSeconds: Double = 2,
    _ match: @escaping @MainActor (ConversionQueue) -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await match(queue) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private func sampleResult(cues: Int = 2, failures: Int = 1) -> TranscriptionResult {
    let srtCues = (0..<cues).map { index in
        SRTCue(
            startPTS: UInt32(index) * 90_000,
            endPTS: UInt32(index + 1) * 90_000,
            text: failures > index ? "[OCR failed: no text recognized]" : "Line \(index)"
        )
    }
    let fails = (0..<failures).map { index in
        CueRecognitionFailure(cueIndex: index, startPTS: 0, endPTS: 90_000, message: "no text recognized")
    }
    return TranscriptionResult(cues: srtCues, failures: fails, srt: "SRT \(cues) \(failures)")
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BatchOutcome] = []

    func append(_ outcome: BatchOutcome) {
        lock.lock()
        stored.append(outcome)
        lock.unlock()
    }

    var outcomes: [BatchOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var outcome: BatchOutcome? { outcomes.last }
}

private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var files: Set<String>
    private var directories: [String: [String]]
    private(set) var writes: [(String, String)] = []
    private(set) var works: [ConversionWork] = []
    let bytes: [String: Data]

    init(
        files: Set<String> = [],
        directories: [String: [String]] = [:],
        bytes: [String: Data] = [:]
    ) {
        self.files = files
        var directories = directories
        if directories["/out"] == nil { directories["/out"] = [] }
        self.directories = directories
        self.bytes = bytes
    }

    func fileExists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return files.contains(path)
    }

    func directoryExists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return directories[path] != nil
    }

    func noteWrite(_ path: String, _ text: String) {
        lock.lock()
        writes.append((path, text))
        files.insert(path)
        lock.unlock()
    }

    func record(_ work: ConversionWork) {
        lock.lock()
        works.append(work)
        lock.unlock()
    }

    func bump() -> Int {
        lock.lock()
        works.append(ConversionWork(data: Data(), languages: [], maxConcurrent: 1, italics: false))
        let count = works.count
        lock.unlock()
        return count
    }

    var listing: DirectoryListing {
        DirectoryListing(
            isDirectory: { self.directoryExists($0) },
            children: { path in
                self.lock.lock()
                let children = self.directories[path] ?? []
                self.lock.unlock()
                return children
            }
        )
    }
}

private struct HelloRecognizer: SubtitleRecognizing {
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        OCRResult(
            text: "Hello",
            confidence: 0.9,
            lines: [RecognizedLine(text: "Hello", confidence: 0.9, isItalic: true, top: 0, left: 0, height: 8)]
        )
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var next = 0
    private var opened = false

    func wait() async throws {
        let claim = reserve()
        if claim.alreadyOpen { return }
        let id = claim.id
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if self.store(id, continuation) == false {
                    continuation.resume()
                } else if Task.isCancelled {
                    self.resume(id, throwing: CancellationError())
                }
            }
        } onCancel: {
            self.resume(id, throwing: CancellationError())
        }
    }

    func openAll() {
        let pending = releaseAll()
        for waiter in pending.values {
            waiter.resume()
        }
    }

    private func reserve() -> (id: Int, alreadyOpen: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if opened { return (0, true) }
        next += 1
        return (next, false)
    }

    /// Stores the continuation. Returns false when the gate is already open.
    private func store(_ id: Int, _ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if opened { return false }
        waiters[id] = continuation
        return true
    }

    private func releaseAll() -> [Int: CheckedContinuation<Void, Error>] {
        lock.lock()
        defer { lock.unlock() }
        opened = true
        let pending = waiters
        waiters.removeAll()
        return pending
    }

    private func resume(_ id: Int, throwing error: Error) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(throwing: error)
    }
}

/// Counts recognizer calls. A cancelled decode should stay at zero.
private final class CallCounter: SubtitleRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func recognize(image _: SubtitleImage, languages _: [String]) async throws -> OCRResult {
        note()
        return OCRResult(text: "should not run")
    }

    private func note() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

/// Lets the first two decoder checks through, then waits until the task is cancelled.
/// That is inside the segment loop, after parsing has started.
private final class DecodePause: @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var blocked = false
    private var release = false

    func check() throws {
        condition.lock()
        calls += 1
        let shouldBlock = calls >= 3
        if shouldBlock {
            blocked = true
            condition.broadcast()
        }
        while shouldBlock && !release && !Task.isCancelled {
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        let stop = release || Task.isCancelled
        condition.unlock()
        if stop {
            try Task.checkCancellation()
            throw CancellationError()
        }
    }

    func waitUntilBlocked(timeoutSeconds: Double = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isBlocked() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func isBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return blocked
    }

    func end() {
        condition.lock()
        release = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Suspends a task before the work under test, so the test can cancel it first.
private final class TaskHold: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var parked = false
    private var released = false

    func park() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.released {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            self.parked = true
            self.lock.unlock()
        }
    }

    func waitUntilParked(timeoutSeconds: Double = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isParked() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func isParked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parked
    }

    func release() {
        lock.lock()
        released = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
