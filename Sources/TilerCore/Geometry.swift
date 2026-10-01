import CoreGraphics

// MARK: Coordinate space
//
// Every CGRect / CGPoint in TilerCore lives in ONE space: origin at the top-left, y growing
// downward, in points. This is the Accessibility / CoreGraphics global space (origin = top-left
// of the PRIMARY screen), so results can be handed to AX `kAXPositionAttribute` /
// `kAXSizeAttribute` unchanged. Callers convert NSScreen rects (bottom-left origin) before
// calling in: `y' = H − r.maxY` with `H = NSScreen.screens[0].frame.maxY` (SPEC §0).
// `UnitRect` uses the same orientation: (0, 0) is the usable area's top-left corner.
//
// Pixel rounding happens in this space. Screen origins sit on whole points, so rounding here is
// equivalent to rounding in the flipped NSScreen space.

/// Pure geometry helpers (SPEC §1 "Geometry").
public enum Geometry {
    /// Rounds a coordinate to the nearest device pixel (a multiple of `1 / scale` points).
    public static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Maps `unit` into `area` (top-left space).
    ///
    /// Every boundary is computed on its own, `edge(f) = round((min + f · len) · scale) / scale`,
    /// so tiles that share a unit edge meet exactly — no Rectangle-style floor slack. Then gaps:
    /// the gap is rounded to whole pixels `G`; an edge on the area's border (unit 0 or 1) is
    /// inset by `G` only if `gapAppliesToEdges`; an interior edge is inset by half the gap on
    /// each side — `G − ⌊G/2⌋` on a tile's leading (min) edge and `⌊G/2⌋` on its trailing (max)
    /// edge, so neighbours end up exactly `G` pixels apart and every edge stays on the pixel
    /// grid (for an even `G` both halves are exactly `g/2`).
    public static func frame(
        for unit: UnitRect, in area: CGRect, scale: CGFloat,
        gap: CGFloat = 0, gapAppliesToEdges: Bool = false
    ) -> CGRect {
        let gapPixels = max(0, (gap * scale).rounded())
        let outer = gapAppliesToEdges ? gapPixels : 0
        let trailing = (gapPixels / 2).rounded(.down)
        let leading = gapPixels - trailing

        // Edge positions in device pixels.
        func edge(_ fraction: Double, _ origin: CGFloat, _ length: CGFloat) -> CGFloat {
            ((origin + CGFloat(fraction) * length) * scale).rounded()
        }
        let minX = edge(unit.minX, area.minX, area.width) + (unit.minX <= 0 ? outer : leading)
        let maxX = edge(unit.maxX, area.minX, area.width) - (unit.maxX >= 1 ? outer : trailing)
        let minY = edge(unit.minY, area.minY, area.height) + (unit.minY <= 0 ? outer : leading)
        let maxY = edge(unit.maxY, area.minY, area.height) - (unit.maxY >= 1 ? outer : trailing)
        return CGRect(
            x: minX / scale, y: minY / scale,
            width: max(0, maxX - minX) / scale, height: max(0, maxY - minY) / scale)
    }

    /// A frame of `size` centered on `area`, origin snapped to the pixel grid. The size is kept.
    /// On an axis where the window is larger than the area, it is aligned to the area's
    /// leading edge instead (keeps the title bar reachable).
    public static func centered(size: CGSize, in area: CGRect, scale: CGFloat) -> CGRect {
        let x = size.width > area.width ? area.minX : area.midX - size.width / 2
        let y = size.height > area.height ? area.minY : area.midY - size.height / 2
        return CGRect(x: snap(x, scale: scale), y: snap(y, scale: scale),
                      width: size.width, height: size.height)
    }
}

/// The area presets tile on one screen, plus everything needed to turn unit rects into frames:
/// backing scale and gap. All rects are in the top-left space (see top of file). The app always
/// uses gap 0 (SPEC §1 "No gaps"); the gap parameters remain for the geometry model and tests.
public struct UsableArea: Equatable, Sendable {
    /// Usable rect in points, top-left space.
    public var rect: CGRect
    /// Backing scale factor of the screen (2 on Retina).
    public var scale: CGFloat
    /// Gap between tiles in points.
    public var gap: CGFloat
    public var gapAppliesToEdges: Bool

    public init(rect: CGRect, scale: CGFloat, gap: CGFloat = 0, gapAppliesToEdges: Bool = false) {
        self.rect = rect
        self.scale = scale
        self.gap = gap
        self.gapAppliesToEdges = gapAppliesToEdges
    }

    /// SPEC §1: usable area of a screen for `preset` = the screen's `visibleFrame` (already
    /// converted to the top-left space); for a Stage Manager (`-sm`) variant minus
    /// `stageManagerInset` on the left, so its layout is the full-width layout scaled into
    /// `[minX + inset, maxX]`. The inset is rounded to whole device pixels so the usable rect
    /// and every frame in it share the pixel grid. Gap 0 (windows touch).
    public init(visibleFrame: CGRect, scale: CGFloat, preset: Preset, stageManagerInset: Double) {
        var rect = visibleFrame
        if preset.isStageManagerVariant {
            let inset = min(max(0, Geometry.snap(CGFloat(stageManagerInset), scale: scale)), rect.width)
            rect.origin.x += inset
            rect.size.width -= inset
        }
        self.init(rect: rect, scale: scale)
    }

    /// Frame for a unit rect, with pixel rounding and gaps.
    public func frame(for unit: UnitRect) -> CGRect {
        Geometry.frame(for: unit, in: rect, scale: scale, gap: gap, gapAppliesToEdges: gapAppliesToEdges)
    }

    /// Slot frames of an arrange preset, in slot order (empty for other kinds).
    public func slotFrames(for preset: Preset) -> [CGRect] {
        preset.slots.map(frame(for:))
    }

    /// Target of a `.center` preset for a window of `size`.
    public func centeredFrame(size: CGSize) -> CGRect {
        Geometry.centered(size: size, in: rect, scale: scale)
    }
}
