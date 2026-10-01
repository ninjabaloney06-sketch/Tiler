import Foundation
import Testing
@testable import TilerCore

@Suite("PaletteLayout")
struct PaletteLayoutTests {
    func well(_ row: Int, _ column: Int) -> WellPosition {
        WellPosition(row: row, column: column)
    }

    @Test("Default placement per SPEC §2")
    func defaultPlacement() {
        let layout = PaletteLayout.default
        let row2 = ["fill", "left-half", "right-half", "top-half", "bottom-half"]
        let row3 = ["arrange-3x2", "arrange-3x3", "arrange-4x3", "arrange-4x4", "arrange-1+3"]
        for (offset, id) in row2.enumerated() {
            #expect(layout.presetID(at: well(2, 3 + offset)) == id)
        }
        for (offset, id) in row3.enumerated() {
            #expect(layout.presetID(at: well(3, 3 + offset)) == id)
        }
        #expect(layout.wells.count == 10)
        #expect(layout.boundingBox == WellBox(minRow: 2, maxRow: 3, minColumn: 3, maxColumn: 7))
        #expect(layout.paletteGrid == [row2, row3])
    }

    @Test("Grid is 11 columns × 6 rows")
    func gridSize() {
        #expect(PaletteLayout.columns == 11)
        #expect(PaletteLayout.rows == 6)
        #expect(well(5, 10).isValid)
        #expect(!well(6, 0).isValid)
        #expect(!well(0, 11).isValid)
        #expect(!well(-1, 0).isValid)
    }

    @Test("Library → empty well adds; occupied or out-of-grid wells refuse")
    func addToWell() {
        var layout = PaletteLayout()
        do { let result = layout.add("center", at: well(0, 0)); #expect(result) }
        #expect(layout.presetID(at: well(0, 0)) == "center")
        do { let result = layout.add("fill", at: well(0, 0)); #expect(!result) }
        #expect(layout.presetID(at: well(0, 0)) == "center")
        do { let result = layout.add("fill", at: well(6, 0)); #expect(!result) }
        do { let result = layout.add("center", at: well(0, 0)); #expect(result) } // already there: no-op
        #expect(layout.wells.count == 1)
    }

    @Test("Adding a preset that is already placed moves it (one well per preset)")
    func addMovesExistingPreset() {
        var layout = PaletteLayout.default
        do { let result = layout.add("fill", at: well(0, 0)); #expect(result) }
        #expect(layout.position(of: "fill") == well(0, 0))
        #expect(layout.presetID(at: well(2, 3)) == nil)
        #expect(layout.wells.count == 10)
    }

    @Test("Well → empty well moves")
    func moveToEmptyWell() {
        var layout = PaletteLayout.default
        do { let result = layout.move(from: well(2, 3), to: well(5, 10)); #expect(result) }
        #expect(layout.presetID(at: well(5, 10)) == "fill")
        #expect(layout.presetID(at: well(2, 3)) == nil)
        #expect(layout.boundingBox == WellBox(minRow: 2, maxRow: 5, minColumn: 3, maxColumn: 10))
    }

    @Test("Well → occupied well swaps")
    func moveSwaps() {
        var layout = PaletteLayout.default
        do { let result = layout.move(from: well(2, 3), to: well(3, 7)); #expect(result) }
        #expect(layout.presetID(at: well(3, 7)) == "fill")
        #expect(layout.presetID(at: well(2, 3)) == "arrange-1+3")
        #expect(layout.wells.count == 10)
    }

    @Test("Moving from an empty or invalid well changes nothing")
    func moveRejects() {
        var layout = PaletteLayout.default
        do { let result = layout.move(from: well(0, 0), to: well(1, 1)); #expect(!result) }
        do { let result = layout.move(from: well(2, 3), to: well(9, 9)); #expect(!result) }
        do { let result = layout.move(from: well(2, 3), to: well(2, 3)); #expect(result) }
        #expect(layout == PaletteLayout.default)
    }

    @Test("Remove by well and by preset id")
    func remove() {
        var layout = PaletteLayout.default
        do { let result = layout.remove(at: well(2, 3)); #expect(result == "fill") }
        do { let result = layout.remove(at: well(2, 3)); #expect(result == nil) }
        do { let result = layout.remove(presetID: "arrange-1+3"); #expect(result == well(3, 7)) }
        do { let result = layout.remove(presetID: "arrange-1+3"); #expect(result == nil) }
        #expect(layout.wells.count == 8)
        #expect(layout.boundingBox == WellBox(minRow: 2, maxRow: 3, minColumn: 3, maxColumn: 7))
    }

    @Test("Bounding box includes blank wells inside it; empty palette has none")
    func boundingBoxWithBlanks() {
        var layout = PaletteLayout()
        #expect(layout.boundingBox == nil)
        #expect(layout.paletteGrid.isEmpty)
        layout.add("fill", at: well(1, 2))
        layout.add("center", at: well(3, 5))
        let box = layout.boundingBox
        #expect(box == WellBox(minRow: 1, maxRow: 3, minColumn: 2, maxColumn: 5))
        #expect(box?.rowCount == 3)
        #expect(box?.columnCount == 4)
        #expect(layout.paletteGrid == [
            ["fill", nil, nil, nil],
            [nil, nil, nil, nil],
            [nil, nil, nil, "center"],
        ])
    }

    @Test("JSON round-trip; decoding drops unknown ids, out-of-grid wells, duplicates and malformed entries")
    func codable() throws {
        let data = try JSONEncoder().encode(PaletteLayout.default)
        #expect(try JSONDecoder().decode(PaletteLayout.self, from: data) == PaletteLayout.default)

        let json = """
        [
          {"id": "fill", "row": 0, "column": 0},
          {"id": "no-such-preset", "row": 0, "column": 1},
          {"id": "center", "row": 6, "column": 0},
          {"id": "left-half", "row": 0, "column": 0},
          {"id": "fill", "row": 1, "column": 1},
          {"id": "right-half", "row": "x", "column": 2},
          42,
          {"id": "top-half", "row": 1, "column": 2}
        ]
        """
        let decoded = try JSONDecoder().decode(PaletteLayout.self, from: Data(json.utf8))
        #expect(decoded.wells == [well(0, 0): "fill", well(1, 2): "top-half"])
    }

    // MARK: Keyboard navigation (SPEC §4.B)

    /// Builds a layout from rows of strings, "." = blank well, anything else = a preset id taken
    /// from `ids` in order (so the ids are real library ids).
    func layout(_ rows: [String], origin: WellPosition = WellPosition(row: 0, column: 0)) -> PaletteLayout {
        let ids = PresetLibrary.all.map(\.id)
        var next = 0
        var layout = PaletteLayout()
        for (r, line) in rows.enumerated() {
            for (c, char) in line.enumerated() where char != "." {
                let added = layout.add(ids[next], at: well(origin.row + r, origin.column + c))
                precondition(added)
                next += 1
            }
        }
        return layout
    }

    @Test("Reading order is row-major over the occupied wells; keys 1–9 map to its first nine")
    func readingOrder() {
        let order = PaletteLayout.default.readingOrder
        #expect(order == (3...7).map { well(2, $0) } + (3...7).map { well(3, $0) })
        let digitIDs = order.prefix(9).compactMap { PaletteLayout.default.presetID(at: $0) }
        #expect(digitIDs == ["fill", "left-half", "right-half", "top-half", "bottom-half",
                             "arrange-3x2", "arrange-3x3", "arrange-4x3", "arrange-4x4"])
        #expect(PaletteLayout().readingOrder.isEmpty)

        var scattered = PaletteLayout()
        scattered.add("center", at: well(4, 0))
        scattered.add("fill", at: well(1, 9))
        scattered.add("left-half", at: well(1, 2))
        scattered.add("right-half", at: well(4, 10))
        #expect(scattered.readingOrder == [well(1, 2), well(1, 9), well(4, 0), well(4, 10)])
    }

    @Test("Full rectangle (default palette): arrows step to the adjacent well and stop at the edges")
    func navigationFullRectangle() {
        let layout = PaletteLayout.default
        for position in layout.readingOrder {
            let expected: [PaletteLayout.Direction: WellPosition] = [
                .left: well(position.row, position.column - 1),
                .right: well(position.row, position.column + 1),
                .up: well(position.row - 1, position.column),
                .down: well(position.row + 1, position.column),
            ]
            for (direction, target) in expected {
                let wanted: WellPosition? = layout.presetID(at: target) == nil ? nil : target
                #expect(layout.neighbor(of: position, direction: direction) == wanted, "\(position) \(direction)")
            }
        }
        #expect(layout.neighbor(of: well(2, 7), direction: .right) == nil)
        #expect(layout.neighbor(of: well(2, 3), direction: .left) == nil)
        #expect(layout.neighbor(of: well(2, 5), direction: .up) == nil)
        #expect(layout.neighbor(of: well(3, 5), direction: .down) == nil)
    }

    @Test("Blank wells are skipped within a row and blank rows between rows")
    func navigationSkipsBlanks() {
        let l = layout([
            "A..B",
            "....",
            "C..D",
        ])
        #expect(l.neighbor(of: well(0, 0), direction: .right) == well(0, 3))
        #expect(l.neighbor(of: well(0, 3), direction: .left) == well(0, 0))
        #expect(l.neighbor(of: well(0, 0), direction: .down) == well(2, 0))
        #expect(l.neighbor(of: well(2, 3), direction: .up) == well(0, 3))
        // Edges: stop.
        #expect(l.neighbor(of: well(0, 3), direction: .right) == nil)
        #expect(l.neighbor(of: well(2, 3), direction: .down) == nil)
        #expect(l.neighbor(of: well(0, 0), direction: .up) == nil)
        #expect(l.neighbor(of: well(2, 0), direction: .left) == nil)
    }

    @Test("← → stay in the row and stop at its ends, even when other rows reach further")
    func navigationHorizontalStaysInRow() {
        let l = layout([
            "A.C",
            ".B.",
            "D...E",
        ])
        #expect(l.neighbor(of: well(0, 0), direction: .right) == well(0, 2)) // C, not the nearer B
        #expect(l.neighbor(of: well(0, 2), direction: .right) == nil)        // E lies further right, other row
        #expect(l.neighbor(of: well(1, 1), direction: .right) == nil)
        #expect(l.neighbor(of: well(1, 1), direction: .left) == nil)
        #expect(l.neighbor(of: well(2, 4), direction: .left) == well(2, 0))
    }

    @Test("↑ ↓ go to the next occupied row (blank rows skipped), at the closest column")
    func navigationVerticalNextRow() {
        let l = layout([
            "A....",
            "...B.",
            ".....",
            ".....",
            "C..D.",
        ])
        #expect(l.neighbor(of: well(0, 0), direction: .down) == well(1, 3)) // next row, not C further down
        #expect(l.neighbor(of: well(1, 3), direction: .down) == well(4, 3)) // two blank rows skipped
        #expect(l.neighbor(of: well(4, 0), direction: .up) == well(1, 3))   // B is the only well in row 1
        #expect(l.neighbor(of: well(1, 3), direction: .up) == well(0, 0))
        #expect(l.neighbor(of: well(0, 0), direction: .up) == nil)
        #expect(l.neighbor(of: well(4, 3), direction: .down) == nil)
        #expect(l.neighbor(of: well(4, 1), direction: .up) == well(1, 3))   // from a blank well
    }

    @Test("Equal column distance above/below goes to the left well")
    func navigationTieBreak() {
        let l = layout([
            "B.C",
            ".A.",
            "D.E",
        ])
        #expect(l.neighbor(of: well(1, 1), direction: .up) == well(0, 0))
        #expect(l.neighbor(of: well(1, 1), direction: .down) == well(2, 0))
    }

    @Test("Empty palette and positions that are not occupied")
    func navigationFromAnywhere() {
        for direction in PaletteLayout.Direction.allCases {
            #expect(PaletteLayout().neighbor(of: well(2, 3), direction: direction) == nil)
        }
        let l = layout(["A.B"], origin: well(1, 1))
        #expect(l.neighbor(of: well(1, 2), direction: .right) == well(1, 3))
        #expect(l.neighbor(of: well(1, 2), direction: .left) == well(1, 1))
        #expect(l.neighbor(of: well(0, 0), direction: .down) == well(1, 1))
    }

    @Test("Random layouts: results obey the row rules, nil only at the edge, every well reachable from every other")
    func navigationProperties() {
        var rng = SplitMix64(seed: 0x7117E4)
        let ids = PresetLibrary.all.map(\.id)
        let allWells = (0..<PaletteLayout.rows).flatMap { r in (0..<PaletteLayout.columns).map { well(r, $0) } }
        for _ in 0..<200 {
            var l = PaletteLayout()
            let count = Int.random(in: 1...24, using: &rng)
            for (id, position) in zip(ids.shuffled(using: &rng), allWells.shuffled(using: &rng).prefix(count)) {
                l.add(id, at: position)
            }
            let occupied = l.readingOrder
            for p in allWells {
                // ← →: nearest in the same row.
                let left = occupied.filter { $0.row == p.row && $0.column < p.column }
                let right = occupied.filter { $0.row == p.row && $0.column > p.column }
                #expect(l.neighbor(of: p, direction: .left) == left.max())
                #expect(l.neighbor(of: p, direction: .right) == right.min())
                // ↑ ↓: in the nearest occupied row, closest column, left one on a tie.
                let above = occupied.map(\.row).filter { $0 < p.row }.max()
                let below = occupied.map(\.row).filter { $0 > p.row }.min()
                for (direction, nearestRow) in [(PaletteLayout.Direction.up, above), (.down, below)] {
                    let result = l.neighbor(of: p, direction: direction)
                    guard let row = nearestRow else {
                        #expect(result == nil)
                        continue
                    }
                    guard let target = result else {
                        Issue.record("no \(direction) neighbor of \(p) in \(occupied)")
                        continue
                    }
                    let distance = abs(target.column - p.column)
                    #expect(target.row == row && l.presetID(at: target) != nil)
                    #expect(!occupied.contains {
                        $0.row == row && (abs($0.column - p.column), $0.column) < (distance, target.column)
                    })
                }
            }
            // Every occupied well can reach every other one with the arrow keys.
            for start in occupied {
                var seen: Set<WellPosition> = [start]
                var queue = [start]
                while let current = queue.popLast() {
                    for direction in PaletteLayout.Direction.allCases {
                        if let next = l.neighbor(of: current, direction: direction), seen.insert(next).inserted {
                            queue.append(next)
                        }
                    }
                }
                #expect(seen.count == occupied.count, "unreachable wells from \(start) in \(occupied)")
            }
        }
    }
}
