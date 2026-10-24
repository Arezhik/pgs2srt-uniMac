import Foundation

/// Puts recognized pieces into reading order: rows from top to bottom, and
/// left to right inside a row. Two pieces are the same row when their vertical
/// ranges overlap by at least half the shorter piece.
public enum ReadingOrder {
    public static func rows(from lines: [RecognizedLine]) -> [[RecognizedLine]] {
        let sorted = lines.sorted { lhs, rhs in
            if lhs.top != rhs.top { return lhs.top < rhs.top }
            if lhs.left != rhs.left { return lhs.left < rhs.left }
            return lhs.text < rhs.text
        }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let index = rows.indices.last, overlaps(line, row: rows[index]) {
                rows[index].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            row.sorted { lhs, rhs in
                if lhs.left != rhs.left { return lhs.left < rhs.left }
                return lhs.top < rhs.top
            }
        }
    }

    private static func overlaps(_ line: RecognizedLine, row: [RecognizedLine]) -> Bool {
        let lineHeight = max(line.height, 1)
        let lineBottom = line.top + lineHeight
        for other in row {
            let otherHeight = max(other.height, 1)
            let overlap = min(lineBottom, other.top + otherHeight) - max(line.top, other.top)
            if overlap > 0 && overlap * 2 >= min(lineHeight, otherHeight) {
                return true
            }
        }
        return false
    }
}
