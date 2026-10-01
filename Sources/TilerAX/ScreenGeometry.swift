import AppKit
import TilerCore

/// NSScreen (bottom-left origin, y up) ↔ AX/CG (top-left origin of the PRIMARY screen, y down)
/// conversion, usable areas per preset width variant and screen lookup (SPEC §0 "Coordinates",
/// §1 "Width variants" and "Geometry").
public enum ScreenGeometry {
    /// The flip constant: `NSScreen.screens[0].frame.maxY` (the primary screen, never
    /// `NSScreen.main`, which is the key window's screen).
    public static var primaryMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// NSScreen rect → AX rect, and back (the flip is its own inverse): `y' = H − r.maxY`.
    public static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// NSScreen point (e.g. `NSEvent.mouseLocation`) → AX point, and back: `y' = H − y`.
    public static func flip(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    /// The screen's full frame in AX space.
    public static func axFrame(of screen: NSScreen) -> CGRect {
        flip(screen.frame)
    }

    /// The screen's `visibleFrame` (without menu bar and Dock) in AX space.
    public static func axVisibleFrame(of screen: NSScreen) -> CGRect {
        flip(screen.visibleFrame)
    }

    /// Rounding grid for window frames, in steps per point. Window frames only take whole points:
    /// AX origins/sizes on half points are truncated by the system (measured: a 367.5 pt slot at
    /// x = 1102.5 lands at 1102 with width 367, leaving 1 pt gaps). Laying out with SPEC §1's
    /// per-edge formula at scale 1 keeps every edge on a whole point — still on the pixel grid —
    /// so neighbouring windows touch exactly.
    public static let windowGridScale: CGFloat = 1

    /// SPEC §1 usable area of `screen` for `preset` (TilerCore `UsableArea`): the whole
    /// `visibleFrame` for full-width presets; for `-sm` variants minus `stageManagerInset` on the
    /// left, the same layout scaled into the narrower width. Gap 0, whole-point grid
    /// (`windowGridScale`).
    public static func usableArea(of screen: NSScreen, for preset: Preset, stageManagerInset: Double) -> UsableArea {
        UsableArea(visibleFrame: axVisibleFrame(of: screen), scale: windowGridScale,
                   preset: preset, stageManagerInset: stageManagerInset)
    }

    /// CoreGraphics display id of `screen` (stable identity for comparisons).
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    public static func isSameScreen(_ a: NSScreen, _ b: NSScreen) -> Bool {
        guard let idA = displayID(of: a), let idB = displayID(of: b) else { return a === b }
        return idA == idB
    }

    /// The screen a window (AX frame) belongs to: the screen that fully contains it, else the one
    /// with the largest intersection, else the primary screen (Rectangle/Loop rule).
    public static func screen(forWindowFrame frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        if let containing = screens.first(where: { axFrame(of: $0).contains(frame) }) {
            return containing
        }
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in screens {
            let overlap = axFrame(of: screen).intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen ?? screens.first
    }

    /// The screen containing an AX point; maxX/maxY count as inside (CGRect.contains is
    /// half-open, which would drop the bottom/right edge).
    public static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let frame = axFrame(of: screen)
            return point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
        }
    }
}
