import XCTest
import PGSCore

final class DebugLogTests: XCTestCase {
    func testHomeFolderBecomesATilde() throws {
        let home = "/Users/ada"
        XCTAssertEqual(
            PathRedaction.redact("\(home)/Desktop/Movie.sup", homeDirectory: home),
            "~/Desktop/Movie.sup"
        )
        XCTAssertEqual(PathRedaction.redact(home, homeDirectory: home), "~")
        XCTAssertEqual(
            PathRedaction.redact("\(home)/Movies/a.sup", homeDirectory: home + "/"),
            "~/Movies/a.sup"
        )
        XCTAssertEqual(
            PathRedaction.redact("read \(home)/a wrote \(home)/b", homeDirectory: home),
            "read ~/a wrote ~/b"
        )
        XCTAssertEqual(
            PathRedaction.redact("/USERS/ada/Desktop/a.sup", homeDirectory: home),
            "~/Desktop/a.sup"
        )
        XCTAssertEqual(
            PathRedaction.redact("file:///Users/ada/Movies/a.sup", homeDirectory: home),
            "file://~/Movies/a.sup"
        )
        XCTAssertEqual(
            PathRedaction.redact("/Users/ada2/Movie.sup", homeDirectory: home),
            "/Users/ada2/Movie.sup"
        )
        XCTAssertEqual(PathRedaction.redact("/tmp/Movie.sup", homeDirectory: home), "/tmp/Movie.sup")
        XCTAssertEqual(PathRedaction.redact("\(home)/a", homeDirectory: ""), "\(home)/a")
        XCTAssertEqual(PathRedaction.redact("\(home)/a", homeDirectory: "/"), "\(home)/a")
    }

    func testASymlinkedHomeIsRedactedToo() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pgs-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(
            PathRedaction.redact(link.appendingPathComponent("Movie.sup").path, homeDirectory: link.path),
            "~/Movie.sup"
        )
        let shown = real.appendingPathComponent("Movie.sup").path
        let redacted = PathRedaction.redact(shown, homeDirectory: link.path)
        XCTAssertEqual(redacted, "~/Movie.sup")
        XCTAssertFalse(redacted.contains(real.path))
    }

    func testHeaderListsVersionMachineToolAndSettings() {
        let settings = ConversionPreferences(
            placement: .folder("/Users/ada/Subs"),
            language: "en-US",
            existingFile: .addNumber,
            concurrency: 4,
            experimentalItalics: true,
            chooseMKVTrack: true
        )
        let environment = DebugEnvironment(
            appVersion: "0.1.0",
            appBuild: "1",
            operatingSystem: "Version 14.5 (Build 23F79)",
            model: "MacBookPro18,3",
            chip: DebugChip.label(architecture: "arm64", runningUnderRosetta: false),
            architecture: "arm64",
            runningUnderRosetta: false,
            mkvToolNixPath: "/Users/ada/bin/mkvmerge",
            mkvToolNixVersion: "mkvmerge v86.0 ('Winter') 64-bit",
            settings: settings.logDescription
        )
        let document = DebugLogDocument.document(
            environment: environment,
            logText: "2026-10-30 [queue] info Added Movie.sup\n",
            homeDirectory: "/Users/ada"
        )
        XCTAssertTrue(document.contains("PGS2SRT debug log"))
        XCTAssertTrue(document.contains("App version: 0.1.0"))
        XCTAssertTrue(document.contains("App build: 1"))
        XCTAssertTrue(document.contains("macOS: Version 14.5 (Build 23F79)"))
        XCTAssertTrue(document.contains("Model: MacBookPro18,3"))
        XCTAssertTrue(document.contains("Chip: Apple silicon"))
        XCTAssertTrue(document.contains("Architecture: arm64"))
        XCTAssertTrue(document.contains("Rosetta: no"))
        XCTAssertTrue(document.contains("MKVToolNix: ~/bin/mkvmerge"))
        XCTAssertTrue(document.contains("MKVToolNix version: mkvmerge v86.0 ('Winter') 64-bit"))
        XCTAssertTrue(document.contains("Settings:"))
        XCTAssertTrue(document.contains("language en-US"))
        XCTAssertTrue(document.contains("folder ~/Subs"))
        XCTAssertTrue(document.contains("if the .srt exists add a number"))
        XCTAssertTrue(document.contains("4 pictures at a time"))
        XCTAssertTrue(document.contains("italics on"))
        XCTAssertTrue(document.contains("choose MKV track on"))
        XCTAssertTrue(document.contains("Added Movie.sup"))
        XCTAssertFalse(document.contains("/Users/ada"))
        let settingsRange = try? XCTUnwrap(document.range(of: "Settings:"))
        let logRange = try? XCTUnwrap(document.range(of: "Added Movie.sup"))
        if let settingsRange, let logRange {
            XCTAssertLessThan(settingsRange.lowerBound, logRange.lowerBound)
        }

        XCTAssertEqual(
            ConversionPreferences.default.logDescription,
            "language en-US, save next to the source file, if the .srt exists overwrite, 4 pictures at a time, italics off, choose MKV track off"
        )
    }

    func testHeaderWhenTheToolIsMissingAndTheMacIsUnderRosetta() {
        let environment = DebugEnvironment(
            appVersion: "0.1.0",
            appBuild: "42",
            operatingSystem: "Version 15.0 (Build 24A335)",
            model: "Mac14,6",
            chip: DebugChip.label(architecture: "x86_64", runningUnderRosetta: true),
            architecture: "x86_64",
            runningUnderRosetta: true,
            mkvToolNixPath: nil,
            mkvToolNixVersion: nil,
            settings: "language en-US"
        )
        let header = DebugLogDocument.header(for: environment)
        XCTAssertTrue(header.contains("App build: 42"))
        XCTAssertTrue(header.contains("Chip: Apple silicon"))
        XCTAssertTrue(header.contains("Architecture: x86_64"))
        XCTAssertTrue(header.contains("Rosetta: yes"))
        XCTAssertTrue(header.contains("MKVToolNix: not found"))
        XCTAssertTrue(header.contains("MKVToolNix version: not found"))
        XCTAssertEqual(DebugChip.label(architecture: "x86_64", runningUnderRosetta: false), "Intel")
    }

    func testFileNameUsesYearMonthDayAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 10,
            day: 30,
            hour: 17,
            minute: 5,
            second: 9
        ))!
        XCTAssertEqual(
            DebugLogDocument.fileName(at: date, timeZone: TimeZone(secondsFromGMT: 0)!),
            "PGS2SRT-debug-log-2026-10-30-170509.txt"
        )
        XCTAssertEqual(
            DebugLogDocument.fileName(at: date, timeZone: TimeZone(secondsFromGMT: -3600)!),
            "PGS2SRT-debug-log-2026-10-30-160509.txt"
        )
    }

    func testRecordRedactsTheHomeFolderBeforeWriting() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 2,
            hour: 3,
            minute: 4,
            second: 5
        ))!
        let log = DebugLog(homeDirectory: "/Users/ada", timeZone: zone)
        XCTAssertEqual(log.recentText(), "")
        log.record(.queue, "Added /Users/ada/Movies/Movie.sup (12 bytes, sup)", date: date)
        log.configure(directory: directory, homeDirectory: "/Users/ada", timeZone: zone)
        log.record(.queue, "Added /Users/ada/Movies/Movie.sup (12 bytes, sup)", date: date)
        let text = log.recentText()
        XCTAssertTrue(text.contains("2026-01-02 03:04:05"))
        XCTAssertTrue(text.contains("[queue]"))
        XCTAssertTrue(text.contains("~/Movies/Movie.sup"))
        XCTAssertFalse(text.contains("/Users/ada"))
    }

    func testExportLineNamesTheDesktopFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "PGS2SRT-debug-log-2026-10-30-170509.txt"
        let log = DebugLog(homeDirectory: "/Users/ada", timeZone: TimeZone(secondsFromGMT: 0)!)
        log.configure(directory: directory, homeDirectory: "/Users/ada", timeZone: TimeZone(secondsFromGMT: 0)!)
        log.record(.lifecycle, "Exporting debug log to /Users/ada/Desktop/\(name)")
        let text = log.recentText()
        XCTAssertTrue(text.contains("[lifecycle] info Exporting debug log to ~/Desktop/\(name)"))
        XCTAssertFalse(text.contains("/Users/ada"))
        XCTAssertFalse(text.hasSuffix("Exporting debug log\n"))
    }

    func testAWarningIsMarkedInTheLog() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DebugLog(homeDirectory: "/Users/ada")
        log.configure(directory: directory, homeDirectory: "/Users/ada")
        log.record(.mkv, "Temp folder removal failed PGS2SRT-abc: permission denied", isWarning: true)
        let text = log.recentText()
        XCTAssertTrue(text.contains("[mkv] warning Temp folder removal failed PGS2SRT-abc: permission denied"))
        XCTAssertFalse(text.contains("[mkv] error"))
    }

    func testRecognizedSubtitleTextStaysOutOfTheLog() async throws {
        let directory = temporaryDirectory()
        defer {
            DebugLog.shared.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        DebugLog.shared.configure(directory: directory, homeDirectory: "/Users/ada")
        let phrase = "Zed quin subtitle 9041"
        let pipeline = TranscriptionPipeline(languages: ["en-US"], maxConcurrent: 1)
        let result = try await pipeline.transcribe(
            cues: [DebugLogSample.cue()],
            recognizer: DebugLogSample.Recognizer(text: phrase)
        )
        XCTAssertTrue(result.srt.contains(phrase))
        let log = DebugLog.shared.recentText()
        XCTAssertTrue(log.contains("[ocr]"))
        XCTAssertTrue(log.contains("OCR finished, 1 cues, 0 failed"))
        XCTAssertFalse(log.contains(phrase))
        XCTAssertFalse(log.contains("/Users/ada"))
    }

    func testRollingLogDropsTheOldestLinesAndStaysUnderTheCap() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let maxTotal = 300
        let fileCount = 3
        let store = RollingLogStore(directory: directory, maxTotalBytes: maxTotal, fileCount: fileCount)
        let payload = "0123456789"
        for index in 0..<80 {
            store.append(String(format: "%02d-", index) + payload)
        }
        let text = store.combinedText()
        XCTAssertTrue(text.contains("79-" + payload))
        XCTAssertFalse(text.contains("00-" + payload))
        XCTAssertGreaterThan(text.utf8.count, store.maxFileBytes)
        let lines = text.split(separator: "\n").map(String.init)
        let firstIndex = Int(lines.first?.prefix(2) ?? "")
        let lastIndex = Int(lines.last?.prefix(2) ?? "")
        XCTAssertEqual(lastIndex, 79)
        XCTAssertLessThan(firstIndex ?? 99, lastIndex ?? 0)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let allowed: Set<String> = ["PGS2SRT.log", "PGS2SRT.log.1", "PGS2SRT.log.2"]
        XCTAssertEqual(files.count, fileCount)
        var total = 0
        for file in files {
            XCTAssertTrue(allowed.contains(file.lastPathComponent))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
            XCTAssertLessThanOrEqual(size, store.maxFileBytes)
            total += size
        }
        XCTAssertLessThanOrEqual(total, maxTotal)
        XCTAssertTrue(files.contains(where: { $0.lastPathComponent == "PGS2SRT.log" }))
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pgs-log-\(UUID().uuidString)", isDirectory: true)
    }
}

private enum DebugLogSample {
    static func cue() -> SubtitleCue {
        SubtitleCue(
            startPTS: 0,
            endPTS: 90_000,
            image: SubtitleImage(
                width: 1,
                height: 1,
                rgba: [0, 0, 0, 0],
                originX: 0,
                originY: 0,
                videoWidth: 100,
                videoHeight: 100
            ),
            forced: false,
            endReason: .clearingDisplaySet
        )
    }

    struct Recognizer: SubtitleRecognizing {
        var text: String
        func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
            OCRResult(text: text)
        }
    }
}
