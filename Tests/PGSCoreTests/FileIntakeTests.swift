import XCTest
import PGSCore

final class FileIntakeTests: XCTestCase {
    func testFolderSearchKeepsSupFilesAndIgnoresOtherTypesInside() {
        let listing = MapListing(directories: [
            "/films": ["/films/Movie.sup", "/films/nested", "/films/Extra.mkv", "/films/notes.txt"],
            "/films/nested": ["/films/nested/Two.SUP"]
        ])
        let result = FileIntake.collect(paths: ["/films"], listing: listing.listing)
        XCTAssertEqual(result.sourcePaths, ["/films/Movie.sup", "/films/nested/Two.SUP", "/films/Extra.mkv"])
        XCTAssertEqual(result.notices, [])
    }

    func testExplicitMkvIsQueuedAndOtherFilesAreNoted() {
        let result = FileIntake.collect(
            paths: ["/films/Movie.mkv", "/films/Poster.jpg", "/films/Movie.sup", "/films/Movie.sup"],
            listing: MapListing(directories: [:]).listing
        )
        XCTAssertEqual(result.sourcePaths, ["/films/Movie.mkv", "/films/Movie.sup"])
        XCTAssertEqual(result.notices, [
            .notSubtitle(path: "/films/Poster.jpg")
        ])
        XCTAssertEqual(result.notices[0].message, "Poster.jpg is not a .sup or .mkv file, so it was skipped.")
    }

    func testEmptyAndUnreadableFolders() {
        let listing = MapListing(
            directories: ["/empty": []],
            unreadable: ["/locked"]
        )
        let empty = FileIntake.collect(paths: ["/empty/"], listing: listing.listing)
        XCTAssertEqual(empty.sourcePaths, [])
        XCTAssertEqual(empty.notices, [.noSubtitles(folderName: "empty")])
        XCTAssertEqual(empty.notices[0].message, "No .sup or .mkv files were found in empty.")

        let locked = FileIntake.collect(paths: ["/locked"], listing: listing.listing)
        XCTAssertEqual(locked.notices, [.unreadableFolder(folderName: "locked")])
        XCTAssertEqual(locked.notices[0].message, "Could not look inside locked.")
    }

    func testDockAndOpenWithAcceptSupFilesAndFolders() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let types = plist?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let contentTypes = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        let extensions = types.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
        XCTAssertTrue(contentTypes.contains("com.pgs2srt.pgs-subtitle"))
        XCTAssertTrue(contentTypes.contains("public.folder"))
        XCTAssertTrue(extensions.contains("sup"))
        XCTAssertTrue(extensions.contains("mkv"))
        XCTAssertTrue(contentTypes.contains("org.matroska.mkv"))
        let folder = types.first { ($0["LSItemContentTypes"] as? [String])?.contains("public.folder") == true }
        XCTAssertEqual(folder?["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(folder?["CFBundleTypeRole"] as? String, "Viewer")
        let mkv = types.first { ($0["CFBundleTypeExtensions"] as? [String])?.contains("mkv") == true }
        XCTAssertEqual(mkv?["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(mkv?["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(types.first?["CFBundleTypeExtensions"] as? [String], ["sup"])
        XCTAssertGreaterThanOrEqual(types.count, 3)
        XCTAssertEqual(types[1]["LSItemContentTypes"] as? [String], ["public.folder"])
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
        XCTAssertEqual(result.sourcePaths, ["/films/Movie.sup"])
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
        XCTAssertEqual(result.sourcePaths.sorted(), [
            root.appendingPathComponent("A.sup").path,
            root.appendingPathComponent("C.mkv").path,
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
