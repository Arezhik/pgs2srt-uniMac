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

    func testMkvIsAPoliteSkipAndDoesNotNotifyOnItsOwn() async {
        let script = Script()
        let box = OutcomeBox()
        let queue = await makeQueue(script: script) { _ in sampleResult() }
        await MainActor.run {
            queue.onBatchFinished = { box.append($0) }
        }
        let notices = await queue.add(paths: ["/films/Movie.mkv"])
        XCTAssertEqual(notices, [.mkv(path: "/films/Movie.mkv")])
        let item = await queue.items[0]
        XCTAssertEqual(item.name, "Movie.mkv")
        XCTAssertEqual(item.status, .skipped("MKV support is coming."))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(box.outcomes.isEmpty)

        await queue.add(paths: ["/films/Movie.sup", "/films/Other.mkv"])
        let finished = await waitUntil(queue) { _ in !box.outcomes.isEmpty }
        XCTAssertTrue(finished)
        let items = await queue.items
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[2].status, .skipped("MKV support is coming."))
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
        XCTAssertEqual(banners, ["No .sup files were found in clips."])
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
        let suite = "pgs2srt.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(ConversionPreferenceStore.load(from: defaults), .default)

        let saved = ConversionPreferences(
            placement: .folder("/subtitles"),
            language: "ja-JP",
            existingFile: .addNumber,
            concurrency: 3,
            experimentalItalics: true
        )
        ConversionPreferenceStore.save(saved, to: defaults)
        XCTAssertEqual(ConversionPreferenceStore.load(from: defaults), saved)
        XCTAssertEqual(defaults.string(forKey: ConversionPreferenceKey.placement), ConversionPreferenceKey.placementFolder)
        XCTAssertEqual(defaults.bool(forKey: ConversionPreferenceKey.italics), true)

        defaults.set(0, forKey: ConversionPreferenceKey.concurrency)
        defaults.set("  ", forKey: ConversionPreferenceKey.language)
        defaults.set("nope", forKey: ConversionPreferenceKey.existingFile)
        let repaired = ConversionPreferenceStore.load(from: defaults)
        XCTAssertEqual(repaired.concurrency, 1)
        XCTAssertEqual(repaired.language, "en-US")
        XCTAssertEqual(repaired.existingFile, .overwrite)
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
    convert: @escaping @Sendable (ConversionWork) async throws -> TranscriptionResult
) async -> ConversionQueue {
    let listing = script.listing
    let services = ConversionServices(
        read: { path in
            if let data = script.bytes[path] { return data }
            return Data()
        },
        write: { path, text in
            script.noteWrite(path, text)
        },
        fileExists: { script.fileExists($0) },
        directoryExists: { script.directoryExists($0) },
        listing: listing,
        convert: convert
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
