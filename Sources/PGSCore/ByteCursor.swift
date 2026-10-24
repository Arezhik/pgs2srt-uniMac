import Foundation

struct ByteCursor {
    private let data: Data
    private var index: Int
    /// File offset of `data[0]`, so errors point at the original .sup file.
    let baseOffset: Int

    var remaining: Int { data.count - index }
    var fileOffset: Int { baseOffset + index }
    var isEmpty: Bool { index >= data.count }

    init(data: Data, baseOffset: Int = 0) {
        self.data = data
        self.index = 0
        self.baseOffset = baseOffset
    }

    mutating func readUInt8(_ context: String) throws -> UInt8 {
        guard index < data.count else {
            throw PGSError.truncated(offset: fileOffset, context: context)
        }
        let value = data[data.startIndex + index]
        index += 1
        return value
    }

    mutating func readUInt16(_ context: String) throws -> UInt16 {
        let high = try readUInt8(context)
        let low = try readUInt8(context)
        return (UInt16(high) << 8) | UInt16(low)
    }

    mutating func readUInt24(_ context: String) throws -> Int {
        let b0 = try readUInt8(context)
        let b1 = try readUInt8(context)
        let b2 = try readUInt8(context)
        return (Int(b0) << 16) | (Int(b1) << 8) | Int(b2)
    }

    mutating func readUInt32(_ context: String) throws -> UInt32 {
        let b0 = UInt32(try readUInt8(context))
        let b1 = UInt32(try readUInt8(context))
        let b2 = UInt32(try readUInt8(context))
        let b3 = UInt32(try readUInt8(context))
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    mutating func readData(_ count: Int, _ context: String) throws -> Data {
        guard count >= 0, index + count <= data.count else {
            throw PGSError.truncated(offset: fileOffset, context: context)
        }
        let start = data.startIndex + index
        let slice = data.subdata(in: start..<(start + count))
        index += count
        return slice
    }
}
