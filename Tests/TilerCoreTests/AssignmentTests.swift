import CoreGraphics
import Testing
@testable import TilerCore

@Suite("Assignment")
struct AssignmentTests {
    // MARK: Solver

    @Test("Solver matches brute force on seeded random rectangular matrices up to 7x7")
    func solverMatchesBruteForce() {
        var rng = SplitMix64(seed: 0x71_1E_12_C1)
        for _ in 0..<400 {
            let rows = Int.random(in: 1...7, using: &rng)
            let columns = Int.random(in: 1...7, using: &rng)
            let integerCosts = Bool.random(using: &rng) // many ties
            let cost = (0..<rows).map { _ in
                (0..<columns).map { _ in
                    integerCosts ? Double(Int.random(in: 0...5, using: &rng)) : Double.random(in: 0..<1000, using: &rng)
                }
            }
            let result = Assignment.solve(cost)
            #expect(result.count == rows)
            let columnsUsed = result.compactMap { $0 }
            #expect(columnsUsed.count == min(rows, columns))
            #expect(Set(columnsUsed).count == columnsUsed.count)
            #expect(columnsUsed.allSatisfy { (0..<columns).contains($0) })
            let total = result.enumerated().reduce(0.0) { sum, entry in
                sum + (entry.element.map { cost[entry.offset][$0] } ?? 0)
            }
            let best = bruteForceMinCost(cost)
            #expect(abs(total - best) <= 1e-9 * max(1, best), "solver \(total) vs brute force \(best) for \(cost)")
        }
    }

    @Test("Solver beats greedy on a known trap")
    func solverBeatsGreedy() {
        // Greedy takes (0,0)=1 then must take (1,1)=100 → 101; optimum is 2 + 3 = 5.
        #expect(Assignment.solve([[1, 2], [3, 100]]) == [1, 0])
    }

    @Test("Solver handles empty input and single rows/columns")
    func solverEdgeCases() {
        #expect(Assignment.solve([]) == [])
        #expect(Assignment.solve([[], []]) == [nil, nil])
        #expect(Assignment.solve([[5, 1, 3]]) == [1])
        #expect(Assignment.solve([[5], [1], [3]]) == [nil, 0, nil])
    }

    // MARK: Cost

    @Test("Cost = center distance + 0.5 × (|Δw| + |Δh|)")
    func costFormula() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(Assignment.cost(window: window, slot: CGRect(x: 30, y: 40, width: 100, height: 100)) == 50)
        // Center moves by 50 in x; width differs by 100 → 50 + 0.5 · 100.
        #expect(Assignment.cost(window: window, slot: CGRect(x: 0, y: 0, width: 200, height: 100)) == 100)
    }

    // MARK: Arrange planning (SPEC §1 steps 2–4)

    static func randomFrame(in area: CGRect, using rng: inout SplitMix64) -> CGRect {
        let width = CGFloat.random(in: 200...area.width, using: &rng)
        let height = CGFloat.random(in: 150...area.height, using: &rng)
        return CGRect(
            x: area.minX + CGFloat.random(in: 0...(area.width - width), using: &rng),
            y: area.minY + CGFloat.random(in: 0...(area.height - height), using: &rng),
            width: width, height: height)
    }

    static let smallArrangePresets = PresetLibrary.arrange.filter { $0.slots.count <= 7 }.map(\.id)

    @Test("Arrange plan is optimal versus brute force (n ≤ 7, seeded)", arguments: smallArrangePresets)
    func planOptimalVersusBruteForce(presetID: String) throws {
        let preset = try #require(PresetLibrary.preset(id: presetID))
        let area = Fixtures.laptopStageManager
        let slots = area.slotFrames(for: preset)
        var rng = SplitMix64(seed: UInt64(slots.count) &* 0x5EED + UInt64(presetID.utf8.count))
        for _ in 0..<60 {
            let count = Int.random(in: 1...7, using: &rng)
            let frames = (0..<count).map { _ in Self.randomFrame(in: area.rect, using: &rng) }
            let hovered = Int.random(in: 0..<count, using: &rng)
            let order = [hovered] + frames.indices.filter { $0 != hovered }
            let kept = Array(order.prefix(slots.count))

            // With a target: the hovered window is pinned to the primary slot (SPEC §1 step 4),
            // the rest minimize Σ cost over the remaining slots.
            let plan = Assignment.planArrange(windowFrames: frames, hoveredIndex: hovered, preset: preset, area: area)
            #expect(plan.map(\.windowIndex) == kept)
            #expect(Set(plan.map(\.slotIndex)).count == plan.count)
            #expect(plan.allSatisfy { $0.frame == slots[$0.slotIndex] })
            #expect(plan.first?.slotIndex == 0)
            let rest = kept.dropFirst()
            let remainingSlots = Array(slots.indices.dropFirst())
            let restCosts = rest.map { window in
                remainingSlots.map { Assignment.cost(window: frames[window], slot: slots[$0]) }
            }
            let planRestTotal = plan.filter { $0.windowIndex != hovered }.reduce(0.0) {
                $0 + Assignment.cost(window: frames[$1.windowIndex], slot: $1.frame)
            }
            let bestRest = bruteForceMinCost(restCosts)
            #expect(abs(planRestTotal - bestRest) <= 1e-9 * max(1, bestRest),
                    "rest \(planRestTotal) vs brute force \(bestRest)")

            // Without a target: plain min-cost over all slots (SPEC §1 step 4, unchanged).
            let noTarget = Assignment.planArrange(windowFrames: frames, hoveredIndex: nil, preset: preset, area: area)
            let plainKept = Array(frames.indices.prefix(slots.count))
            #expect(noTarget.map(\.windowIndex) == plainKept)
            #expect(Set(noTarget.map(\.slotIndex)).count == noTarget.count)
            #expect(noTarget.allSatisfy { $0.frame == slots[$0.slotIndex] })
            let costs = plainKept.map { window in slots.map { Assignment.cost(window: frames[window], slot: $0) } }
            let noTargetTotal = noTarget.reduce(0.0) {
                $0 + Assignment.cost(window: frames[$1.windowIndex], slot: $1.frame)
            }
            let best = bruteForceMinCost(costs)
            #expect(abs(noTargetTotal - best) <= 1e-9 * max(1, best),
                    "plan \(noTargetTotal) vs brute force \(best)")
        }
    }

    @Test("More windows than slots: hovered + frontmost are kept, the rest untouched")
    func overflowKeepsHoveredAndFrontmost() {
        let preset = PresetLibrary.preset(id: "arrange-2x1")!
        let frames = (0..<6).map { CGRect(x: 100 + 50 * $0, y: 100, width: 600, height: 500) }

        let plan = Assignment.planArrange(windowFrames: frames, hoveredIndex: 4, preset: preset, area: Fixtures.laptop)
        #expect(plan.map(\.windowIndex) == [4, 0])
        #expect(plan.map(\.slotIndex) == [0, 1]) // hovered pinned to the primary slot

        let hoveredFront = Assignment.planArrange(windowFrames: frames, hoveredIndex: 0, preset: preset, area: Fixtures.laptop)
        #expect(hoveredFront.map(\.windowIndex) == [0, 1])
        #expect(hoveredFront.map(\.slotIndex) == [0, 1])

        let noHover = Assignment.planArrange(windowFrames: frames, hoveredIndex: nil, preset: preset, area: Fixtures.laptop)
        #expect(noHover.map(\.windowIndex) == [0, 1])

        // The pin is independent of position: window 5 sits at the right edge, where pure cost
        // would pair it with the right slot — as the hovered window it still takes slot 0.
        var farRight = frames
        farRight[5] = CGRect(x: 1200, y: 100, width: 600, height: 500)
        let slots = Fixtures.laptop.slotFrames(for: preset)
        #expect(Assignment.cost(window: farRight[5], slot: slots[1]) < Assignment.cost(window: farRight[5], slot: slots[0]))
        let pinned = Assignment.planArrange(windowFrames: farRight, hoveredIndex: 5, preset: preset, area: Fixtures.laptop)
        #expect(pinned.map(\.windowIndex) == [5, 0])
        #expect(pinned.map(\.slotIndex) == [0, 1])
    }

    @Test("Fewer windows than slots: hovered takes the primary slot, the rest their closest remaining slot")
    func fewerWindowsThanSlots() {
        let preset = PresetLibrary.preset(id: "arrange-2x2")!
        let area = Fixtures.laptop
        // Window 0 sits in the bottom-right quadrant, window 1 in the top-left one. Pure cost
        // would send window 0 to slot 3 — as the hovered window it takes the primary slot, and
        // window 1 goes to its closest remaining slot (bottom-left, nearest of slots 1–3).
        let frames = [
            CGRect(x: 800, y: 500, width: 600, height: 350),
            CGRect(x: 50, y: 60, width: 600, height: 350),
        ]
        let plan = Assignment.planArrange(windowFrames: frames, hoveredIndex: 0, preset: preset, area: area)
        #expect(plan.count == 2)
        #expect(plan.first { $0.windowIndex == 0 }?.slotIndex == 0)
        #expect(plan.first { $0.windowIndex == 1 }?.slotIndex == 2)

        let single = Assignment.planArrange(
            windowFrames: [CGRect(x: 1200, y: 40, width: 200, height: 150)], hoveredIndex: 0,
            preset: PresetLibrary.preset(id: "arrange-4x4")!, area: area)
        #expect(single.map(\.slotIndex) == [0]) // primary cell, not the nearest top-right one
    }

    @Test("Regression (1+3, ninja 1 Oct 2026): the hovered mid-size window takes the primary slot, the tall window fills a right row")
    func hoveredTakesPrimarySlot() {
        let preset = PresetLibrary.preset(id: "arrange-1+3")!
        let area = Fixtures.laptop
        let slots = area.slotFrames(for: preset)
        // The tall window fills the left column's neighbourhood, the hovered mid-size window
        // sits top-right. Pure cost would pair the hovered window with a small right slot
        // (≈ 123 pt vs ≈ 1094 pt to the primary slot); the rule pins it to slot 0 and the tall
        // window takes the cheapest remaining slot (the middle right row).
        let tall = CGRect(x: 0, y: 34, width: 700, height: 850)
        let hovered = CGRect(x: 750, y: 40, width: 600, height: 280)
        let plan = Assignment.planArrange(windowFrames: [tall, hovered], hoveredIndex: 1, preset: preset, area: area)
        #expect(Assignment.cost(window: hovered, slot: slots[1]) < Assignment.cost(window: hovered, slot: slots[0]))
        #expect(plan.map(\.windowIndex) == [1, 0])
        #expect(plan.map(\.slotIndex) == [0, 2])
        let restCosts = [slots.dropFirst().map { Assignment.cost(window: tall, slot: $0) }]
        #expect(bruteForceMinCost(restCosts) == Assignment.cost(window: tall, slot: slots[2]))
    }

    @Test("Windows already near distinct slots each keep their slot, whatever the z-order")
    func closestSlotAssignment() {
        let preset = PresetLibrary.preset(id: "arrange-3x2")!
        let area = Fixtures.laptop
        let slots = area.slotFrames(for: preset)
        // Window i sits on slot permutation[i], slightly off; the hovered window (index 2) is
        // the one near the primary slot, so the pin and the min-cost assignment agree.
        let permutation = [4, 1, 0, 5, 3, 2]
        let frames = permutation.map { slots[$0].insetBy(dx: 20, dy: 15).offsetBy(dx: 7, dy: -5) }
        let plan = Assignment.planArrange(windowFrames: frames, hoveredIndex: 2, preset: preset, area: area)
        #expect(plan.count == 6)
        for move in plan {
            #expect(move.slotIndex == permutation[move.windowIndex])
        }
    }

    @Test("Non-arrange presets and empty window lists produce no moves")
    func noMoves() {
        let frames = [CGRect(x: 0, y: 34, width: 500, height: 400)]
        #expect(Assignment.planArrange(windowFrames: frames, hoveredIndex: 0,
                                       preset: PresetLibrary.preset(id: "left-half")!, area: Fixtures.laptop).isEmpty)
        #expect(Assignment.planArrange(windowFrames: frames, hoveredIndex: 0,
                                       preset: PresetLibrary.preset(id: "center")!, area: Fixtures.laptop).isEmpty)
        #expect(Assignment.planArrange(windowFrames: [], hoveredIndex: nil,
                                       preset: PresetLibrary.preset(id: "arrange-2x2")!, area: Fixtures.laptop).isEmpty)
    }

    @Test("Arrange plan honours gaps: target frames are the gapped slot frames")
    func planUsesGappedSlots() {
        let preset = PresetLibrary.preset(id: "arrange-2x1")!
        let area = UsableArea(rect: Fixtures.laptop.rect, scale: 2, gap: 8, gapAppliesToEdges: true)
        let plan = Assignment.planArrange(
            windowFrames: [CGRect(x: 0, y: 34, width: 500, height: 500)], hoveredIndex: 0, preset: preset, area: area)
        #expect(plan.first?.frame == CGRect(x: 8, y: 42, width: 723, height: 840))
    }
}
