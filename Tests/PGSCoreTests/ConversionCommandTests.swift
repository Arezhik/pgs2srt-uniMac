import XCTest
import PGSCore

final class ConversionCommandTests: XCTestCase {
    func testInputOnlyWritesSrtBesideTheSup() throws {
        let parsed = try ConversionCommand.parse(["pgs2srt", "Films/Movie.SUP"])
        guard case let .convert(command) = parsed else {
            return XCTFail("expected a conversion")
        }
        XCTAssertEqual(command.inputPath, "Films/Movie.SUP")
        XCTAssertEqual(command.outputPath, "Films/Movie.srt")
        XCTAssertEqual(command.languages, ["en-US"])
        XCTAssertEqual(command.jobs, 4)
        XCTAssertFalse(command.italics)
    }

    func testExplicitOutputLanguagesAndJobs() throws {
        let parsed = try ConversionCommand.parse([
            "pgs2srt", "--jobs", "2", "/tmp/in.sup", "--lang", "fr-FR", "--lang=de-DE", "/tmp/out.srt"
        ])
        guard case let .convert(command) = parsed else {
            return XCTFail("expected a conversion")
        }
        XCTAssertEqual(command.inputPath, "/tmp/in.sup")
        XCTAssertEqual(command.outputPath, "/tmp/out.srt")
        XCTAssertEqual(command.languages, ["fr-FR", "de-DE"])
        XCTAssertEqual(command.jobs, 2)
        XCTAssertFalse(command.italics)
        XCTAssertEqual(ConversionCommand.defaultOutputPath(for: "notes"), "notes.srt")
        XCTAssertEqual(ConversionCommand.defaultOutputPath(for: "/films/Movie.mkv"), "/films/Movie.srt")

        let withItalics = try ConversionCommand.parse(["pgs2srt", "Movie.sup", "--italics"])
        guard case let .convert(italicCommand) = withItalics else {
            return XCTFail("expected a conversion")
        }
        XCTAssertTrue(italicCommand.italics)
        XCTAssertTrue(ConversionCommand.helpText.contains("--italics"))
        XCTAssertTrue(ConversionCommand.helpText.contains("experimental") || ConversionCommand.helpText.contains("Experimental"))
    }

    func testHelpAndErrors() throws {
        let help = try ConversionCommand.parse(["pgs2srt", "file.sup", "--help"])
        XCTAssertEqual(help, .help)
        XCTAssertThrowsError(try ConversionCommand.parse(["pgs2srt"])) { error in
            XCTAssertEqual(error as? ConversionCommandError, .missingInput)
        }
        XCTAssertThrowsError(try ConversionCommand.parse(["pgs2srt", "a.sup", "--lang"])) { error in
            XCTAssertEqual(error as? ConversionCommandError, .missingLanguage)
        }
        XCTAssertThrowsError(try ConversionCommand.parse(["pgs2srt", "a.sup", "--jobs", "0"])) { error in
            XCTAssertEqual(error as? ConversionCommandError, .invalidJobs("0"))
        }
        XCTAssertThrowsError(try ConversionCommand.parse(["pgs2srt", "a.sup", "--nope"])) { error in
            XCTAssertEqual(error as? ConversionCommandError, .unknownOption("--nope"))
        }
        XCTAssertThrowsError(try ConversionCommand.parse(["pgs2srt", "a.sup", "b.srt", "extra"])) { error in
            XCTAssertEqual(error as? ConversionCommandError, .unexpectedArgument("extra"))
        }
    }
}
