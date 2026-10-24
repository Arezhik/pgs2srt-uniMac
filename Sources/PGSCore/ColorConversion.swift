import Foundation

struct YCbCrColor: Equatable {
    var y: UInt8
    var cr: UInt8
    var cb: UInt8
    var a: UInt8
}

/// Limited-range YCbCr (studio swing) to straight RGBA.
///
/// Coefficients match the conversion used by BDSup2Sub and SubtitleEdit, including
/// the small bias that keeps reference white (Y=235) on 255.
enum ColorConversion {
    static func rgba(_ color: YCbCrColor, matrix: ColorMatrix) -> RGBA {
        let y = Double(Int(color.y) - 16)
        let cb = Double(Int(color.cb) - 128)
        let cr = Double(Int(color.cr) - 128)
        let y1 = y * 1.164383562

        let r: Double
        let g: Double
        let b: Double
        switch matrix {
        case .bt601:
            r = y1 + 1.596026317 * cr
            g = y1 - 0.8129674985 * cr - 0.3917615979 * cb
            b = y1 + 2.017232218 * cb
        case .bt709:
            r = y1 + 1.792741071 * cr
            g = y1 - 0.5329093286 * cr - 0.2132486143 * cb
            b = y1 + 2.112401786 * cb
        }
        return RGBA(r: quantize(r), g: quantize(g), b: quantize(b), a: color.a)
    }

    static func quantize(_ value: Double) -> UInt8 {
        var adjusted = value
        if adjusted > 254.0 {
            adjusted += 0.35
        }
        let rounded: Int
        if adjusted >= 0 {
            rounded = Int(adjusted + 0.5)
        } else {
            rounded = Int(adjusted - 0.5)
        }
        if rounded < 0 { return 0 }
        if rounded > 255 { return 255 }
        return UInt8(rounded)
    }
}
