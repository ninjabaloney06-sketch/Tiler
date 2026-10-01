import AppKit
import ApplicationServices
import TilerCore

/// Sets one window's frame through AX (SPEC §3). All frames are in AX space.
///
/// Sequence: `AXEnhancedUserInterface` off on the app element (if it was on) → size → position
/// → size → read back. If any edge is off by more than 1 pt (min-size / fixed-aspect / fixed-size
/// windows), the window keeps the size the app allowed and is re-aligned with `alignedFrame`,
/// then read back again. Enhanced UI is restored afterwards except for Chromium-family apps
/// (Rectangle's "automatic" policy). Windows whose size is not settable are only moved.
public enum FrameSetter {
    /// Which edges of a target lie on the usable area's border. Drives the re-align rule.
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let left = Edges(rawValue: 1 << 0)
        public static let right = Edges(rawValue: 1 << 1)
        public static let top = Edges(rawValue: 1 << 2)
        public static let bottom = Edges(rawValue: 1 << 3)

        /// Edges a unit rect shares with the usable area (unit 0 or 1). Gaps do not change this.
        public static func shared(by unit: UnitRect) -> Edges {
            var edges: Edges = []
            if unit.minX <= 0 { edges.insert(.left) }
            if unit.maxX >= 1 { edges.insert(.right) }
            if unit.minY <= 0 { edges.insert(.top) }
            if unit.maxY >= 1 { edges.insert(.bottom) }
            return edges
        }
    }

    public struct Result {
        /// The requested frame.
        public let target: CGRect
        /// The frame read back after all steps; nil if the window did not answer.
        public let final: CGRect?
        /// False for fixed-size windows (moved only).
        public let sizeSettable: Bool
        /// True if the re-align pass ran (the app refused the requested frame).
        public let realigned: Bool
    }

    /// Differences up to this many points count as "landed" (macOS shortens a size change onto
    /// the Dock edge by 1 pt; Rectangle ignores that too).
    public static let tolerance: CGFloat = 1

    /// Chromium-family bundle id prefixes (Rectangle `EnhancedUI.automatic`): Enhanced UI is not
    /// switched back on for these after a move.
    static let chromiumFamilies = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaNext",
        "com.operasoftware.OperaDeveloper", "com.operasoftware.OperaNightly", "com.operasoftware.OperaGX",
        "com.operasoftware.OperaGXNext", "com.operasoftware.OperaGXDeveloper",
        "com.operasoftware.OperaGXNightly", "company.thebrowser.Browser", "company.thebrowser.dia",
        "ai.perplexity.comet", "com.openai.atlas",
    ]

    public static func isChromiumFamily(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromiumFamilies.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// The re-align rule for a window of `size` that could not take the size of `target`:
    ///
    /// Per axis, and only if that axis differs from the target by more than `tolerance`: if the
    /// target touches exactly one of the two usable-area edges on that axis, the window is
    /// anchored to that edge; otherwise (both or neither) it is centered in the target, origin
    /// snapped to the pixel grid. An axis within tolerance keeps the target's origin. Finally,
    /// if `bounds` is given, the frame is nudged inside it (right/bottom first, then left/top,
    /// so a window larger than the bounds sticks to the left/top edge).
    public static func alignedFrame(
        size: CGSize, in target: CGRect, sharedEdges: Edges, bounds: CGRect?, scale: CGFloat
    ) -> CGRect {
        func axis(_ length: CGFloat, targetMin: CGFloat, targetLength: CGFloat,
                  leading: Bool, trailing: Bool) -> CGFloat {
            guard abs(length - targetLength) > tolerance else { return targetMin }
            if leading && !trailing { return targetMin }
            if trailing && !leading { return targetMin + targetLength - length }
            return Geometry.snap(targetMin + (targetLength - length) / 2, scale: scale)
        }
        var x = axis(size.width, targetMin: target.minX, targetLength: target.width,
                     leading: sharedEdges.contains(.left), trailing: sharedEdges.contains(.right))
        var y = axis(size.height, targetMin: target.minY, targetLength: target.height,
                     leading: sharedEdges.contains(.top), trailing: sharedEdges.contains(.bottom))
        if let bounds {
            if x + size.width > bounds.maxX { x = bounds.maxX - size.width }
            if x < bounds.minX { x = bounds.minX }
            if y + size.height > bounds.maxY { y = bounds.maxY - size.height }
            if y < bounds.minY { y = bounds.minY }
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// True if every edge of `a` is within `tolerance` of `b`.
    public static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = tolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// Moves/resizes `window` to `target` (see type doc). `bounds` (usually the usable area) is
    /// where a re-aligned window is nudged back into; nil disables the nudge (used by revert, which
    /// must restore frames exactly).
    @discardableResult
    public static func setFrame(
        _ target: CGRect, of window: AXUIElement, sharedEdges: Edges, bounds: CGRect?, scale: CGFloat
    ) -> Result {
        AX.prepare(window)
        let pid = AX.pid(window)
        let app = pid.map { AX.application(pid: $0) }
        let enhancedUI = "AXEnhancedUserInterface"
        let enhancedWasOn = app.flatMap { AX.bool($0, enhancedUI) } == true
        if enhancedWasOn, let app { AX.set(app, enhancedUI, NSNumber(value: false)) }
        defer {
            let bundleID = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            if enhancedWasOn, let app, !isChromiumFamily(bundleID) {
                AX.set(app, enhancedUI, NSNumber(value: true))
            }
        }

        // A failed settable query counts as resizable (Rectangle does the same).
        let sizeSettable = AX.isSettable(window, kAXSizeAttribute) ?? true
        if sizeSettable {
            AX.setSize(window, target.size)
            AX.setPosition(window, target.origin)
            AX.setSize(window, target.size)
        } else if let size = AX.size(window) {
            let aligned = alignedFrame(size: size, in: target, sharedEdges: sharedEdges, bounds: bounds, scale: scale)
            AX.setPosition(window, aligned.origin)
        }

        var final = AX.frame(window)
        var realigned = false
        if let actual = final, !matches(actual, target) {
            let aligned = alignedFrame(size: actual.size, in: target, sharedEdges: sharedEdges, bounds: bounds, scale: scale)
            if abs(aligned.minX - actual.minX) > 0.25 || abs(aligned.minY - actual.minY) > 0.25 {
                AX.setPosition(window, aligned.origin)
                realigned = true
                final = AX.frame(window)
            }
        }
        return Result(target: target, final: final, sizeSettable: sizeSettable, realigned: realigned)
    }
}
