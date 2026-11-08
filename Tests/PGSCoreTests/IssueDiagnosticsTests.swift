import XCTest
import PGSCore

final class IssueDiagnosticsTests: XCTestCase {
    func testSwitchTreatsBlankAndUnknownValuesAsUnset() {
        XCTAssertFalse(DiagnosticSwitch.isOn(environmentValue: nil, defaultsFlag: false))
        XCTAssertTrue(DiagnosticSwitch.isOn(environmentValue: nil, defaultsFlag: true))
        XCTAssertTrue(DiagnosticSwitch.isOn(environmentValue: "", defaultsFlag: true))
        XCTAssertTrue(DiagnosticSwitch.isOn(environmentValue: "  ", defaultsFlag: true))
        XCTAssertFalse(DiagnosticSwitch.isOn(environmentValue: "maybe", defaultsFlag: false))
        XCTAssertTrue(DiagnosticSwitch.isOn(environmentValue: "maybe", defaultsFlag: true))
        for value in ["1", "YES", "true", " on "] {
            XCTAssertTrue(DiagnosticSwitch.isOn(environmentValue: value, defaultsFlag: false))
        }
        for value in ["0", "no", "FALSE", "off"] {
            XCTAssertFalse(DiagnosticSwitch.isOn(environmentValue: value, defaultsFlag: true))
        }
    }

    func testStableFocusAppliesOnlyWhenReviewAvailabilityChanges() {
        XCTAssertTrue(StableCommandFocus.shouldApply(previousCanReview: nil, canReview: false))
        XCTAssertFalse(StableCommandFocus.shouldApply(previousCanReview: false, canReview: false))
        XCTAssertTrue(StableCommandFocus.shouldApply(previousCanReview: false, canReview: true))
        XCTAssertFalse(StableCommandFocus.shouldApply(previousCanReview: true, canReview: true))
    }

    func testProgressTicksDoNotChangeCommandAvailability() {
        let early = QueueCommandSnapshot.observe(
            items: [item(.converting(completed: 1, total: 400))],
            hasReviewsNeedingSave: false
        )
        let later = QueueCommandSnapshot.observe(
            items: [item(.converting(completed: 40, total: 400))],
            hasReviewsNeedingSave: false
        )
        XCTAssertEqual(early.availabilityKey, later.availabilityKey)
        XCTAssertTrue(early.hasCancellableWork)
        XCTAssertFalse(early.canClearFinished)
        XCTAssertEqual(early.progress.label, "1/400")
        XCTAssertEqual(later.progress.label, "40/400")

        let done = QueueCommandSnapshot.observe(
            items: [item(.done(cueCount: 3, unrecognizedCount: 1, outputPath: "/secret/Hello subtitle.srt"))],
            hasReviewsNeedingSave: true
        )
        XCTAssertFalse(done.hasCancellableWork)
        XCTAssertTrue(done.canClearFinished)
        XCTAssertTrue(done.hasReviewsNeedingSave)
        XCTAssertNotEqual(done.availabilityKey, early.availabilityKey)
        let line = DiagnosticFormatting.modelRefresh(done, menu: "closed").message
        XCTAssertFalse(line.contains("Hello"))
        XCTAssertFalse(line.contains("secret"))
        XCTAssertFalse(line.contains(".srt"))
        XCTAssertTrue(line.contains("progress=none"))
        XCTAssertTrue(line.contains("saveAll=true"))
    }

    func testMixedRowsReportBothCommandFlagsWithoutCueText() {
        let mixed = QueueCommandSnapshot.observe(
            items: [
                item(.converting(completed: 2, total: 9)),
                item(.awaitingReview(cueCount: 4, unrecognizedCount: 0, plannedPath: "/tmp/Keep this sentence.srt"))
            ],
            hasReviewsNeedingSave: false
        )
        XCTAssertTrue(mixed.hasCancellableWork)
        XCTAssertTrue(mixed.canClearFinished)
        XCTAssertEqual(mixed.progress, .converting(completed: 2, total: 9))
        let several = QueueCommandSnapshot.observe(
            items: [
                item(.converting(completed: 1, total: 2)),
                item(.converting(completed: 3, total: 4))
            ],
            hasReviewsNeedingSave: false
        )
        XCTAssertEqual(several.progress, .multiple)
        let line = DiagnosticFormatting.modelRefresh(several, menu: "closed").message
        XCTAssertTrue(line.contains("progress=multiple"))
        XCTAssertFalse(line.contains("sentence"))
    }

    func testIdenticalPublicationsCoalesceUntilTheSignatureOrMenuChanges() {
        let coalescer = DiagnosticCoalescer()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = coalescer.ingest(model(progress: "1/400", menu: "closed"), at: start)
        XCTAssertEqual(first, [model(progress: "1/400", menu: "closed").message])

        var quiet: [String] = []
        for step in 1...4 {
            let date = start.addingTimeInterval(Double(step) * 0.125)
            quiet.append(contentsOf: coalescer.ingest(model(progress: "\(step)/400", menu: "closed"), at: date))
        }
        XCTAssertEqual(quiet, [])

        let opened = coalescer.ingest(
            DiagnosticFormatting.menuTrack(phase: "begin", menu: .standard("file"), itemCount: 8, cancelAll: "on", clearFinished: "off"),
            at: start.addingTimeInterval(0.5)
        )
        XCTAssertEqual(opened, [
            "repeated 4 over 0.50s; last \(model(progress: "4/400", menu: "closed").message)",
            "menu-track begin menu=file items=8 cancelAll=on clearFinished=off"
        ])

        let during = coalescer.ingest(model(progress: "5/400", menu: "file"), at: start.addingTimeInterval(0.625))
        XCTAssertEqual(during, [model(progress: "5/400", menu: "file").message])
    }

    func testSeparateGroupsCoalesceAtTheSameTimeAndASecondFlushesOneGroup() {
        let coalescer = DiagnosticCoalescer()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            coalescer.ingest(model(progress: "1/8", menu: "closed"), at: start),
            [model(progress: "1/8", menu: "closed").message]
        )
        XCTAssertEqual(
            coalescer.ingest(commands(menu: "closed"), at: start.addingTimeInterval(0.25)),
            [commands(menu: "closed").message]
        )
        XCTAssertEqual(
            coalescer.ingest(model(progress: "2/8", menu: "closed"), at: start.addingTimeInterval(0.25)),
            []
        )
        XCTAssertEqual(
            coalescer.ingest(commands(menu: "closed"), at: start.addingTimeInterval(0.5)),
            []
        )
        let flushed = coalescer.ingest(
            model(progress: "3/8", menu: "closed"),
            at: start.addingTimeInterval(DiagnosticCoalescer.repeatFlushInterval)
        )
        XCTAssertEqual(flushed, [
            "repeated 2 over 1.00s; last \(model(progress: "3/8", menu: "closed").message)"
        ])
        let commandsStillOpen = coalescer.flush(at: start.addingTimeInterval(1.25))
        XCTAssertEqual(commandsStillOpen, [
            "repeated 1 over 1.00s; last \(commands(menu: "closed").message)"
        ])
        XCTAssertEqual(coalescer.flush(at: start.addingTimeInterval(2)), [])
    }

    func testMenuTitlesDoNotCopyFilenamesOrSubtitleText() {
        XCTAssertEqual(DiagnosticMenuName.classify(title: " File ").logToken, "file")
        XCTAssertEqual(DiagnosticMenuName.classify(title: "Window").logToken, "window")
        XCTAssertEqual(DiagnosticMenuName.classify(title: nil).logToken, "other")
        let leaked = "Hello there subtitle"
        let other = DiagnosticMenuName.classify(title: leaked)
        XCTAssertEqual(other, .other)
        let line = DiagnosticFormatting.menuTrack(
            phase: "begin",
            menu: other,
            itemCount: 3,
            cancelAll: nil,
            clearFinished: nil
        ).message
        XCTAssertEqual(line, "menu-track begin menu=other items=3")
        XCTAssertFalse(line.contains("Hello"))
        XCTAssertFalse(line.contains("subtitle"))
    }

    func testScopeAndEditLinesKeepOrderFactsAndDropCueText() {
        let planted = "it 'cause the line was private"
        let intent = DiagnosticFormatting.scopeIntent(
            source: .picker,
            from: .all,
            to: .problems,
            edit: .text,
            selectionCount: 1,
            dirty: true
        )
        XCTAssertFalse(intent.coalesce)
        XCTAssertEqual(
            intent.message,
            "scope intent source=picker from=all to=problems edit=text selection=1 dirty=true"
        )
        XCTAssertFalse(intent.message.contains(planted))
        let after = DiagnosticFormatting.scopeBoundary(
            phase: "after",
            source: .command,
            from: .problems,
            to: .all,
            edit: .none,
            selectionCount: 2,
            dirty: false,
            published: true,
            stickyCount: nil
        )
        XCTAssertTrue(after.message.contains("published=true"))
        XCTAssertTrue(after.message.contains("sticky=none"))
        XCTAssertEqual(DiagnosticEditPhase.combine(text: true, time: true), .textAndTime)
        XCTAssertEqual(
            DiagnosticFormatting.editPhase(.time, field: .start).message,
            "edit-phase phase=time field=start"
        )
        XCTAssertEqual(
            DiagnosticFormatting.timeCommit(field: .end, phase: "before", changed: true).message,
            "time-commit field=end before changed=true"
        )
        XCTAssertEqual(
            DiagnosticFormatting.coalesce(phase: "before", published: false).message,
            "coalesce-end before published=false"
        )
    }

    func testDocumentEditedLineRecordsTheUnconditionalUpdateSeparatelyFromInstall() {
        let update = DiagnosticFormatting.documentEdited(
            site: "update",
            windowExisted: true,
            previous: true,
            requested: true,
            willWrite: true
        )
        XCTAssertTrue(update.coalesce)
        XCTAssertEqual(
            update.message,
            "document-edited site=update window=true previous=true requested=true willWrite=true"
        )
        let install = DiagnosticFormatting.documentEdited(
            site: "install",
            windowExisted: true,
            previous: false,
            requested: true,
            willWrite: true
        )
        XCTAssertNotEqual(update.signature, install.signature)
        XCTAssertTrue(install.message.contains("site=install"))
        let missing = DiagnosticFormatting.documentEdited(
            site: "update",
            windowExisted: false,
            previous: nil,
            requested: false,
            willWrite: false
        )
        XCTAssertTrue(missing.message.contains("previous=none"))
        XCTAssertTrue(missing.message.contains("willWrite=false"))
    }

    func testReviewFocusSignatureIgnoresNothingButTheCommandBooleans() {
        let snapshot = ReviewCommandFocusSnapshot(
            canSaveAll: false,
            canUndo: true,
            canRedo: false,
            canMerge: false,
            canDelete: true,
            canStepProblem: true,
            canNextFile: false,
            showPictures: false
        )
        let line = DiagnosticFormatting.reviewFocus(snapshot, menu: "closed")
        XCTAssertTrue(line.coalesce)
        XCTAssertTrue(line.message.contains("undo=true"))
        XCTAssertTrue(line.message.contains("delete=true"))
        XCTAssertFalse(line.message.contains("cue"))
        let same = DiagnosticFormatting.reviewFocus(snapshot, menu: "closed")
        XCTAssertEqual(line.signature, same.signature)
        let otherMenu = DiagnosticFormatting.reviewFocus(snapshot, menu: "file")
        XCTAssertNotEqual(line.signature, otherMenu.signature)
    }

    func testStartupLineStatesBothFlags() {
        XCTAssertEqual(
            DiagnosticFormatting.startup(version: "0.1.2", build: "4", tracing: true, stableCommands: false).message,
            "diagnostics on version=0.1.2 build=4 tracing=on stable-commands=off"
        )
    }

    private func item(_ status: ConversionStatus) -> ConversionItem {
        ConversionItem(id: UUID(), sourcePath: "/tmp/source.sup", name: "source.sup", status: status)
    }

    private func model(progress: String, menu: String) -> DiagnosticEvent {
        let parts = progress.split(separator: "/")
        let completed = Int(parts[0]) ?? 0
        let total = Int(parts[1]) ?? 0
        let snapshot = QueueCommandSnapshot(
            itemCount: 1,
            activeCount: 1,
            removableCount: 0,
            hasCancellableWork: true,
            canClearFinished: false,
            hasReviewsNeedingSave: false,
            progress: .converting(completed: completed, total: total)
        )
        return DiagnosticFormatting.modelRefresh(snapshot, menu: menu)
    }

    private func commands(menu: String) -> DiagnosticEvent {
        DiagnosticFormatting.commandsEval(
            hasCancellableWork: true,
            canClearFinished: false,
            hasReviewsNeedingSave: false,
            reviewFocused: false,
            queueCanReview: false,
            menu: menu
        )
    }
}
