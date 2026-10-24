import Foundation

extension SubtitleImage {
    /// Netpbm PAM (P7) with `TUPLTYPE RGB_ALPHA`. Viewers such as `ffplay` and ImageMagick can open it.
    public func pamData() -> Data {
        // The line break before a closing """ is not part of the string, so the
        // header is built with explicit newlines. The byte after ENDHDR must be
        // a newline or the first pixel is glued to the header.
        let header = "P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"
        var data = Data(header.utf8)
        data.append(contentsOf: rgba)
        return data
    }
}
