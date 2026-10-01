import CoreGraphics

/// One window move produced by `Assignment.planArrange`.
public struct ArrangeMove: Equatable, Sendable {
    /// Index into the `windowFrames` array passed to `planArrange`.
    public let windowIndex: Int
    /// Index into the preset's slots.
    public let slotIndex: Int
    /// Target frame in points, top-left space (see `Geometry`).
    public let frame: CGRect
}

/// Optimal window ↔ slot assignment for arrange presets (SPEC §1 "Arrange algorithm").
public enum Assignment {
    /// SPEC §1 step 4 cost, in points: distance between the centers + 0.5 × (|Δwidth| + |Δheight|).
    public static func cost(window: CGRect, slot: CGRect) -> Double {
        let dx = Double(window.midX - slot.midX)
        let dy = Double(window.midY - slot.midY)
        let dw = Double(abs(window.width - slot.width))
        let dh = Double(abs(window.height - slot.height))
        return (dx * dx + dy * dy).squareRoot() + 0.5 * (dw + dh)
    }

    /// Plans an arrange preset (SPEC §1 steps 2–4).
    ///
    /// - Parameters:
    ///   - windowFrames: candidate windows (step 1 is the caller's job) in front-to-back
    ///     CGWindowList z-order, top-left space.
    ///   - hoveredIndex: index of the hovered window in `windowFrames`; it is moved to the
    ///     front of the order. Nil or out of range keeps the given order.
    ///   - preset: an `.arrange` preset; any other kind yields no moves.
    ///   - area: the usable area of the hovered window's screen.
    /// - Returns: one move per kept window, in kept order (hovered first). With more windows than
    ///   slots only the first `slots.count` windows (most recently used) are kept; the others do
    ///   not appear and stay untouched. With fewer windows, the extra slots stay empty. The
    ///   window ↔ slot pairing minimizes the summed `cost`.
    public static func planArrange(
        windowFrames: [CGRect], hoveredIndex: Int?, preset: Preset, area: UsableArea
    ) -> [ArrangeMove] {
        let slotFrames = area.slotFrames(for: preset)
        guard !slotFrames.isEmpty, !windowFrames.isEmpty else { return [] }

        // Step 2: front-to-back, hovered window first.
        var order = Array(windowFrames.indices)
        if let hovered = hoveredIndex, windowFrames.indices.contains(hovered) {
            order.remove(at: hovered)
            order.insert(hovered, at: 0)
        }
        // Step 3: keep the most recently used windows, at most one per slot.
        let kept = Array(order.prefix(slotFrames.count))
        // Step 4: optimal assignment.
        let costs = kept.map { window in
            slotFrames.map { slot in cost(window: windowFrames[window], slot: slot) }
        }
        let slotForKept = solve(costs)
        return kept.enumerated().compactMap { position, window in
            slotForKept[position].map { slot in
                ArrangeMove(windowIndex: window, slotIndex: slot, frame: slotFrames[slot])
            }
        }
    }

    /// Minimum-cost assignment on a rectangular cost matrix (Hungarian algorithm with
    /// potentials, O(n² · m) for n ≤ m; a taller matrix is solved transposed).
    ///
    /// - Parameter cost: `cost[row][column]`; every row has the same length; all values finite.
    /// - Returns: the assigned column for each row, or nil. Exactly `min(rows, columns)` rows are
    ///   assigned, every column at most once, and the summed cost is minimal.
    public static func solve(_ cost: [[Double]]) -> [Int?] {
        let rows = cost.count
        let columns = cost.first?.count ?? 0
        precondition(cost.allSatisfy { $0.count == columns }, "cost matrix rows differ in length")
        precondition(cost.allSatisfy { $0.allSatisfy(\.isFinite) }, "cost matrix has non-finite values")
        guard rows > 0, columns > 0 else { return Array(repeating: nil, count: rows) }

        if rows <= columns {
            return hungarian(cost).map { Optional($0) }
        }
        let transposed = (0..<columns).map { column in (0..<rows).map { row in cost[row][column] } }
        var result = [Int?](repeating: nil, count: rows)
        for (column, row) in hungarian(transposed).enumerated() {
            result[row] = column
        }
        return result
    }

    /// Kuhn–Munkres with row/column potentials (shortest augmenting paths). Requires
    /// `a.count <= a[0].count`; returns the column of every row. Indices are 1-based internally,
    /// index 0 is the virtual source column.
    private static func hungarian(_ a: [[Double]]) -> [Int] {
        let n = a.count
        let m = a[0].count
        var u = [Double](repeating: 0, count: n + 1)   // row potentials
        var v = [Double](repeating: 0, count: m + 1)   // column potentials
        var rowOf = [Int](repeating: 0, count: m + 1)  // column → matched row (0 = free)
        var way = [Int](repeating: 0, count: m + 1)    // previous column on the augmenting path

        for i in 1...n {
            rowOf[0] = i
            var j0 = 0
            var minSlack = [Double](repeating: .infinity, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[j0] = true
                let i0 = rowOf[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...m where !used[j] {
                    let reduced = a[i0 - 1][j - 1] - u[i0] - v[j]
                    if reduced < minSlack[j] {
                        minSlack[j] = reduced
                        way[j] = j0
                    }
                    if minSlack[j] < delta {
                        delta = minSlack[j]
                        j1 = j
                    }
                }
                for j in 0...m {
                    if used[j] {
                        u[rowOf[j]] += delta
                        v[j] -= delta
                    } else {
                        minSlack[j] -= delta
                    }
                }
                j0 = j1
            } while rowOf[j0] != 0
            // Augment along the path back to the source.
            repeat {
                let previous = way[j0]
                rowOf[j0] = rowOf[previous]
                j0 = previous
            } while j0 != 0
        }

        var columnOf = [Int](repeating: -1, count: n)
        for j in 1...m where rowOf[j] != 0 {
            columnOf[rowOf[j] - 1] = j - 1
        }
        return columnOf
    }
}
