import Foundation
import PGSCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let arguments = CommandLine.arguments
if arguments.count == 2 && (arguments[1] == "-h" || arguments[1] == "--help") {
    writeStderr("Usage: pgsdump <input.sup> <output-directory>\n")
    exit(0)
}
guard arguments.count == 3 else {
    writeStderr("Usage: pgsdump <input.sup> <output-directory>\n")
    exit(2)
}

do {
    let input = arguments[1]
    let output = arguments[2]
    let data = try Data(contentsOf: URL(fileURLWithPath: input))
    let cues = try PGSDecoder().decode(data)
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    var lines: [String] = []
    for (offset, cue) in cues.enumerated() {
        let filename = pad(offset + 1, 4) + ".pam"
        try cue.image.pamData().write(to: directory.appendingPathComponent(filename))
        let line = "\(offset + 1)\t\(SRTWriter.timestamp(pts: cue.startPTS)) --> \(SRTWriter.timestamp(pts: cue.endPTS))\t\(cue.image.width)x\(cue.image.height)+\(cue.image.originX)+\(cue.image.originY)\tforced=\(cue.forced)"
        lines.append(line)
        print(line)
    }
    let summary = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    try summary.write(to: directory.appendingPathComponent("cues.txt"), atomically: true, encoding: .utf8)
} catch {
    writeStderr("pgsdump: \(error.localizedDescription)\n")
    exit(1)
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

func pad(_ value: Int, _ width: Int) -> String {
    let text = String(value)
    if text.count >= width { return text }
    return String(repeating: "0", count: width - text.count) + text
}
