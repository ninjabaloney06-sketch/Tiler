/// A well in the palette editor grid. `row` 0 is the top row, `column` 0 the left column.
public struct WellPosition: Hashable, Sendable, Comparable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// True if the position lies inside the 11 × 6 editor grid.
    public var isValid: Bool {
        (0..<PaletteLayout.rows).contains(row) && (0..<PaletteLayout.columns).contains(column)
    }

    /// Row-major order.
    public static func < (a: WellPosition, b: WellPosition) -> Bool {
        (a.row, a.column) < (b.row, b.column)
    }
}

/// Inclusive bounding box of the occupied wells — the shape of the live palette.
public struct WellBox: Hashable, Sendable {
    public let minRow: Int
    public let maxRow: Int
    public let minColumn: Int
    public let maxColumn: Int

    public var rowCount: Int { maxRow - minRow + 1 }
    public var columnCount: Int { maxColumn - minColumn + 1 }
}

/// The Moom-style palette editor model (SPEC §2): an 11 × 6 grid of wells, each holding at most
/// one item id — a preset id or `revertID` — each item in at most one well. The live palette is the bounding box of the
/// occupied wells; empty wells inside the box render as blank space.
///
/// Operations mirror the editor's drag and drop (SPEC §5) and return whether anything changed.
public struct PaletteLayout: Hashable, Sendable {
    public static let columns = 11
    public static let rows = 6

    /// Occupied wells → item id (a preset id or `revertID`).
    public private(set) var wells: [WellPosition: String]

    /// The reserved well id of the Revert item (SPEC §3): placed, moved and removed like a
    /// preset, but not a `PresetLibrary` preset — it restores the frames from before the last move.
    public static let revertID = "revert"

    /// True for an id a well may hold: a library preset or `revertID`.
    public static func isPlaceable(_ id: String) -> Bool {
        id == revertID || PresetLibrary.preset(id: id) != nil
    }

    /// The display name of a placeable id (tooltips, editor labels); nil for an unknown id.
    public static func name(of id: String) -> String? {
        id == revertID ? "Revert" : PresetLibrary.preset(id: id)?.name
    }

    /// An empty layout.
    public init() {
        wells = [:]
    }

    /// Default placement: row 2, columns 3–7 = Fill, Left/Right/Top/Bottom half; row 3,
    /// columns 3–7 = 3x2, 3x3, 4x3, 4x4, 1+3. Every other preset starts in the library only.
    public static let `default`: PaletteLayout = {
        var layout = PaletteLayout()
        let rows: [(row: Int, ids: [String])] = [
            (2, ["fill", "left-half", "right-half", "top-half", "bottom-half"]),
            (3, ["arrange-3x2", "arrange-3x3", "arrange-4x3", "arrange-4x4", "arrange-1+3"]),
        ]
        for (row, ids) in rows {
            for (offset, id) in ids.enumerated() {
                layout.add(id, at: WellPosition(row: row, column: 3 + offset))
            }
        }
        return layout
    }()

    public func presetID(at position: WellPosition) -> String? {
        wells[position]
    }

    public func position(of presetID: String) -> WellPosition? {
        wells.first { $0.value == presetID }?.key
    }

    /// Library → well. The target must be a valid, empty well (or already hold this preset). If
    /// the preset sits in another well it moves here. Returns false and changes nothing otherwise.
    @discardableResult
    public mutating func add(_ presetID: String, at position: WellPosition) -> Bool {
        guard position.isValid else { return false }
        if wells[position] == presetID { return true }
        guard wells[position] == nil else { return false }
        if let old = self.position(of: presetID) {
            wells[old] = nil
        }
        wells[position] = presetID
        return true
    }

    /// Well → well. Moves the preset at `source` to `destination`; if `destination` is occupied
    /// the two presets swap. Returns false (no change) if `source` is empty or a position is
    /// outside the grid.
    @discardableResult
    public mutating func move(from source: WellPosition, to destination: WellPosition) -> Bool {
        guard source.isValid, destination.isValid, let moving = wells[source] else { return false }
        guard source != destination else { return true }
        let displaced = wells[destination]
        wells[destination] = moving
        wells[source] = displaced
        return true
    }

    /// Well → outside / library, or right-click → Remove. Returns the removed preset id.
    @discardableResult
    public mutating func remove(at position: WellPosition) -> String? {
        wells.removeValue(forKey: position)
    }

    /// Removes a preset wherever it sits. Returns the well it occupied.
    @discardableResult
    public mutating func remove(presetID: String) -> WellPosition? {
        guard let position = position(of: presetID) else { return nil }
        wells[position] = nil
        return position
    }

    /// Places Revert for a layout saved before it became a well item (SPEC §2 migration): in the
    /// well left of the palette's top-left well — where the fixed Revert column used to sit —
    /// else the first empty well in reading order. No-op if Revert is placed or the palette is
    /// empty.
    public mutating func placeRevertIfMissing() {
        guard position(of: Self.revertID) == nil, let box = boundingBox else { return }
        let left = WellPosition(row: box.minRow, column: box.minColumn - 1)
        if left.isValid, wells[left] == nil {
            wells[left] = Self.revertID
            return
        }
        for row in 0..<Self.rows {
            for column in 0..<Self.columns where wells[WellPosition(row: row, column: column)] == nil {
                wells[WellPosition(row: row, column: column)] = Self.revertID
                return
            }
        }
    }

    /// Bounding box of the occupied wells; nil when the palette is empty.
    public var boundingBox: WellBox? {
        guard !wells.isEmpty else { return nil }
        let positions = wells.keys
        return WellBox(
            minRow: positions.map(\.row).min()!,
            maxRow: positions.map(\.row).max()!,
            minColumn: positions.map(\.column).min()!,
            maxColumn: positions.map(\.column).max()!)
    }

    /// The live palette: the bounding box as rows of cells, top row first; nil = blank space.
    /// Empty when the palette is empty.
    public var paletteGrid: [[String?]] {
        guard let box = boundingBox else { return [] }
        return (box.minRow...box.maxRow).map { row in
            (box.minColumn...box.maxColumn).map { column in wells[WellPosition(row: row, column: column)] }
        }
    }

    // MARK: Keyboard navigation (SPEC §4.B)

    /// Occupied wells in reading order (row-major: top row first, left to right). Key n (1–9)
    /// applies `presetID(at: readingOrder[n - 1])`.
    public var readingOrder: [WellPosition] {
        wells.keys.sorted()
    }

    public enum Direction: Hashable, Sendable, CaseIterable {
        case left, right, up, down
    }

    /// The occupied well an arrow key moves the selection to, or nil at the edge (the selection
    /// stays; no wrapping). `position` need not be occupied.
    ///
    /// - ← →: the nearest occupied well in the same row, skipping blanks; nil past the row's
    ///   first / last well.
    /// - ↑ ↓: the nearest row in that direction that has an occupied well (blank rows skipped),
    ///   at its well closest in column; equal distance → the left one. nil in the top / bottom
    ///   occupied row.
    ///
    /// Rows are the palette's structure (reading order is row-major). This keeps every preset
    /// reachable from every other: ↑↓ visit every occupied row, ←→ every well within a row.
    public func neighbor(of position: WellPosition, direction: Direction) -> WellPosition? {
        let occupied = readingOrder
        let row: Int
        switch direction {
        case .left:
            return occupied.last { $0.row == position.row && $0.column < position.column }
        case .right:
            return occupied.first { $0.row == position.row && $0.column > position.column }
        case .up:
            guard let above = occupied.last(where: { $0.row < position.row })?.row else { return nil }
            row = above
        case .down:
            guard let below = occupied.first(where: { $0.row > position.row })?.row else { return nil }
            row = below
        }
        return occupied
            .filter { $0.row == row }
            .min { abs($0.column - position.column) < abs($1.column - position.column) }
    }
}

// MARK: Codable

/// Persisted as a row-major array of `{"id", "row", "column"}` objects. Decoding keeps the first
/// valid entry per well and per preset and drops entries that are malformed, outside the grid,
/// or name an id that is neither in `PresetLibrary` nor `revertID` (SPEC §2: unknown ids ignored).
extension PaletteLayout: Codable {
    private struct Entry: Encodable {
        let id: String
        let row: Int
        let column: Int
    }

    /// Never throws for an individual element, so one bad entry cannot sink the whole array.
    private struct LenientEntry: Decodable {
        let id: String?
        let row: Int?
        let column: Int?

        private enum CodingKeys: String, CodingKey { case id, row, column }

        init(from decoder: any Decoder) {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            id = (try? c?.decode(String.self, forKey: .id)) ?? nil
            row = (try? c?.decode(Int.self, forKey: .row)) ?? nil
            column = (try? c?.decode(Int.self, forKey: .column)) ?? nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let entries = try decoder.singleValueContainer().decode([LenientEntry].self)
        self.init()
        for entry in entries {
            guard let id = entry.id, let row = entry.row, let column = entry.column,
                  Self.isPlaceable(id) else { continue }
            let position = WellPosition(row: row, column: column)
            guard position.isValid, wells[position] == nil, self.position(of: id) == nil else { continue }
            wells[position] = id
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wells.sorted { $0.key < $1.key }.map {
            Entry(id: $0.value, row: $0.key.row, column: $0.key.column)
        })
    }
}
