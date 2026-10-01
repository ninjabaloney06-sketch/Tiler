import CoreGraphics
import Foundation
import Testing
@testable import TilerCore

/// Deterministic RNG so randomized tests are reproducible (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A named usable area for parameterized tests.
struct TestArea: Sendable, CustomTestStringConvertible {
    let name: String
    let area: UsableArea

    var testDescription: String { name }

    func with(gap: CGFloat, edges: Bool) -> UsableArea {
        UsableArea(rect: area.rect, scale: area.scale, gap: gap, gapAppliesToEdges: edges)
    }
}

enum Fixtures {
    /// This Mac: visibleFrame (0, 66, 1470, 856) in NSScreen space on a 956 pt tall screen →
    /// top-left space y = 956 − (66 + 856) = 34.
    static let laptop = UsableArea(rect: CGRect(x: 0, y: 34, width: 1470, height: 856), scale: 2)
    /// Same screen with the default 72 pt Stage Manager inset.
    static let laptopStageManager = UsableArea(rect: CGRect(x: 72, y: 34, width: 1398, height: 856), scale: 2)
    /// Synthetic 2560 × 1415 area at the origin.
    static let external = UsableArea(rect: CGRect(x: 0, y: 25, width: 2560, height: 1415), scale: 2)
    /// Same size as a secondary display right of and above the primary (negative y).
    static let externalOffset = UsableArea(rect: CGRect(x: 1470, y: -300, width: 2560, height: 1415), scale: 2)
    /// Non-Retina variant: edges must land on whole points.
    static let laptop1x = UsableArea(rect: CGRect(x: 0, y: 34, width: 1470, height: 856), scale: 1)

    static let areas: [TestArea] = [
        TestArea(name: "1470x856@2x", area: laptop),
        TestArea(name: "1398x856@2x (Stage Manager)", area: laptopStageManager),
        TestArea(name: "2560x1415@2x", area: external),
        TestArea(name: "2560x1415@2x offset", area: externalOffset),
        TestArea(name: "1470x856@1x", area: laptop1x),
    ]
}

func isOnPixelGrid(_ value: CGFloat, scale: CGFloat) -> Bool {
    let pixels = value * scale
    return pixels == pixels.rounded()
}

func isOnPixelGrid(_ rect: CGRect, scale: CGFloat) -> Bool {
    [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy { isOnPixelGrid($0, scale: scale) }
}

func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) * max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
}

/// Asserts that `frames` tile `rect` exactly: each frame lies inside `rect`, no two overlap, and
/// their areas sum to the area of `rect` (inside + disjoint + equal area ⇒ union == rect).
/// Coordinates are multiples of 1/2 or 1, so the float sums are exact.
func expectExactTiling(_ frames: [CGRect], of rect: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
    for frame in frames {
        #expect(rect.contains(frame), "\(frame) outside \(rect)", sourceLocation: sourceLocation)
        #expect(frame.width > 0 && frame.height > 0, "empty frame \(frame)", sourceLocation: sourceLocation)
    }
    for i in frames.indices {
        for j in frames.indices where j > i {
            #expect(overlapArea(frames[i], frames[j]) == 0,
                    "\(frames[i]) overlaps \(frames[j])", sourceLocation: sourceLocation)
        }
    }
    let total = frames.reduce(0) { $0 + $1.width * $1.height }
    #expect(total == rect.width * rect.height, "union area \(total) ≠ \(rect.width * rect.height)",
            sourceLocation: sourceLocation)
}

/// Exhaustive minimum of a rectangular assignment problem (min(rows, cols) pairs, each row and
/// column used at most once). Only for small matrices.
func bruteForceMinCost(_ cost: [[Double]]) -> Double {
    let rows = cost.count
    let columns = cost.first?.count ?? 0
    guard rows > 0, columns > 0 else { return 0 }
    if rows > columns {
        return bruteForceMinCost((0..<columns).map { c in (0..<rows).map { r in cost[r][c] } })
    }
    var best = Double.infinity
    var used = [Bool](repeating: false, count: columns)
    func search(_ row: Int, _ sum: Double) {
        if row == rows {
            best = min(best, sum)
            return
        }
        for column in 0..<columns where !used[column] {
            used[column] = true
            search(row + 1, sum + cost[row][column])
            used[column] = false
        }
    }
    search(0, 0)
    return best
}

/// A fresh directory inside the package (`<root>/.build-tests/<uuid>`, git-ignored) so tests
/// never write outside the project. The caller removes it.
func makeTestDirectory(filePath: String = #filePath) throws -> URL {
    let root = URL(fileURLWithPath: filePath)
        .deletingLastPathComponent() // TilerCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // package root
    let directory = root.appending(path: ".build-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Mutable box for values captured by @Sendable callbacks that run synchronously in the test.
final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
