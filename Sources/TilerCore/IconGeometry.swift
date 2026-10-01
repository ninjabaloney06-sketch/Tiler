import CoreGraphics

/// What to draw for a preset's icon in Apple's green-button-menu style (SPEC §4 "Visual spec —
/// Apple's current style"): a thin rounded-rect outline standing for the screen, the target
/// region(s) as filled rounded rects inset from it, arrange slots separated by a thin gap, and —
/// for Stage Manager (`-sm`) variants — a small strip mark of three stacked bars at the left edge
/// with the layout drawn in the remaining width. Icons are procedural: every preset's icon comes
/// from its `rects`. Monochrome; the renderer picks the color.
///
/// Coordinates are icon-local, origin top-left, y down (draw in a flipped context or flip).
/// Proportions are Apple's, measured on `docs/reference/apple-native-menu*.png` (native icon
/// 50.0 × 39.6 px @2x): stroke 3.6, outer corner radius 5.6, fill inset from the stroke's inner
/// edge 2.8, fill corner radius 2.1, gap between arrange slots 2.8 px — each taken as a fraction
/// of the icon width. At the reference size 25 × 20 pt (palette size 1.0; SPEC §10.1 — the same
/// @2x pixels are points, not doubled) that is stroke 1.8, outer radius 2.8, inset 1.4, fill
/// radius 1.05, slot gap 1.4 pt; everything scales with the icon size. The stroke, content inset
/// and gaps are rounded to whole device pixels.
///
/// Guarantees (at any size, @1x and @2x): whole-pixel size and edges; the outline, content and
/// layout are mirror-symmetric (the `-sm` strip mark is the one intentional asymmetry — the
/// layout part beside it is still exact); arrange slots of equal unit size get identical fills.
public struct IconGeometry: Equatable, Sendable {
    /// Icon size at palette size 1.0 (SPEC §10.1: Apple's native menu icon, measured on
    /// `docs/reference/apple-native-menu-{light,dark}@2x.png` — ≈ 50 × 40 px @2x = 25 × 20 pt;
    /// the previous 44 × 35 mistakenly used the @2x pixel count as points, ~1.76× too large).
    public static let referenceSize = CGSize(width: 25, height: 20)
    /// Apple's icon as measured in the @2x reference captures, in pixels.
    static let measuredWidth: CGFloat = 50
    static let measuredStroke: CGFloat = 3.6
    static let measuredOuterCornerRadius: CGFloat = 5.6
    static let measuredInset: CGFloat = 2.8
    static let measuredFillCornerRadius: CGFloat = 2.1
    static let measuredSlotGap: CGFloat = 2.8
    /// The measurements as points at the reference width (measured / 50 · 25).
    static let referenceStroke = measuredStroke / measuredWidth * referenceSize.width
    static let referenceOuterCornerRadius = measuredOuterCornerRadius / measuredWidth * referenceSize.width
    static let referenceInset = measuredInset / measuredWidth * referenceSize.width
    static let referenceFillCornerRadius = measuredFillCornerRadius / measuredWidth * referenceSize.width
    static let referenceSlotGap = measuredSlotGap / measuredWidth * referenceSize.width
    /// Stage Manager strip mark (Tiler's own; not in Apple's menu): bar width, bar height and
    /// the gap between the three bars, in points at the reference size. Tuned at the previous
    /// reference size (44 × 35 pt: width 5, bar height 3.5, bar gap 2) and rescaled here to the
    /// 25 × 20 pt reference (SPEC §10.1) so the three bars keep fitting inside `contentRect`
    /// (13 pt tall at size 1.0) instead of overflowing into the outline stroke.
    static let referenceMarkWidth: CGFloat = 5 * referenceSize.width / 44     // ≈ 2.84
    static let referenceMarkBarHeight: CGFloat = 3.5 * referenceSize.height / 35 // = 2.0
    static let referenceMarkBarGap: CGFloat = 2 * referenceSize.height / 35   // ≈ 1.14
    /// Filled block for `.center` presets (a small centered block, like Apple's "Center").
    static let centerIconRect = UnitRect(minX: 0.25, minY: 0.25, maxX: 0.75, maxY: 0.75)

    /// Icon size for a palette size setting (1.0 → 25 × 20 pt), rounded to whole device pixels
    /// at `pixelScale` so the outline's outer edges land on pixel boundaries.
    public static func iconSize(paletteSize: Double, pixelScale: CGFloat = 2) -> CGSize {
        CGSize(width: Geometry.snap(referenceSize.width * CGFloat(paletteSize), scale: pixelScale),
               height: Geometry.snap(referenceSize.height * CGFloat(paletteSize), scale: pixelScale))
    }

    /// (0, 0, size), size rounded to whole device pixels.
    public let bounds: CGRect
    /// Outline stroke width, whole device pixels (at least one).
    public let strokeWidth: CGFloat
    /// Path to stroke with `strokeWidth` (centered on the path): `bounds` inset by half the
    /// stroke, so the stroke's outer edge touches `bounds`.
    public let outlineRect: CGRect
    /// Corner radius of `outlineRect` (outer radius minus half the stroke).
    public let outlineCornerRadius: CGFloat
    /// Region inside the stroke: `bounds` inset on all four sides by the same amount, stroke +
    /// fill inset rounded to whole device pixels (centered in `bounds`, on the pixel grid).
    public let contentRect: CGRect
    /// Where the preset's layout is drawn: `contentRect`, or for `-sm` variants the part of it
    /// right of the Stage Manager strip mark.
    public let layoutRect: CGRect
    /// Filled regions for the target rect(s), one per rect in `preset.rects` order (one for
    /// `.center`), inside `layoutRect`.
    public let fills: [CGRect]
    /// The Stage Manager strip mark of `-sm` variants — three stacked bars at the left edge of
    /// `contentRect`, vertically centered; empty for full-width presets.
    public let stageManagerMarks: [CGRect]
    /// Corner radius for `fills` and `stageManagerMarks`; clamp to half the shorter side of
    /// each rect when drawing.
    public let fillCornerRadius: CGFloat

    /// Everything to fill: `fills` followed by `stageManagerMarks`.
    public var filledRects: [CGRect] { fills + stageManagerMarks }

    /// - Parameters:
    ///   - size: icon size in points, normally `iconSize(paletteSize:pixelScale:)`; rounded to
    ///     whole device pixels. Metrics scale by `min(width / 25, height / 20)`.
    ///   - pixelScale: backing scale used to snap the size, content, mark and fill edges to
    ///     device pixels (icon-local), so the icon is crisp and symmetric when its origin is
    ///     pixel-aligned.
    public init(preset: Preset, size: CGSize, pixelScale: CGFloat = 2) {
        let size = CGSize(width: Geometry.snap(size.width, scale: pixelScale),
                          height: Geometry.snap(size.height, scale: pixelScale))
        let k = min(size.width / Self.referenceSize.width, size.height / Self.referenceSize.height)
        let stroke = max(1 / pixelScale, Geometry.snap(Self.referenceStroke * k, scale: pixelScale))
        func pixels(_ points: CGFloat) -> Int { Int((points * pixelScale).rounded()) }

        bounds = CGRect(origin: .zero, size: size)
        strokeWidth = stroke
        outlineRect = bounds.insetBy(dx: stroke / 2, dy: stroke / 2)
        outlineCornerRadius = max(0, Self.referenceOuterCornerRadius * k - stroke / 2)
        let contentInset = Geometry.snap(stroke + Self.referenceInset * k, scale: pixelScale)
        let content = bounds.insetBy(dx: contentInset, dy: contentInset)
        contentRect = content
        fillCornerRadius = Self.referenceFillCornerRadius * k
        let slotGap = pixels(Self.referenceSlotGap * k)

        var layout = content
        var marks: [CGRect] = []
        if preset.isStageManagerVariant {
            let markWidth = max(1, pixels(Self.referenceMarkWidth * k))
            let height = pixels(content.height)
            // Bar height takes the parity of the content height so the three bars and two gaps
            // center exactly (3 · bar + 2 · gap ≡ bar mod 2).
            let parity = height % 2
            let ideal = Self.referenceMarkBarHeight * k * pixelScale
            let barHeight = max(parity == 0 ? 2 : 1, 2 * Int(((ideal - CGFloat(parity)) / 2).rounded()) + parity)
            let barGap = max(1, pixels(Self.referenceMarkBarGap * k))
            let top = (height - (3 * barHeight + 2 * barGap)) / 2
            for bar in 0..<3 {
                marks.append(CGRect(
                    x: content.minX,
                    y: content.minY + CGFloat(top + bar * (barHeight + barGap)) / pixelScale,
                    width: CGFloat(markWidth) / pixelScale,
                    height: CGFloat(barHeight) / pixelScale))
            }
            let offset = CGFloat(markWidth + max(1, slotGap)) / pixelScale
            layout = CGRect(x: content.minX + offset, y: content.minY,
                            width: max(0, content.width - offset), height: content.height)
        }
        layoutRect = layout
        stageManagerMarks = marks

        switch preset.kind {
        case .moveResize:
            fills = preset.rects.map { Self.proportionalFill(for: $0, in: layout, scale: pixelScale) }
        case .center:
            fills = [Self.proportionalFill(for: Self.centerIconRect, in: layout, scale: pixelScale)]
        case .arrange:
            fills = preset.rects.map { Self.arrangeFill(for: $0, in: layout, gapPixels: slotGap, scale: pixelScale) }
        }
    }

    // MARK: Arrange icons

    /// Arrange-icon fill: per axis, the slot's interval is looked up in the coarsest even
    /// partition of the layout whose part boundaries it sits on (halves, thirds, quarters, …),
    /// see `partition(_:into:gap:)`. Deliberately not `Geometry.frame`'s window model.
    ///
    /// Every partition has ONE whole-pixel part length, so slots of equal unit size get
    /// identical fills; neighbours are a whole-pixel gap within one pixel of the slot gap apart;
    /// the layout is an exact mirror image of the mirrored preset. Quarters nest exactly inside
    /// halves, so a 50 % column is exactly as wide as the two quarter columns beside it plus
    /// their gap.
    static func arrangeFill(for unit: UnitRect, in layout: CGRect, gapPixels: Int, scale: CGFloat) -> CGRect {
        func span(_ from: Double, _ to: Double, length: CGFloat) -> (start: CGFloat, length: CGFloat) {
            let total = Int((length * scale).rounded())
            let pixels = pixelSpan(from, to, total: total, gap: gapPixels)
            return (CGFloat(pixels.start) / scale, CGFloat(max(0, pixels.end - pixels.start)) / scale)
        }
        let x = span(unit.minX, unit.maxX, length: layout.width)
        let y = span(unit.minY, unit.maxY, length: layout.height)
        return CGRect(x: layout.minX + x.start, y: layout.minY + y.start, width: x.length, height: y.length)
    }

    /// Pixel extent of the unit interval `from…to` inside `total` pixels: parts `i0 ..< i1` of the
    /// smallest partition `n` with `from = i0 / n` and `to = i1 / n`.
    private static func pixelSpan(_ from: Double, _ to: Double, total: Int, gap: Int) -> (start: Int, end: Int) {
        for n in 1...12 {
            let first = from * Double(n)
            let last = to * Double(n)
            let i0 = first.rounded()
            let i1 = last.rounded()
            guard abs(first - i0) < 1e-9, abs(last - i1) < 1e-9, 0 <= i0, i0 < i1, i1 <= Double(n) else { continue }
            let parts = partition(total, into: n, gap: gap)
            return (parts[Int(i0)].start, parts[Int(i1) - 1].end)
        }
        // Not an even subdivision (no library preset): scale proportionally, without gaps.
        let length = CGFloat(total)
        return (Int(split(from, of: length, isFillStart: true)), Int(split(to, of: length, isFillStart: false)))
    }

    /// Splits `total` pixels into `n` parts of ONE whole-pixel length separated by whole-pixel
    /// gaps within one pixel of `gap`, filling `total` exactly and mirror-symmetrically.
    ///
    /// The part length is the largest that leaves a non-negative leftover; leftover pixels
    /// widen gaps symmetrically (an odd one goes to the middle gap, pairs go to mirrored gaps
    /// from the outside in). With an odd `n` there is no middle gap, so the part length takes the
    /// parity of `total` (even leftover); if that leftover exceeds one pixel per gap, the parts
    /// grow by 2 px and the gaps narrow by up to 1 px instead — or, where a gap cannot narrow
    /// (gap ≤ 1 px), every gap gets 1 px and the rest goes to equal outer margins (≤ n/2 px).
    static func partition(_ total: Int, into n: Int, gap: Int) -> [(start: Int, end: Int)] {
        guard n > 1 else { return [(0, total)] }
        let gapCount = n - 1
        var part = floorDivide(total - gapCount * gap, n)
        var gaps: [Int]
        var margin = 0
        if !gapCount.isMultiple(of: 2) {
            gaps = symmetricGaps(leftover: total - n * part - gapCount * gap, count: gapCount, nominal: gap)
        } else {
            if !(total - part).isMultiple(of: 2) { part -= 1 }
            let leftover = total - n * part - gapCount * gap // even, 0 … 2 · gapCount
            if leftover <= gapCount {
                gaps = symmetricGaps(leftover: leftover, count: gapCount, nominal: gap)
            } else if gap - 1 >= min(gap, 1) {
                part += 2
                gaps = symmetricGaps(leftover: leftover - 2 * n, count: gapCount, nominal: gap)
            } else {
                gaps = Array(repeating: gap + 1, count: gapCount)
                margin = (leftover - gapCount) / 2
            }
        }
        var parts: [(start: Int, end: Int)] = []
        var start = margin
        for index in 0..<n {
            parts.append((start, start + part))
            if index < gapCount { start += part + gaps[index] }
        }
        return parts
    }

    /// `count` gaps of `nominal` px sharing `leftover` px (may be negative) symmetrically.
    /// An odd remainder is only possible with an odd `count` and goes to the middle gap.
    private static func symmetricGaps(leftover: Int, count: Int, nominal: Int) -> [Int] {
        let base = floorDivide(leftover, count)
        var gaps = Array(repeating: nominal + base, count: count)
        var remainder = leftover - base * count // 0 ..< count
        if !remainder.isMultiple(of: 2) {
            gaps[count / 2] += 1
            remainder -= 1
        }
        for index in 0..<(remainder / 2) {
            gaps[index] += 1
            gaps[count - 1 - index] += 1
        }
        return gaps
    }

    private static func floorDivide(_ a: Int, _ b: Int) -> Int {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }

    // MARK: Single-rect icons

    /// Move & resize and Center icons: the unit rect scaled into the layout, each edge rounded
    /// to the nearest device pixel mirror-symmetrically (see `split`), so an icon is the exact
    /// mirror image of its mirrored preset.
    static func proportionalFill(for unit: UnitRect, in layout: CGRect, scale: CGFloat) -> CGRect {
        func span(_ from: Double, _ to: Double, length: CGFloat) -> (start: CGFloat, length: CGFloat) {
            let total = (length * scale).rounded()
            let start = split(from, of: total, isFillStart: true)
            let end = split(to, of: total, isFillStart: false)
            return (start / scale, max(0, end - start) / scale)
        }
        let x = span(unit.minX, unit.maxX, length: layout.width)
        let y = span(unit.minY, unit.maxY, length: layout.height)
        return CGRect(x: layout.minX + x.start, y: layout.minY + y.start, width: x.length, height: y.length)
    }

    /// Pixel boundary nearest to `fraction · total`; ties go toward the nearer end (0 or total),
    /// which makes the rounding mirror-symmetric: `split(1 − f) = total − split(f)`. The exact
    /// middle of an odd total has no nearer end: it rounds up for a fill's start and down for a
    /// fill's end, so the halves stay mirror images.
    private static func split(_ fraction: Double, of total: CGFloat, isFillStart: Bool) -> CGFloat {
        if fraction == 0.5 {
            return (total / 2).rounded(isFillStart ? .up : .down)
        }
        func nearestTiesDown(_ value: CGFloat) -> CGFloat { (value - 0.5).rounded(.up) }
        return fraction < 0.5
            ? nearestTiesDown(CGFloat(fraction) * total)
            : total - nearestTiesDown(CGFloat(1 - fraction) * total)
    }
}
