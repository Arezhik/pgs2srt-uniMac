import CZLib
import Foundation

/// zlib inflate and deflate. Matroska subtitle tracks use a zlib wrapper, not raw deflate.
enum Zlib {
    static func inflate(_ input: Data) throws -> Data {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let opened = inflateInit2_(&stream, 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard opened == Z_OK else { throw MKVReadError.compressed }
        defer { inflateEnd(&stream) }
        return try pump(input, stream: &stream) { stream in
            CZLib.inflate(&stream, Z_NO_FLUSH)
        }
    }

    static func deflate(_ input: Data) throws -> Data {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let opened = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard opened == Z_OK else { throw MKVReadError.compressed }
        defer { deflateEnd(&stream) }
        return try pump(input, stream: &stream) { stream in
            CZLib.deflate(&stream, Z_FINISH)
        }
    }

    private static func pump(
        _ input: Data,
        stream: inout z_stream,
        step: (inout z_stream) -> Int32
    ) throws -> Data {
        let chunk = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        try input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw MKVReadError.compressed
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            var status = Z_OK
            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(chunk)
                status = step(&stream)
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw MKVReadError.compressed
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
            } while status != Z_STREAM_END
        }
        return output
    }
}
