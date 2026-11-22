import XCTest
@testable import PGSCore

final class UITestingEnvironmentTests: XCTestCase {
    func testMissingEmptyAndWhitespaceKeysAreIgnored() {
        let env = [
            "UITEST_SOURCE_DIR": "",
            "UITEST_OUTPUT_DIR": "   ",
        ]
        XCTAssertNil(UITestingEnvironment.directory(named: "UITEST_SOURCE_DIR", from: env, directoryExists: { _ in true }))
        XCTAssertNil(UITestingEnvironment.directory(named: "UITEST_OUTPUT_DIR", from: env, directoryExists: { _ in true }))
        XCTAssertNil(UITestingEnvironment.directory(named: "UITEST_INPUT_DIR", from: env, directoryExists: { _ in true }))
    }

    func testNonDirectoryAndMissingPathsAreIgnored() {
        let env = [
            "UITEST_SOURCE_DIR": "/tmp/not-a-folder",
            "UITEST_OUTPUT_DIR": "/tmp/output-folder",
        ]
        let exists: (String) -> Bool = { $0 == "/tmp/output-folder" }
        XCTAssertNil(UITestingEnvironment.directory(named: "UITEST_SOURCE_DIR", from: env, directoryExists: exists))
        let output = UITestingEnvironment.directory(named: "UITEST_OUTPUT_DIR", from: env, directoryExists: exists)
        XCTAssertEqual(output?.path, "/tmp/output-folder")
        XCTAssertEqual(output?.hasDirectoryPath, true)
    }

    func testRealFolderIsReturnedAndAFileIsIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Input", isDirectory: true)
        let file = root.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let env = [
            "UITEST_INPUT_DIR": folder.path,
            "UITEST_OUTPUT_DIR": file.path,
        ]
        let found = UITestingEnvironment.directory(
            named: "UITEST_INPUT_DIR",
            from: env,
            directoryExists: AppFolderCheck.isFolder
        )
        XCTAssertEqual(found?.path, folder.path)
        XCTAssertNil(
            UITestingEnvironment.directory(
                named: "UITEST_OUTPUT_DIR",
                from: env,
                directoryExists: AppFolderCheck.isFolder
            )
        )
    }
}

/// Local folder check so the test stays in the package and does not need AppKit.
private enum AppFolderCheck {
    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
