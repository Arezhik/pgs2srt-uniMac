import XCTest
import PGSCore

final class MKVToolNixTests: XCTestCase {
    func testHomebrewIsPreferredOverTheAppBundleAndPath() {
        let tools = MKVToolNix.locate(
            executableExists: { path in
                path == "/opt/homebrew/bin/mkvmerge"
                    || path == "/opt/homebrew/bin/mkvextract"
                    || path == "/usr/local/bin/mkvmerge"
                    || path == "/usr/local/bin/mkvextract"
                    || path == "/Applications/MKVToolNix.app/Contents/MacOS/mkvmerge"
                    || path == "/Applications/MKVToolNix.app/Contents/MacOS/mkvextract"
                    || path == "/custom/bin/mkvmerge"
                    || path == "/custom/bin/mkvextract"
            },
            applications: ["MKVToolNix.app", "Other.app"],
            searchPath: "/custom/bin:/usr/bin"
        )
        XCTAssertEqual(tools?.mkvmerge, "/opt/homebrew/bin/mkvmerge")
        XCTAssertEqual(tools?.mkvextract, "/opt/homebrew/bin/mkvextract")
    }

    func testUsrLocalIsUsedWhenHomebrewIsMissing() {
        let tools = MKVToolNix.locate(
            executableExists: { path in
                path == "/usr/local/bin/mkvmerge" || path == "/usr/local/bin/mkvextract"
            },
            applications: [],
            searchPath: ""
        )
        XCTAssertEqual(tools?.mkvmerge, "/usr/local/bin/mkvmerge")
        XCTAssertEqual(tools?.mkvextract, "/usr/local/bin/mkvextract")
    }

    func testAnAppBundleIsUsedWhenTheBinariesAreNotInstalledElsewhere() {
        let tools = MKVToolNix.locate(
            executableExists: { path in
                path.hasPrefix("/Applications/MKVToolNix")
            },
            applications: ["VLC.app", "MKVToolNix-99.app", "MKVToolNix.app"],
            searchPath: "/usr/bin"
        )
        XCTAssertEqual(
            tools?.mkvmerge,
            "/Applications/MKVToolNix-99.app/Contents/MacOS/mkvmerge"
        )
        XCTAssertEqual(
            tools?.mkvextract,
            "/Applications/MKVToolNix-99.app/Contents/MacOS/mkvextract"
        )
    }

    func testPathIsTheLastPlaceAndBothToolsAreRequired() {
        let tools = MKVToolNix.locate(
            executableExists: { path in
                path == "/custom/bin/mkvmerge" || path == "/custom/bin/mkvextract"
            },
            applications: ["MKVToolNix.app"],
            searchPath: "/custom/bin:/opt/homebrew/bin"
        )
        XCTAssertEqual(tools?.mkvmerge, "/custom/bin/mkvmerge")
        XCTAssertEqual(tools?.mkvextract, "/custom/bin/mkvextract")

        let mergeOnly = MKVToolNix.locate(
            executableExists: { $0 == "/opt/homebrew/bin/mkvmerge" },
            applications: [],
            searchPath: "/usr/bin"
        )
        XCTAssertNil(mergeOnly)

        let split = MKVToolNix.locate(
            executableExists: { path in
                path == "/opt/homebrew/bin/mkvmerge" || path == "/custom/bin/mkvextract"
            },
            applications: [],
            searchPath: "/custom/bin"
        )
        XCTAssertEqual(split?.mkvmerge, "/opt/homebrew/bin/mkvmerge")
        XCTAssertEqual(split?.mkvextract, "/custom/bin/mkvextract")
    }

    func testACommandReturnsItsOutput() async throws {
        let echo = executable(["/bin/echo", "/usr/bin/echo"])
        let result = try await MKVCommand.run(executable: echo, arguments: ["hello"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "hello\n")
    }

    func testCancelTerminatesARunningProcess() async throws {
        let sleep = executable(["/bin/sleep", "/usr/bin/sleep"])
        let started = Date()
        let task = Task {
            try await MKVCommand.run(executable: sleep, arguments: ["30"])
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the sleep to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAMissingToolDoesNotHang() async {
        do {
            _ = try await MKVCommand.run(executable: "/no/such/mkvmerge", arguments: ["--version"])
            XCTFail("expected the launch to fail")
        } catch let error as MKVFailure {
            XCTAssertEqual(error, .couldNotStartTool)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testInstalledMKVToolNixRespondsToVersion() async throws {
        guard let tools = MKVToolNix.locate() else {
            throw XCTSkip("MKVToolNix is not installed")
        }
        let merge = try await MKVCommand.run(executable: tools.mkvmerge, arguments: ["--version"])
        XCTAssertEqual(merge.status, 0)
        XCTAssertFalse(merge.standardOutput.isEmpty)
        let extract = try await MKVCommand.run(executable: tools.mkvextract, arguments: ["--version"])
        XCTAssertEqual(extract.status, 0)
        XCTAssertFalse(extract.standardOutput.isEmpty)
    }

    private func executable(_ candidates: [String]) -> String {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }
}
