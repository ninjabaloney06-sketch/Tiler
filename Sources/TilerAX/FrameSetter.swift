import AppKit
import ApplicationServices
import TilerCore

/// Sets one window's frame through AX (SPEC §3). All frames are in AX space.
///
/// Sequence: `AXEnhancedUserInterface` off on the app element (if it was on) → glide → size →
/// position → size → read back. The glide (ninja, 2 Oct 2026: windows should move like macOS's
/// native animations) interpolates from the window's current frame to the target over ~0.2 s
/// with an ease-in-out curve (10 steps, whole-point frames, AX position+size set per step) and
/// is skipped while `TILER_NO_ANIMATE` is set (the live-test tools run with it set). If any
/// edge is off by more than 1 pt after the exact set (min-size / fixed-aspect / fixed-size
/// windows), the window keeps the size the app allowed and is re-aligned with `alignedFrame`,
/// then read back again. Enhanced UI is restored afterwards except for Chromium-family apps
/// (Rectangle's "automatic" policy). Windows whose size is not settable are only moved (no
/// glide — their final position is only known after the size is read).
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

    /// Environment variable that switches the glide off (SPEC §3): set = windows jump instantly
    /// to the final frame. Same pattern as `TILER_ONLY_PIDS` — the live-test tools set it so
    /// their frame checks read exact frames without timing dependence (tiler-harness for its
    /// in-process engine; tiler-palettetest and tiler-hovertest pass it to the spawned Tiler).
    public static let noAnimateVariable = "TILER_NO_ANIMATE"

    /// True while `TILER_NO_ANIMATE` is set, read on every move (the harness sets it at runtime).
    static var animationDisabled: Bool { getenv(noAnimateVariable) != nil }

    /// Duration of one glide (SPEC §3) and its step count: ~0.2 s over 10 steps keeps the added
    /// wall time per move far under the 0.35 s bound even with one slow (timeout-length) set.
    static let glideDuration: TimeInterval = 0.2
    static let glideSteps = 10

    /// One window of a `setFrames` batch.
    public struct Request {
        public let window: AXUIElement
        public let target: CGRect
        public let sharedEdges: Edges

        public init(window: AXUIElement, target: CGRect, sharedEdges: Edges) {
            self.window = window
            self.target = target
            self.sharedEdges = sharedEdges
        }
    }

    /// Interpolates every `(window, start, target)` together (SPEC §3 "Glide"): ease-in-out
    /// (smoothstep) at whole-point frames, one AX size + position set per window per step, all
    /// windows on the same frame of the curve (ninja, 3 Oct 2026: an arrange glides as one
    /// motion, not window after window). Each step's curve position comes from the elapsed time,
    /// so slow sets (many windows of one app) mean fewer steps, never a longer glide; at most
    /// `glideSteps` steps, ending past `glideDuration`. A failed set skips that window for the
    /// step; the exact final set in `setFrames` always follows.
    static func glide(_ moves: [(window: AXUIElement, start: CGRect, target: CGRect)]) {
        let moves = moves.filter { $0.start != $0.target }
        guard !animationDisabled, !moves.isEmpty else { return }
        let began = Date()
        let interval = glideDuration / Double(glideSteps)
        var step = 0
        while step < glideSteps {
            step += 1
            let due = began.addingTimeInterval(interval * Double(step))
            let remaining = due.timeIntervalSinceNow
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            let t = min(1, Date().timeIntervalSince(began) / glideDuration)
            guard t < 1 else { break }
            let eased = t * t * (3 - 2 * t)
            for move in moves {
                let (start, target) = (move.start, move.target)
                let frame = CGRect(
                    x: (start.minX + (target.minX - start.minX) * eased).rounded(),
                    y: (start.minY + (target.minY - start.minY) * eased).rounded(),
                    width: (start.width + (target.width - start.width) * eased).rounded(),
                    height: (start.height + (target.height - start.height) * eased).rounded())
                if !AX.setSize(move.window, frame.size) { continue }  // failed step: next window
                AX.setPosition(move.window, frame.origin)
            }
        }
    }

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
        setFrames([Request(window: window, target: target, sharedEdges: sharedEdges)],
                  bounds: bounds, scale: scale)[0]
    }

    /// Moves/resizes every request's window to its target (see type doc): the resizable windows
    /// glide together, then each gets the exact set, readback and re-align. Results are in
    /// request order.
    public static func setFrames(_ requests: [Request], bounds: CGRect?, scale: CGFloat) -> [Result] {
        let enhancedUI = "AXEnhancedUserInterface"
        var enhancedOff: [pid_t: AXUIElement] = [:]
        var sizeSettable: [Bool] = []
        for request in requests {
            AX.prepare(request.window)
            if let pid = AX.pid(request.window), enhancedOff[pid] == nil {
                let app = AX.application(pid: pid)
                if AX.bool(app, enhancedUI) == true {
                    AX.set(app, enhancedUI, NSNumber(value: false))
                    enhancedOff[pid] = app
                }
            }
            // A failed settable query counts as resizable (Rectangle does the same).
            sizeSettable.append(AX.isSettable(request.window, kAXSizeAttribute) ?? true)
        }
        defer {
            for (pid, app) in enhancedOff {
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                if !isChromiumFamily(bundleID) { AX.set(app, enhancedUI, NSNumber(value: true)) }
            }
        }

        glide(requests.indices.compactMap { index in
            let request = requests[index]
            guard sizeSettable[index], let start = AX.frame(request.window) else { return nil }
            return (request.window, start, request.target)
        })

        return requests.indices.map { index in
            let request = requests[index]
            let (window, target) = (request.window, request.target)
            if sizeSettable[index] {
                AX.setSize(window, target.size)
                AX.setPosition(window, target.origin)
                AX.setSize(window, target.size)
                if let actual = AX.frame(window), !sizesMatch(actual.size, target.size) {
                    unstick(window, target: target, bounds: bounds)
                }
            } else if let size = AX.size(window) {
                let aligned = alignedFrame(size: size, in: target, sharedEdges: request.sharedEdges,
                                           bounds: bounds, scale: scale)
                AX.setPosition(window, aligned.origin)
            }

            var final = AX.frame(window)
            var realigned = false
            if let actual = final, !matches(actual, target) {
                let aligned = alignedFrame(size: actual.size, in: target, sharedEdges: request.sharedEdges,
                                           bounds: bounds, scale: scale)
                if abs(aligned.minX - actual.minX) > 0.25 || abs(aligned.minY - actual.minY) > 0.25 {
                    AX.setPosition(window, aligned.origin)
                    realigned = true
                    final = AX.frame(window)
                }
            }
            return Result(target: target, final: final, sizeSettable: sizeSettable[index], realigned: realigned)
        }
    }

    static func sizesMatch(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Second try for a resizable window that kept a different size: AppKit ignores height
    /// changes while a window's bottom edge sits within ~20 pt of a display edge that borders
    /// another display (measured 3 Oct 2026, Terminal and TextEdit, external display stacked
    /// above the built-in one; the glide's last steps park bottom-row windows exactly there, so
    /// they kept one to four rows too many). The window is lifted to the top of `bounds` (else
    /// of its target), resized there and put back. Apps that refuse the size for other reasons
    /// (min size, resize increments) answer the same again; the re-align rule handles them.
    static func unstick(_ window: AXUIElement, target: CGRect, bounds: CGRect?) {
        let top = bounds?.minY ?? target.minY
        AX.setPosition(window, CGPoint(x: target.minX, y: top))
        AX.setSize(window, target.size)
        AX.setPosition(window, target.origin)
        AX.setSize(window, target.size)
    }
}
