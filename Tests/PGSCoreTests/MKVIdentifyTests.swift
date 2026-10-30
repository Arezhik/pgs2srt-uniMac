import XCTest
@testable import PGSCore

final class MKVIdentifyTests: XCTestCase {
    func testEnglishPGSWinsOverAnEarlierTrackAndATextSubtitle() throws {
        let tracks = try MKVIdentify.tracks(in: fixture("english-later"))
        XCTAssertEqual(tracks.map(\.id), [2, 4, 6])
        XCTAssertEqual(tracks[0].number, 3)
        XCTAssertEqual(tracks[0].language, "jpn")
        XCTAssertEqual(tracks[0].languageIETF, "ja")
        XCTAssertEqual(tracks[0].name, "Japanese")
        XCTAssertTrue(tracks[0].forced)
        XCTAssertTrue(tracks[0].isDefault)
        XCTAssertFalse(tracks[0].isEnglish)
        XCTAssertEqual(tracks[0].displayLanguage, "ja")

        XCTAssertEqual(tracks[1].number, 5)
        XCTAssertEqual(tracks[1].name, "English")
        XCTAssertTrue(tracks[1].isEnglish)
        XCTAssertEqual(tracks[1].displayLanguage, "English")
        XCTAssertFalse(tracks[1].forced)
        XCTAssertFalse(tracks[1].isDefault)

        let preferred = MKVIdentify.preferredTrack(in: tracks)
        XCTAssertEqual(preferred?.id, 4)
        XCTAssertEqual(preferred?.name, "English")
    }

    func testWithoutEnglishTheFirstPGSTrackIsUsed() throws {
        let tracks = try MKVIdentify.tracks(in: fixture("first-pgs"))
        XCTAssertEqual(tracks.map(\.id), [3, 5])
        XCTAssertFalse(tracks[0].isEnglish)
        XCTAssertFalse(tracks[1].isEnglish)
        XCTAssertFalse(tracks[1].forced)
        XCTAssertTrue(tracks[1].isDefault)
        XCTAssertEqual(MKVIdentify.preferredTrack(in: tracks)?.id, 3)
        XCTAssertEqual(tracks[0].displayLanguage, "ja")
    }

    func testNoPGSTrack() throws {
        let tracks = try MKVIdentify.tracks(in: fixture("no-pgs"))
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertNil(MKVIdentify.preferredTrack(in: tracks))
    }

    func testATrackWithNoLanguageIsStillSelectable() throws {
        let tracks = try MKVIdentify.tracks(in: fixture("missing-language"))
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.id, 8)
        XCTAssertEqual(track.number, 9)
        XCTAssertEqual(track.language, "")
        XCTAssertEqual(track.languageIETF, "")
        XCTAssertEqual(track.name, "Signs")
        XCTAssertFalse(track.isEnglish)
        XCTAssertEqual(track.displayLanguage, "Unknown")
        XCTAssertFalse(track.forced)
        XCTAssertFalse(track.isDefault)
        XCTAssertEqual(MKVIdentify.preferredTrack(in: tracks)?.id, 8)
    }

    func testLanguageCodesAndACodecIdOnTheTrackItself() throws {
        XCTAssertTrue(PGSSubtitleTrack.isEnglishLanguage("eng"))
        XCTAssertTrue(PGSSubtitleTrack.isEnglishLanguage("EN"))
        XCTAssertTrue(PGSSubtitleTrack.isEnglishLanguage("en-US"))
        XCTAssertTrue(PGSSubtitleTrack.isEnglishLanguage("en_GB"))
        XCTAssertFalse(PGSSubtitleTrack.isEnglishLanguage("und"))
        XCTAssertFalse(PGSSubtitleTrack.isEnglishLanguage(""))
        XCTAssertFalse(PGSSubtitleTrack.isEnglishLanguage("jpn"))
        XCTAssertFalse(PGSSubtitleTrack.isEnglishLanguage("english"))

        let json = Data(
            """
            {"tracks":[{"id":1,"codec":"S_HDMV/PGS","properties":{"language":"en"}}]}
            """.utf8
        )
        let tracks = try MKVIdentify.tracks(in: json)
        XCTAssertEqual(tracks.map(\.id), [1])
        XCTAssertEqual(tracks[0].number, 1)
        XCTAssertTrue(tracks[0].isEnglish)
        XCTAssertEqual(MKVIdentify.preferredTrack(in: tracks)?.id, 1)
    }

    func testUnreadableJSON() {
        XCTAssertThrowsError(try MKVIdentify.tracks(in: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? MKVFailure, .unreadableTracks)
        }
        XCTAssertThrowsError(try MKVIdentify.tracks(in: Data("[]".utf8))) { error in
            XCTAssertEqual(error as? MKVFailure, .unreadableTracks)
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mkv/\(name).json")
        return try Data(contentsOf: url)
    }
}
