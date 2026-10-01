/// A rectangle in the unit space of a usable area: both axes run 0…1, the origin is the usable
/// area's TOP-LEFT corner and y grows downward (the orientation `Geometry` works in).
///
/// Stored as its four edges rather than origin + size, so two rects that share an edge hold the
/// bit-identical `Double` for it (no `x + width` round-off). `Geometry` rounds every edge on its
/// own, so identical edge values guarantee that neighbouring tiles meet exactly.
public struct UnitRect: Hashable, Sendable, Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// The whole usable area.
    public static let full = UnitRect(minX: 0, minY: 0, maxX: 1, maxY: 1)

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    /// True if the rect has a positive area and lies inside 0…1 on both axes.
    public var isValid: Bool {
        0 <= minX && minX < maxX && maxX <= 1 && 0 <= minY && minY < maxY && maxY <= 1
    }

    /// The cells of a `columns` × `rows` grid laid over this rect, row-major from the top-left.
    public func grid(columns: Int, rows: Int) -> [UnitRect] {
        precondition(columns > 0 && rows > 0, "grid needs at least one column and one row")
        let xs = Self.split(minX, maxX, into: columns)
        let ys = Self.split(minY, maxY, into: rows)
        var cells: [UnitRect] = []
        cells.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                cells.append(UnitRect(minX: xs[column], minY: ys[row], maxX: xs[column + 1], maxY: ys[row + 1]))
            }
        }
        return cells
    }

    /// `n + 1` evenly spaced edges from `a` to `b`. The end points are exactly `a` and `b`;
    /// interior edges are `a + (b − a) · i / n`, so the same fraction always yields the same
    /// `Double` (IEEE division is correctly rounded, so e.g. 2/6 == 1/3 bit for bit).
    static func split(_ a: Double, _ b: Double, into n: Int) -> [Double] {
        (0...n).map { i in
            i == 0 ? a : i == n ? b : a + (b - a) * Double(i) / Double(n)
        }
    }
}
