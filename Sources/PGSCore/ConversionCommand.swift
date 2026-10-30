import Foundation

/// Arguments for the `pgs2srt` command. Parsing lives here so it can be tested
/// without a Mac. The command itself calls Apple Vision and only converts on macOS.
public struct ConversionCommand: Equatable, Sendable {
    public var inputPath: String
    public var outputPath: String
    public var languages: [String]
    public var jobs: Int
    /// Experimental. Wrap leaning lines in `<i>`. Off unless `--italics` is passed.
    public var italics: Bool

    public init(inputPath: String, outputPath: String, languages: [String], jobs: Int, italics: Bool) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.languages = languages
        self.jobs = jobs
        self.italics = italics
    }

    public enum ParseOutcome: Equatable, Sendable {
        case help
        case convert(ConversionCommand)
    }

    public static let helpText = """
    pgs2srt — read a Blu-ray PGS .sup file and write an .srt subtitle file

    Usage:
      pgs2srt <input.sup> [output.srt] [--lang <tag>]... [--jobs <n>] [--italics]

    The .srt file is written next to the .sup file when you leave out output.srt.
    Text recognition uses Apple Vision and only runs on a Mac.

    Options:
      --lang <tag>   Language to look for, such as en-US or fr-FR. Repeat to add another.
                     Default: en-US
      --jobs <n>     How many subtitle pictures to read at the same time. Default: 4
      --italics      Experimental. Wrap a line that leans to the right in <i> tags.
                     Off by default. Upright Blu-ray type was often marked by mistake.
      -h, --help     Show this help
    """

    /// `arguments` is the full command line, including the program name at index 0.
    public static func parse(_ arguments: [String]) throws -> ParseOutcome {
        let args = Array(arguments.dropFirst())
        if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
            return .help
        }
        var input: String?
        var output: String?
        var languages: [String] = []
        var jobs = 4
        var italics = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--italics" {
                italics = true
            } else if argument == "--lang" {
                index += 1
                guard index < args.count else { throw ConversionCommandError.missingLanguage }
                languages.append(try language(args[index]))
            } else if argument.hasPrefix("--lang=") {
                languages.append(try language(String(argument.dropFirst("--lang=".count))))
            } else if argument == "--jobs" {
                index += 1
                guard index < args.count else { throw ConversionCommandError.missingJobs }
                jobs = try jobCount(args[index])
            } else if argument.hasPrefix("--jobs=") {
                jobs = try jobCount(String(argument.dropFirst("--jobs=".count)))
            } else if argument.hasPrefix("-") {
                throw ConversionCommandError.unknownOption(argument)
            } else if input == nil {
                input = argument
            } else if output == nil {
                output = argument
            } else {
                throw ConversionCommandError.unexpectedArgument(argument)
            }
            index += 1
        }
        guard let input else { throw ConversionCommandError.missingInput }
        if languages.isEmpty { languages = ["en-US"] }
        let outputPath = output ?? defaultOutputPath(for: input)
        return .convert(
            ConversionCommand(
                inputPath: input,
                outputPath: outputPath,
                languages: languages,
                jobs: jobs,
                italics: italics
            )
        )
    }

    /// `movie.sup` and `movie.mkv` become `movie.srt` in the same directory.
    /// The path is not looked up on disk, and a relative path stays relative.
    public static func defaultOutputPath(for inputPath: String) -> String {
        let path = inputPath as NSString
        let ext = path.pathExtension.lowercased()
        if ext == "sup" || ext == "mkv" {
            let base = path.deletingPathExtension as NSString
            return base.appendingPathExtension("srt") ?? (path.deletingPathExtension + ".srt")
        }
        return path.appendingPathExtension("srt") ?? (inputPath + ".srt")
    }

    private static func language(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ConversionCommandError.missingLanguage }
        return trimmed
    }

    private static func jobCount(_ value: String) throws -> Int {
        guard let number = Int(value), number >= 1 else {
            throw ConversionCommandError.invalidJobs(value)
        }
        return number
    }
}

public enum ConversionCommandError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case missingInput
    case missingLanguage
    case missingJobs
    case invalidJobs(String)
    case unexpectedArgument(String)
    case unknownOption(String)

    public var description: String {
        switch self {
        case .missingInput:
            return "Give the path to a .sup file."
        case .missingLanguage:
            return "Add a language after --lang, such as en-US."
        case .missingJobs:
            return "Add a number after --jobs."
        case let .invalidJobs(value):
            return "Jobs must be a whole number of 1 or more, not \"\(value)\"."
        case let .unexpectedArgument(value):
            return "Unexpected extra argument \"\(value)\". Usage: pgs2srt <input.sup> [output.srt]"
        case let .unknownOption(value):
            return "Unknown option \"\(value)\"."
        }
    }

    public var errorDescription: String? { description }
}
