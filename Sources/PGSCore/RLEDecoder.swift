import Foundation

/// Blu-ray PGS run-length encoding.
///
/// Each line is a sequence of codes ending in `00 00`. A line whose encoded
/// length (including that end marker) is odd is followed by a `00` pad so the
/// next line starts on a 16-bit boundary. Some writers omit the pad; both
/// forms are accepted when one of them decodes cleanly.
enum RLEDecoder {
    static func decode(data: Data, width: Int, height: Int, objectID: UInt16) throws -> [UInt8] {
        guard width > 0, height > 0 else {
            throw PGSError.rleDecodingFailed(
                objectID: objectID,
                message: "dimensions \(width)x\(height) are not usable."
            )
        }
        guard width <= 8192, height <= 8192 else {
            throw PGSError.rleDecodingFailed(
                objectID: objectID,
                message: "dimensions \(width)x\(height) are larger than 8192 pixels on a side."
            )
        }

        let padded = tryDecode(data: data, width: width, height: height, padOddLines: true)
        let plain = tryDecode(data: data, width: width, height: height, padOddLines: false)
        let paddedScore = score(padded, data: data, height: height)
        let plainScore = score(plain, data: data, height: height)

        // Retail Blu-ray streams pad odd lines. Trust that layout when it
        // consumes the buffer. Writers that omit the pad still decode when
        // the padded reading does not fit.
        if paddedScore == 2, let padded {
            return padded.pixels
        }
        if plainScore > paddedScore, let plain {
            return plain.pixels
        }
        if paddedScore > 0, let padded {
            return padded.pixels
        }
        if plainScore > 0, let plain {
            return plain.pixels
        }
        throw PGSError.rleDecodingFailed(
            objectID: objectID,
            message: "the run-length data is truncated or inconsistent for a \(width)x\(height) image."
        )
    }

    private struct Attempt {
        var pixels: [UInt8]
        var consumed: Int
    }

    /// 2 = consumed the buffer exactly, 1 = only a few trailing zero bytes left, 0 = unusable.
    private static func score(_ attempt: Attempt?, data: Data, height: Int) -> Int {
        guard let attempt else { return 0 }
        if attempt.consumed == data.count { return 2 }
        guard attempt.consumed < data.count else { return 0 }
        let extra = data.count - attempt.consumed
        if extra > height { return 0 }
        let start = data.startIndex + attempt.consumed
        for byte in data[start...] where byte != 0 {
            return 0
        }
        return 1
    }

    private static func tryDecode(data: Data, width: Int, height: Int, padOddLines: Bool) -> Attempt? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var index = 0

        func read() -> UInt8? {
            guard index < data.count else { return nil }
            let value = data[data.startIndex + index]
            index += 1
            return value
        }

        for line in 0..<height {
            let lineStart = index
            var x = 0
            var endedWithEOL = false
            while x < width {
                guard let first = read() else { return nil }
                if first != 0 {
                    pixels[line * width + x] = first
                    x += 1
                    continue
                }
                guard let flags = read() else { return nil }
                if flags == 0 {
                    endedWithEOL = true
                    break
                }
                var run = Int(flags & 0x3F)
                if flags & 0x40 != 0 {
                    guard let extra = read() else { return nil }
                    run = (run << 8) | Int(extra)
                }
                if run == 0 {
                    return nil
                }
                var color: UInt8 = 0
                if flags & 0x80 != 0 {
                    guard let value = read() else { return nil }
                    color = value
                }
                if x + run > width {
                    return nil
                }
                if color != 0 {
                    let row = line * width
                    for offset in 0..<run {
                        pixels[row + x + offset] = color
                    }
                }
                x += run
            }
            if x < width && !endedWithEOL {
                return nil
            }
            if !endedWithEOL {
                guard read() == 0, read() == 0 else { return nil }
            }
            if padOddLines && ((index - lineStart) % 2 == 1) {
                guard read() == 0 else { return nil }
            }
        }
        return Attempt(pixels: pixels, consumed: index)
    }
}
