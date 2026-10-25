import XCTest
import PGSCore

final class FileIntakeTests: XCTestCase {
    func testFolderSearchKeepsSupFilesAndIgnoresOtherTypesInside() {
        let listing = MapListing(directories: [
            "/films": ["/films/Movie.sup", "/films/nested", "/films/Extra.mkv", "/films/notes.txt"],
            "/films/nested": ["/films/nested/Two.SUP"]
        ])
        let result = FileIntake.collect(paths: ["/films"], listing: listing.listing)
        XCTAssertEqual(result.supPaths, ["/films/Movie.sup", "/films/nested/Two.SUP"])
        XCTAssertEqual(result.notices, [])
    }

    func testExplicitMkvAndOtherFilesAreNoted() {
        let result = FileIntake.collect(
            paths: ["/films/Movie.mkv", "/films/Poster.jpg", "/films/Movie.sup", "/films/Movie.sup"],
            listing: MapListing(directories: [:]).listing
        )
        XCTAssertEqual(result.supPaths, ["/films/Movie.sup"])
        XCTAssertEqual(result.notices, [
            .mkv(path: "/films/Movie.mkv"),
            .notSubtitle(path: "/films/Poster.jpg")
        ])
        XCTAssertEqual(result.notices[0].message, "MKV support is coming.")
    }

    func testEmptyAndUnreadableFolders() {
        let listing = MapListing(
            directories: ["/empty": []],
            unreadable: ["/locked"]
        )
        let empty = FileIntake.collect(paths: ["/empty/"], listing: listing.listing)
        XCTAssertEqual(empty.supPaths, [])
        XCTAssertEqual(empty.notices, [.noSubtitles(folderName: "empty")])

        let locked = FileIntake.collect(paths: ["/locked"], listing: listing.listing)
        XCTAssertEqual(locked.notices, [.unreadableFolder(folderName: "locked")])
        XCTAssertEqual(locked.notices[0].message, "Could not look inside locked.")
    }

    func testADirectoryLinkBackToItsParentDoesNotLoop() {
        let listing = MapListing(
            directories: [
                "/films": ["/films/Movie.sup", "/films/loop"],
                "/films/loop": ["/films/loop"]
            ],
            identities: ["/films/loop": "/films"]
        )
        let result = FileIntake.collect(paths: ["/films", "/films"], listing: listing.listing)
        XCTAssertEqual(result.supPaths, ["/films/Movie.sup"])
        XCTAssertEqual(result.notices, [])
        XCTAssertEqual(listing.reads, ["/films"])
    }

    func testLiveListingFindsNestedSupFilesAndSkipsHiddenOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pgs-intake-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appendingPathComponent("A.sup").path, contents: Data([1])))
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.appendingPathComponent("B.SUP").path, contents: Data([2])))
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appendingPathComponent("C.mkv").path, contents: Data([3])))
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appendingPathComponent(".hidden.sup").path, contents: Data([4])))

        let result = FileIntake.collect(paths: [root.path], listing: .live)
        XCTAssertEqual(result.supPaths.sorted(), [
            root.appendingPathComponent("A.sup").path,
            nested.appendingPathComponent("B.SUP").path
        ].sorted())
        XCTAssertEqual(result.notices, [])
    }
}

private final class MapListing: @unchecked Sendable {
    var directories: [String: [String]]
    var unreadable: Set<String>
    var identities: [String: String]
    private(set) var reads: [String] = []

    init(
        directories: [String: [String]],
        unreadable: Set<String> = [],
        identities: [String: String] = [:]
    ) {
        self.directories = directories
        self.unreadable = unreadable
        self.identities = identities
    }

    var listing: DirectoryListing {
        DirectoryListing(
            isDirectory: { path in
                self.directories[path] != nil || self.unreadable.contains(path)
            },
            children: { path in
                self.reads.append(path)
                if self.unreadable.contains(path) {
                    throw CocoaError(.fileReadNoPermission)
                }
                return self.directories[path] ?? []
            },
            identity: { self.identities[$0] ?? $0 }
        )
    }
}
