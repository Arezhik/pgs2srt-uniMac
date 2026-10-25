import Foundation
import PGSCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)
import VisionOCR
#endif

@main
struct PGS2SRTCLI {
    static func main() async {
        do {
            switch try ConversionCommand.parse(CommandLine.arguments) {
            case .help:
                print(ConversionCommand.helpText)
            case let .convert(command):
                let code = await convert(command)
                if code != 0 {
                    exit(code)
                }
            }
        } catch {
            let message = "pgs2srt: \(error.localizedDescription)\n\n\(ConversionCommand.helpText)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(2)
        }
    }

    static func convert(_ command: ConversionCommand) async -> Int32 {
        #if os(macOS)
        return await convertOnMac(command)
        #else
        let message = "pgs2srt: text recognition uses Apple Vision and only runs on macOS.\n"
        FileHandle.standardError.write(Data(message.utf8))
        return 1
        #endif
    }
}

#if os(macOS)
private func convertOnMac(_ command: ConversionCommand) async -> Int32 {
    do {
        let input = URL(fileURLWithPath: command.inputPath)
        let data = try Data(contentsOf: input)
        let pipeline = TranscriptionPipeline(
            languages: command.languages,
            maxConcurrent: command.jobs,
            italics: command.italics
        )
        let log = StandardError()
        let result = try await pipeline.transcribeFile(data: data, recognizer: VisionOCR()) { progress in
            log.write("\(progress.completed)/\(progress.total)\n")
        }
        let output = URL(fileURLWithPath: command.outputPath)
        try result.srt.write(to: output, atomically: true, encoding: .utf8)
        var summary = "Wrote \(command.outputPath)\nCues: \(result.cues.count)\nUnrecognized: \(result.failures.count)\n"
        for failure in result.failures {
            summary += "  \(failure.description)\n"
        }
        FileHandle.standardError.write(Data(summary.utf8))
        return 0
    } catch {
        let message = "pgs2srt: \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
        return 1
    }
}

private final class StandardError: @unchecked Sendable {
    func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
#endif
