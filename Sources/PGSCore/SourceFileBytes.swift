import Foundation

/// Bytes of a file the person picked.
///
/// The read is split into pieces so Cancel can stop while a long `.sup` is
/// still coming off disk. A piece is large enough that a normal file is only
/// a few reads.
public enum SourceFileBytes {
    static let chunkBytes = 1_048_576

    public static func read(_ path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { _ = try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let total = Int(exactly: length) else {
            throw CocoaError(.fileReadTooLarge)
        }
        var data = Data()
        data.reserveCapacity(total)
        var remaining = total
        while remaining > 0 {
            try Task.checkCancellation()
            let amount = min(chunkBytes, remaining)
            let piece = try handle.read(upToCount: amount) ?? Data()
            if piece.isEmpty { break }
            data.append(piece)
            remaining -= piece.count
        }
        return data
    }
}
