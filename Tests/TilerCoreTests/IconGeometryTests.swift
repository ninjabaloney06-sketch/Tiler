import CoreGraphics
import Testing
@testable import TilerCore

@Suite("IconGeometry")
struct IconGeometryTests {
    static let iconSizes: [Double] = [0.6, 0.75, 0.8, 1.0, 1.37, 1.5, 2.0]
    static let arrangeIDs = PresetLibrary.all.filter { $0.kind == .arrange }.map(\.id)
    static let splitIDs = ["arrange-1+3", "arrange-2+3", "arrange-1+4-grid", "arrange-1+4-rows",
                           "arrange-2+4-grid", "arrange-2+4-rows"].flatMap { [$0, $0 + "-sm"] }

    static func icon(_ id: String, _ paletteSize: Double, scale: CGFloat = 2) -> (preset: Preset, icon: IconGeometry) {
        let preset = PresetLibrary.preset(id: id)!
        let size = IconGeometry.iconSize(paletteSize: paletteSize, pixelScale: scale)
        return (preset, IconGeometry(preset: preset, size: size, pixelScale: scale))
    }

    // MARK: Reference metrics

    @Test("Apple's measured proportions: stroke 3.6, radius 5.6, inset 2.8, fill radius 2.1, gap 2.8 of a 50 px icon")
    func measuredProportions() {
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }
        #expect(close(IconGeometry.referenceStroke, 1.8))              // 3.6 / 50 · 25
        #expect(close(IconGeometry.referenceOuterCornerRadius, 2.8))   // 5.6 / 50 · 25
        #expect(close(IconGeometry.referenceInset, 1.4))               // 2.8 / 50 · 25
        #expect(close(IconGeometry.referenceFillCornerRadius, 1.05))   // 2.1 / 50 · 25
        #expect(close(IconGeometry.referenceSlotGap, 1.4))             // 2.8 / 50 · 25
    }

    @Test("Metrics at size 1.0 @2x: 25 × 20 pt (SPEC §10.1), 2 pt (4 px) outline, content inset 3.5 pt, rounded fills")
    func referenceMetrics() {
        let icon = Self.icon("fill", 1.0).icon
        #expect(IconGeometry.iconSize(paletteSize: 1.0) == CGSize(width: 25, height: 20))
        #expect(icon.bounds == CGRect(x: 0, y: 0, width: 25, height: 20))
        #expect(icon.strokeWidth == 2) // 1.8 pt snapped to 4 px
        #expect(icon.outlineRect == CGRect(x: 1, y: 1, width: 23, height: 18))
        #expect(abs(icon.outlineCornerRadius - (2.8 - 1)) < 1e-9) // outer radius − stroke / 2
        #expect(icon.contentRect == CGRect(x: 3.5, y: 3.5, width: 18, height: 13)) // 2 + 1.4 → 7 px
        #expect(icon.layoutRect == icon.contentRect)
        #expect(icon.fills == [icon.contentRect])
        #expect(icon.stageManagerMarks.isEmpty)
        #expect(icon.filledRects == icon.fills)
        #expect(abs(icon.fillCornerRadius - 1.05) < 1e-9)
    }

    @Test("Move & resize fills are the unit rect inside the content rect")
    func moveResizeFills() {
        func fills(_ id: String) -> [CGRect] { Self.icon(id, 1.0).icon.fills }
        #expect(fills("left-half") == [CGRect(x: 3.5, y: 3.5, width: 9, height: 13)])
        #expect(fills("right-half") == [CGRect(x: 12.5, y: 3.5, width: 9, height: 13)])
        #expect(fills("top-half") == [CGRect(x: 3.5, y: 3.5, width: 18, height: 6.5)])
        #expect(fills("bottom-half") == [CGRect(x: 3.5, y: 10, width: 18, height: 6.5)])
        // Centered block: 4.5 pt / 3 pt from the content edges on each side.
        #expect(fills("center") == [CGRect(x: 8, y: 6.5, width: 9, height: 7)])
    }

    @Test("Center icon block is centered in the layout rect", arguments: ["center", "center-sm"], iconSizes)
    func centerIconCentered(presetID: String, paletteSize: Double) {
        for scale in [1, 2] as [CGFloat] {
            let icon = Self.icon(presetID, paletteSize, scale: scale).icon
            let fill = icon.fills[0]
            let layout = icon.layoutRect
            #expect(fill.minX - layout.minX == layout.maxX - fill.maxX)
            #expect(fill.minY - layout.minY == layout.maxY - fill.maxY)
        }
    }

    @Test("Everything scales with the palette size")
    func scaling() {
        let icon = Self.icon("fill", 2.0).icon
        #expect(icon.bounds.size == CGSize(width: 50, height: 40))
        #expect(icon.strokeWidth == 3.5) // 3.6 pt → 7 px
        #expect(abs(icon.outlineCornerRadius - (5.6 - 1.75)) < 1e-9)
        #expect(icon.contentRect == CGRect(x: 6.5, y: 6.5, width: 37, height: 27)) // 3.5 + 2.8 → 13 px
        #expect(abs(icon.fillCornerRadius - 2.1) < 1e-9)
    }

    @Test("Icon sizes round to whole device pixels; the initializer snaps a raw size too")
    func sizesSnapToPixels() {
        #expect(IconGeometry.iconSize(paletteSize: 0.6) == CGSize(width: 15, height: 12))     // 30 × 24 px, already whole
        #expect(IconGeometry.iconSize(paletteSize: 1.37) == CGSize(width: 34.5, height: 27.5)) // 68.5 × 54.8 px → 69 × 55
        #expect(IconGeometry.iconSize(paletteSize: 1.37, pixelScale: 1) == CGSize(width: 34, height: 27))
        #expect(IconGeometry.iconSize(paletteSize: 1.0) == IconGeometry.referenceSize)
        let icon = IconGeometry(preset: PresetLibrary.preset(id: "fill")!, size: CGSize(width: 25.2, height: 19.8))
        #expect(icon.bounds.size == CGSize(width: 25, height: 20))
    }

    // MARK: Stage Manager variants

    @Test("-sm icon at size 1.0: three 3 × 2 pt bars centered at the left, inset inside the content rect, layout in the remaining width")
    func stageManagerReference() {
        let icon = Self.icon("fill-sm", 1.0).icon
        #expect(icon.stageManagerMarks == [
            CGRect(x: 3.5, y: 6, width: 3, height: 2),
            CGRect(x: 3.5, y: 9, width: 3, height: 2),
            CGRect(x: 3.5, y: 12, width: 3, height: 2),
        ])
        #expect(icon.contentRect.contains(icon.stageManagerMarks[0]))
        #expect(icon.contentRect.contains(icon.stageManagerMarks[1]))
        #expect(icon.contentRect.contains(icon.stageManagerMarks[2]))
        #expect(icon.layoutRect == CGRect(x: 8, y: 3.5, width: 13.5, height: 13)) // mark 3 + gap 1.5 (3 px)
        #expect(icon.fills == [icon.layoutRect])
        #expect(icon.filledRects == icon.fills + icon.stageManagerMarks)
    }

    @Test("Strip mark only on -sm variants: three equal bars at the content's left edge, vertically centered, on the pixel grid",
          arguments: PresetLibrary.all.map(\.id), iconSizes)
    func stageManagerMark(presetID: String, paletteSize: Double) {
        for scale in [1, 2] as [CGFloat] {
            let (preset, icon) = Self.icon(presetID, paletteSize, scale: scale)
            let c = icon.contentRect
            guard preset.isStageManagerVariant else {
                #expect(icon.stageManagerMarks.isEmpty)
                #expect(icon.layoutRect == c)
                continue
            }
            let marks = icon.stageManagerMarks
            #expect(marks.count == 3)
            #expect(marks.allSatisfy { c.contains($0) },
                    "\(presetID) \(paletteSize)@\(scale)x marks \(marks) overflow contentRect \(c)")
            #expect(marks.allSatisfy { $0.size == marks[0].size }, "unequal bars \(marks)")
            #expect(marks.allSatisfy { $0.minX == c.minX && $0.width > 0 && $0.height > 0 && isOnPixelGrid($0, scale: scale) })
            #expect(marks[0].minY - c.minY == c.maxY - marks[2].maxY, "\(presetID) \(paletteSize)@\(scale)x bars not centered")
            #expect(marks[1].minY - marks[0].maxY == marks[2].minY - marks[1].maxY)
            let layout = icon.layoutRect
            #expect(layout.minX - marks[0].maxX >= 1 / scale)
            #expect(layout.maxX == c.maxX && layout.minY == c.minY && layout.height == c.height)
            #expect(isOnPixelGrid(layout, scale: scale))
            #expect(icon.fills.allSatisfy { layout.contains($0) })
        }
    }

    // MARK: Arrange fills

    @Test("Arrange slots of equal unit size get exactly equal fills (@1x and @2x)", arguments: arrangeIDs, iconSizes)
    func equalSlotsEqualFills(presetID: String, paletteSize: Double) {
        for scale in [1, 2] as [CGFloat] {
            let (preset, icon) = Self.icon(presetID, paletteSize, scale: scale)
            let slots = preset.slots
            let fills = icon.fills
            #expect(fills.count == slots.count)
            for i in slots.indices {
                for j in slots.indices where j > i {
                    if abs(slots[i].width - slots[j].width) < 1e-9 {
                        #expect(fills[i].width == fills[j].width,
                                "\(presetID) \(paletteSize)@\(scale)x: widths \(fills[i].width) vs \(fills[j].width)")
                    }
                    if abs(slots[i].height - slots[j].height) < 1e-9 {
                        #expect(fills[i].height == fills[j].height,
                                "\(presetID) \(paletteSize)@\(scale)x: heights \(fills[i].height) vs \(fills[j].height)")
                    }
                }
            }
        }
    }

    @Test("Split layouts: the 50 % left column is exactly as wide as the right column region (@1x and @2x)",
          arguments: splitIDs, iconSizes)
    func splitColumnsBalanced(presetID: String, paletteSize: Double) {
        for scale in [1, 2] as [CGFloat] {
            let (preset, icon) = Self.icon(presetID, paletteSize, scale: scale)
            let pairs = zip(preset.slots, icon.fills)
            let left = pairs.filter { $0.0.maxX <= 0.5 }.map(\.1)
            let right = pairs.filter { $0.0.minX >= 0.5 }.map(\.1)
            let rightMinX = right.map(\.minX).min()!
            let rightMaxX = right.map(\.maxX).max()!
            #expect(left.allSatisfy { $0.minX == left[0].minX && $0.width == left[0].width })
            #expect(left[0].minX - icon.layoutRect.minX == icon.layoutRect.maxX - rightMaxX)
            #expect(left[0].width == rightMaxX - rightMinX,
                    "\(presetID) \(paletteSize)@\(scale)x: left \(left[0].width) vs right \(rightMaxX - rightMinX)")
        }
    }

    @Test("Neighbouring arrange fills are a whole-pixel gap within 1 px of the slot gap apart; outer margins are symmetric and at most 1 px (@1x and @2x)",
          arguments: arrangeIDs, iconSizes)
    func arrangeSeparatedByGap(presetID: String, paletteSize: Double) {
        for scale in [1, 2] as [CGFloat] {
            let (preset, icon) = Self.icon(presetID, paletteSize, scale: scale)
            let k = min(icon.bounds.width / IconGeometry.referenceSize.width,
                        icon.bounds.height / IconGeometry.referenceSize.height)
            let nominal = (IconGeometry.referenceSlotGap * k * scale).rounded() / scale
            let fills = icon.fills
            let slots = preset.slots
            func check(_ gap: CGFloat) {
                #expect(abs(gap - nominal) <= 1 / scale && gap >= 1 / scale && isOnPixelGrid(gap, scale: scale),
                        "\(presetID) \(paletteSize)@\(scale)x: gap \(gap), nominal \(nominal)")
            }
            for i in slots.indices {
                for j in slots.indices where i != j {
                    let verticalOverlap = min(slots[i].maxY, slots[j].maxY) - max(slots[i].minY, slots[j].minY)
                    if abs(slots[i].maxX - slots[j].minX) < 1e-9 && verticalOverlap > 0 {
                        check(fills[j].minX - fills[i].maxX)
                    }
                    let horizontalOverlap = min(slots[i].maxX, slots[j].maxX) - max(slots[i].minX, slots[j].minX)
                    if abs(slots[i].maxY - slots[j].minY) < 1e-9 && horizontalOverlap > 0 {
                        check(fills[j].minY - fills[i].maxY)
                    }
                }
            }
            // Outer fills touch the layout rect, except for ≤ 1 px symmetric margins when a
            // gap of ≤ 1 px cannot narrow (tiny @1x icons).
            let layout = icon.layoutRect
            let left = fills.map(\.minX).min()! - layout.minX
            let right = layout.maxX - fills.map(\.maxX).max()!
            let top = fills.map(\.minY).min()! - layout.minY
            let bottom = layout.maxY - fills.map(\.maxY).max()!
            #expect(left == right && top == bottom)
            #expect(left <= 1 / scale && top <= 1 / scale)
            if nominal >= 2 / scale {
                #expect(left == 0 && top == 0)
            }
        }
    }

    @Test("Critic cases: identical rows/columns at the sizes that used to differ")
    func criticCases() {
        func fills(_ id: String, _ paletteSize: Double, scale: CGFloat = 2) -> [CGRect] {
            Self.icon(id, paletteSize, scale: scale).icon.fills
        }
        // 4x4 @1.0@2x: layout 36 × 26 px, gap 3/4 px. Columns 4 · 6 + 3 · 4 = 36; rows 4 · 4 + 3 + 4 + 3 = 26.
        let grid = fills("arrange-4x4", 1.0)
        #expect(Set(grid.map(\.width)) == [3])
        #expect(Set(grid.map(\.height)) == [2])
        #expect(stride(from: 0, to: 16, by: 4).map { grid[$0].minY } == [3.5, 7, 11, 14.5])
        // 4x4 @0.75@2x: layout 28 × 20 px, gap 2 px → rows 4 · 3 + 3 + 2 + 3 = 20.
        #expect(Set(fills("arrange-4x4", 0.75).map(\.height)) == [1.5])
        // 3x2 @1.0@1x: layout 19 px (@1x, px = pt), gap 1 px → 3 · 5 + 2 · 2 = 19.
        #expect(fills("arrange-3x2", 1.0, scale: 1).prefix(3).map(\.width) == [5, 5, 5])
        // 3x3 @2.0@2x: layout 74 px, gap 6 px → 3 · 20 + 2 · 7 = 74.
        #expect(fills("arrange-3x3", 2.0).prefix(3).map(\.width) == [10, 10, 10])
        // 2+4 (rows) @1.0: the four right rows are identical.
        #expect(Set(fills("arrange-2+4-rows", 1.0).suffix(4).map(\.height)) == [2])
    }

    @Test("partition: equal parts, exact fill, palindromic gaps within 1 px of nominal, symmetric margins, quarters nest in halves")
    func partitionProperties() {
        #expect(IconGeometry.partition(56, into: 4, gap: 5).map { [$0.start, $0.end] }
                == [[0, 10], [15, 25], [31, 41], [46, 56]])
        #expect(IconGeometry.partition(64, into: 1, gap: 5).map { [$0.start, $0.end] } == [[0, 64]])
        for total in 12...200 {
            for gap in 0...12 {
                for n in 1...4 where total - (n - 1) * (gap + 1) >= 2 * n {
                    let parts = IconGeometry.partition(total, into: n, gap: gap)
                    let label = "\(total)/\(n)/\(gap)"
                    #expect(parts.count == n)
                    #expect(Set(parts.map { $0.end - $0.start }).count == 1, "unequal parts \(label)")
                    let margin = parts[0].start
                    #expect(total - parts[n - 1].end == margin, "asymmetric margins \(label)")
                    #expect(margin == 0 || (gap <= 1 && margin <= n / 2), "margin \(margin) for \(label)")
                    let gaps = zip(parts, parts.dropFirst()).map { $1.start - $0.end }
                    #expect(gaps == Array(gaps.reversed()), "asymmetric gaps \(gaps) for \(label)")
                    #expect(gaps.allSatisfy { abs($0 - gap) <= 1 && $0 >= min(gap, 1) }, "gaps \(gaps) for \(label)")
                }
                if total - 3 * gap >= 8 {
                    let halves = IconGeometry.partition(total, into: 2, gap: gap)
                    let quarters = IconGeometry.partition(total, into: 4, gap: gap)
                    #expect(quarters[1].end == halves[0].end && quarters[2].start == halves[1].start,
                            "quarters do not nest in halves for \(total)/\(gap)")
                }
            }
        }
    }

    // MARK: Well-formedness, pixel snapping and symmetry for every preset

    @Test("Every preset: one fill per rect inside the layout rect, on the pixel grid, no overlaps",
          arguments: PresetLibrary.all.map(\.id), iconSizes)
    func fillsWellFormed(presetID: String, paletteSize: Double) {
        for scale in [1, 2] as [CGFloat] {
            let (preset, icon) = Self.icon(presetID, paletteSize, scale: scale)
            #expect(icon.fills.count == max(1, preset.rects.count))
            for fill in icon.fills {
                #expect(icon.layoutRect.contains(fill), "\(fill) outside \(icon.layoutRect)")
                #expect(fill.width > 0 && fill.height > 0)
                #expect(isOnPixelGrid(fill, scale: scale))
            }
            let all = icon.filledRects
            for i in all.indices {
                for j in all.indices where j > i {
                    #expect(overlapArea(all[i], all[j]) == 0)
                }
            }
        }
    }

    /// The preset mirrored left↔right (or top↔bottom), keeping its width variant.
    static func mirrored(_ preset: Preset, horizontally: Bool) -> Preset {
        let rects = preset.rects.map { r in
            horizontally
                ? UnitRect(minX: 1 - r.maxX, minY: r.minY, maxX: 1 - r.minX, maxY: r.maxY)
                : UnitRect(minX: r.minX, minY: 1 - r.maxY, maxX: r.maxX, maxY: 1 - r.minY)
        }
        let base: Preset
        switch preset.kind {
        case .moveResize: base = .moveResize(id: "mirror", name: "Mirror", rect: rects[0])
        case .center: base = .center(id: "mirror", name: "Mirror")
        case .arrange: base = .arrange(id: "mirror", name: "Mirror", slots: rects)
        }
        return preset.isStageManagerVariant ? base.stageManagerVariant() : base
    }

    /// Mirror `rect` left↔right inside `frame`, or (frame nil) top↔bottom inside `bounds`.
    static func mirror(_ rect: CGRect, horizontallyIn frame: CGRect?, bounds: CGRect) -> CGRect {
        if let frame {
            return CGRect(x: frame.minX + frame.maxX - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
        }
        return CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    @Test("Icon is pixel-snapped, has equal opposite margins and its layout is an exact mirror image of the mirrored preset (@1x and @2x)",
          arguments: PresetLibrary.all.map(\.id), iconSizes)
    func pixelSnappedAndMirrorSymmetric(presetID: String, paletteSize: Double) throws {
        let preset = try #require(PresetLibrary.preset(id: presetID))
        for scale in [1, 2] as [CGFloat] {
            let size = IconGeometry.iconSize(paletteSize: paletteSize, pixelScale: scale)
            #expect(isOnPixelGrid(size.width, scale: scale) && isOnPixelGrid(size.height, scale: scale),
                    "@\(scale)x size \(size)")
            let icon = IconGeometry(preset: preset, size: size, pixelScale: scale)
            let b = icon.bounds
            let c = icon.contentRect
            #expect(b.size == size)

            // Content and outline are centered in the bounds, content on the pixel grid.
            #expect(c.minX - b.minX == b.maxX - c.maxX, "@\(scale)x left/right margins of \(c) in \(b)")
            #expect(c.minY - b.minY == b.maxY - c.maxY, "@\(scale)x top/bottom margins of \(c) in \(b)")
            #expect(isOnPixelGrid(c, scale: scale))
            // The outline inset is stroke / 2 (a non-dyadic real), so compare up to float round-off.
            #expect(abs((icon.outlineRect.minX - b.minX) - (b.maxX - icon.outlineRect.maxX)) < 1e-9)
            #expect(abs((icon.outlineRect.minY - b.minY) - (b.maxY - icon.outlineRect.maxY)) < 1e-9)

            // Horizontal mirror inside the layout rect (= content rect, centered in the bounds,
            // for full-width presets); vertical mirror inside the bounds, strip mark included.
            let horizontal = IconGeometry(preset: Self.mirrored(preset, horizontally: true), size: size, pixelScale: scale)
            #expect(horizontal.layoutRect == icon.layoutRect)
            #expect(horizontal.fills == icon.fills.map { Self.mirror($0, horizontallyIn: icon.layoutRect, bounds: b) },
                    "@\(scale)x horizontal mirror of \(presetID)")
            let vertical = IconGeometry(preset: Self.mirrored(preset, horizontally: false), size: size, pixelScale: scale)
            #expect(vertical.fills == icon.fills.map { Self.mirror($0, horizontallyIn: nil, bounds: b) },
                    "@\(scale)x vertical mirror of \(presetID)")
            #expect(Array(icon.stageManagerMarks.map { Self.mirror($0, horizontallyIn: nil, bounds: b) }.reversed())
                    == icon.stageManagerMarks, "@\(scale)x strip mark not vertically symmetric")
        }
    }
}
