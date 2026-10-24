import XCTest
import PGSCore

/// Real `.sup` files are optional. Drop them in `Tests/PGSCoreTests/Fixtures/`
/// and `swift test` will decode each one. See the README.
final class FixtureTests: XCTestCase {
    func testRealSUPFixturesIfPresent() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let samples = files.filter { $0.pathExtension.lowercased() == "sup" }
        if samples.isEmpty { return }

        let decoder = PGSDecoder()
        for sample in samples {
            let data = try Data(contentsOf: sample)
            let cues = try decoder.decode(data)
            XCTAssertFalse(cues.isEmpty, "\(sample.lastPathComponent) decoded no subtitles")
            for cue in cues {
                XCTAssertEqual(cue.image.rgba.count, cue.image.width * cue.image.height * 4)
                XCTAssertGreaterThanOrEqual(cue.endPTS, cue.startPTS)
            }
        }
    }
}
