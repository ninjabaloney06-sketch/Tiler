import CoreGraphics
import Testing
@testable import TilerCore

@Suite("Geometry")
struct GeometryTests {
    // MARK: Exact tiling (SPEC §8)

    @Test("Arrange slots tile the usable area exactly", arguments: PresetLibrary.arrange.map(\.id), Fixtures.areas)
    func arrangeSlotsTileExactly(presetID: String, area: TestArea) throws {
        let preset = try #require(PresetLibrary.preset(id: presetID))
        let frames = area.area.slotFrames(for: preset)
        #expect(frames.count == preset.slots.count)
        expectExactTiling(frames, of: area.area.rect)
        for frame in frames {
            #expect(isOnPixelGrid(frame, scale: area.area.scale), "\(frame) off the pixel grid")
        }
    }

    /// Move & resize presets that together cover the whole area.
    static let moveResizeTilings: [[String]] = [
        ["fill"],
        ["left-half", "right-half"],
        ["top-half", "bottom-half"],
        ["top-left-quarter", "top-right-quarter", "bottom-left-quarter", "bottom-right-quarter"],
        ["left-third", "middle-third", "right-third"],
        ["left-two-thirds", "right-third"],
        ["left-third", "right-two-thirds"],
    ]

    @Test("Move & resize families tile the usable area exactly", arguments: moveResizeTilings, Fixtures.areas)
    func moveResizeFamiliesTileExactly(ids: [String], area: TestArea) throws {
        let frames = try ids.map { id in
            let rect = try #require(PresetLibrary.preset(id: id)?.rect)
            return area.area.frame(for: rect)
        }
        expectExactTiling(frames, of: area.area.rect)
        for frame in frames {
            #expect(isOnPixelGrid(frame, scale: area.area.scale), "\(frame) off the pixel grid")
        }
    }

    @Test("Every move & resize preset except Center is covered by a tiling family")
    func tilingFamiliesCoverAllMoveResizePresets() {
        let covered = Set(Self.moveResizeTilings.flatMap { $0 })
        let expected = Set(PresetLibrary.moveResize.filter { $0.kind == .moveResize }.map(\.id))
        #expect(covered == expected)
    }

    @Test("Halves on 1470x856@2x have the exact expected frames")
    func halvesExactFrames() {
        let a = Fixtures.laptop
        #expect(a.frame(for: PresetLibrary.preset(id: "fill")!.rect!) == CGRect(x: 0, y: 34, width: 1470, height: 856))
        #expect(a.frame(for: PresetLibrary.preset(id: "left-half")!.rect!) == CGRect(x: 0, y: 34, width: 735, height: 856))
        #expect(a.frame(for: PresetLibrary.preset(id: "right-half")!.rect!) == CGRect(x: 735, y: 34, width: 735, height: 856))
        #expect(a.frame(for: PresetLibrary.preset(id: "top-half")!.rect!) == CGRect(x: 0, y: 34, width: 1470, height: 428))
        #expect(a.frame(for: PresetLibrary.preset(id: "bottom-half")!.rect!) == CGRect(x: 0, y: 462, width: 1470, height: 428))
    }

    @Test("Each boundary is rounded on its own (thirds of 2560 pt at 2x)")
    func perBoundaryRounding() {
        // 2560 / 3 = 853.33 → 853.5 (1707 px); 2 · 2560 / 3 = 1706.67 → 1706.5 (3413 px).
        let frames = Fixtures.external.slotFrames(for: PresetLibrary.preset(id: "arrange-3x3")!)
        #expect(frames.map(\.minX).prefix(3) == [0, 853.5, 1706.5])
        #expect(frames[0].width == 853.5)
        #expect(frames[1].width == 853)
        #expect(frames[2].width == 853.5)
        // Rows: 25 + 1415 / 3 = 496.67 → 496.5; 25 + 2 · 1415 / 3 = 968.33 → 968.5.
        #expect([frames[0].minY, frames[3].minY, frames[6].minY] == [25, 496.5, 968.5])
        #expect(frames[8].maxY == 1440)
    }

    // MARK: Gaps

    @Test("Gap 8 pt on halves, with and without screen edges")
    func gapOnHalves() {
        let left = PresetLibrary.preset(id: "left-half")!.rect!
        let right = PresetLibrary.preset(id: "right-half")!.rect!
        let rect = Fixtures.laptop.rect

        let inner = UsableArea(rect: rect, scale: 2, gap: 8, gapAppliesToEdges: false)
        #expect(inner.frame(for: left) == CGRect(x: 0, y: 34, width: 731, height: 856))
        #expect(inner.frame(for: right) == CGRect(x: 739, y: 34, width: 731, height: 856))

        let edges = UsableArea(rect: rect, scale: 2, gap: 8, gapAppliesToEdges: true)
        #expect(edges.frame(for: left) == CGRect(x: 8, y: 42, width: 723, height: 840))
        #expect(edges.frame(for: right) == CGRect(x: 739, y: 42, width: 723, height: 840))
    }

    @Test("Gap halves stay on the pixel grid: 5 pt at 2x is 2.5 + 2.5, 3 pt at 1x is 1 + 2")
    func gapHalvesOnPixelGrid() {
        let slots = PresetLibrary.preset(id: "arrange-2x1")!.slots
        let retina = UsableArea(rect: Fixtures.laptop.rect, scale: 2, gap: 5)
        #expect(retina.frame(for: slots[0]).maxX == 732.5)
        #expect(retina.frame(for: slots[1]).minX == 737.5)

        let plain = UsableArea(rect: Fixtures.laptop.rect, scale: 1, gap: 3)
        #expect(plain.frame(for: slots[0]).maxX == 734)
        #expect(plain.frame(for: slots[1]).minX == 737)
    }

    @Test("Gap math for every arrange preset: outer edges by g only with edges on, interior by g/2 each side",
          arguments: PresetLibrary.arrange.map(\.id), Fixtures.areas)
    func gapMathAllArrangePresets(presetID: String, area: TestArea) throws {
        let preset = try #require(PresetLibrary.preset(id: presetID))
        let rect = area.area.rect
        let scale = area.area.scale
        let base = area.area.slotFrames(for: preset)

        for gap in [1.0, 5.0, 8.0, 13.0] as [CGFloat] {
            for edges in [false, true] {
                let gapped = area.with(gap: gap, edges: edges).slotFrames(for: preset)
                let gapPixels = (gap * scale).rounded()
                let outer = edges ? gapPixels / scale : 0
                let trailing = (gapPixels / 2).rounded(.down) / scale
                let leading = gapPixels / scale - trailing
                if gapPixels.truncatingRemainder(dividingBy: 2) == 0 {
                    #expect(leading == gap / 2 && trailing == gap / 2)
                }

                for (plain, frame) in zip(base, gapped) {
                    #expect(frame.minX == plain.minX + (plain.minX == rect.minX ? outer : leading))
                    #expect(frame.maxX == plain.maxX - (plain.maxX == rect.maxX ? outer : trailing))
                    #expect(frame.minY == plain.minY + (plain.minY == rect.minY ? outer : leading))
                    #expect(frame.maxY == plain.maxY - (plain.maxY == rect.maxY ? outer : trailing))
                    #expect(isOnPixelGrid(frame, scale: scale))
                    #expect(rect.contains(frame))
                }
                // Neighbours (sharing an edge without gap) end up exactly one gap apart.
                for i in base.indices {
                    for j in base.indices where i != j {
                        let verticalOverlap = min(base[i].maxY, base[j].maxY) - max(base[i].minY, base[j].minY)
                        if base[i].maxX == base[j].minX && verticalOverlap > 0 {
                            #expect(gapped[j].minX - gapped[i].maxX == gapPixels / scale)
                        }
                        let horizontalOverlap = min(base[i].maxX, base[j].maxX) - max(base[i].minX, base[j].minX)
                        if base[i].maxY == base[j].minY && horizontalOverlap > 0 {
                            #expect(gapped[j].minY - gapped[i].maxY == gapPixels / scale)
                        }
                        #expect(overlapArea(gapped[i], gapped[j]) == 0)
                    }
                }
            }
        }
    }

    // MARK: Usable area and Stage Manager

    @Test("-sm variants leave the Stage Manager inset free on the left; full-width presets use the whole visibleFrame")
    func stageManagerInset() {
        let visible = CGRect(x: 0, y: 34, width: 1470, height: 856)
        let leftHalf = PresetLibrary.preset(id: "left-half")!
        let leftHalfSM = PresetLibrary.preset(id: "left-half-sm")!

        let full = UsableArea(visibleFrame: visible, scale: 2, preset: leftHalf, stageManagerInset: 72)
        #expect(full.rect == visible)
        #expect(full.frame(for: leftHalf.rect!) == CGRect(x: 0, y: 34, width: 735, height: 856))

        let sm = UsableArea(visibleFrame: visible, scale: 2, preset: leftHalfSM, stageManagerInset: 72)
        #expect(sm.rect == CGRect(x: 72, y: 34, width: 1398, height: 856))
        #expect(sm.frame(for: leftHalfSM.rect!) == CGRect(x: 72, y: 34, width: 699, height: 856))

        #expect(UsableArea(visibleFrame: visible, scale: 2, preset: leftHalfSM, stageManagerInset: 100).rect
                == CGRect(x: 100, y: 34, width: 1370, height: 856))
        // Gap is always 0 (SPEC §1 "No gaps").
        #expect(sm.gap == 0 && !sm.gapAppliesToEdges)
    }

    static let visibleFrames: [TestArea] = [
        TestArea(name: "1470x856@2x", area: Fixtures.laptop),
        TestArea(name: "2560x1415@2x offset", area: Fixtures.externalOffset),
        TestArea(name: "1470x856@1x", area: Fixtures.laptop1x),
    ]

    /// Asserts that frames of unit-adjacent slots share their edge exactly (windows touch).
    static func expectSharedEdges(_ units: [UnitRect], _ frames: [CGRect], sourceLocation: SourceLocation = #_sourceLocation) {
        for i in units.indices {
            for j in units.indices where i != j {
                let verticalOverlap = min(units[i].maxY, units[j].maxY) - max(units[i].minY, units[j].minY)
                if units[i].maxX == units[j].minX && verticalOverlap > 0 {
                    #expect(frames[i].maxX == frames[j].minX, "\(frames[i]) / \(frames[j])", sourceLocation: sourceLocation)
                }
                let horizontalOverlap = min(units[i].maxX, units[j].maxX) - max(units[i].minX, units[j].minX)
                if units[i].maxY == units[j].minY && horizontalOverlap > 0 {
                    #expect(frames[i].maxY == frames[j].minY, "\(frames[i]) / \(frames[j])", sourceLocation: sourceLocation)
                }
            }
        }
    }

    @Test("Every -sm arrange preset: slots touch exactly and cover exactly [minX + inset, maxX] × full height",
          arguments: PresetLibrary.arrangeStageManager.map(\.id), visibleFrames)
    func stageManagerArrangeCoverage(presetID: String, visible: TestArea) throws {
        let preset = try #require(PresetLibrary.preset(id: presetID))
        let v = visible.area.rect
        for inset in [72.0, 100.0, 37.5] {
            let area = UsableArea(visibleFrame: v, scale: visible.area.scale, preset: preset, stageManagerInset: inset)
            // A fractional inset is rounded to device pixels (37.5 → 38 at @1x).
            let pixelInset = Geometry.snap(CGFloat(inset), scale: visible.area.scale)
            let covered = CGRect(x: v.minX + pixelInset, y: v.minY, width: v.width - pixelInset, height: v.height)
            #expect(area.rect == covered)
            let frames = area.slotFrames(for: preset)
            expectExactTiling(frames, of: covered)
            Self.expectSharedEdges(preset.slots, frames)
            #expect(frames.map(\.minX).min() == covered.minX && frames.map(\.maxX).max() == covered.maxX)
            #expect(frames.map(\.minY).min() == covered.minY && frames.map(\.maxY).max() == covered.maxY)
            for frame in frames {
                #expect(isOnPixelGrid(frame, scale: visible.area.scale))
            }
        }
    }

    @Test("-sm move & resize families tile [minX + inset, maxX] × full height; full-width ones the whole visibleFrame",
          arguments: moveResizeTilings, visibleFrames)
    func widthVariantFamilies(ids: [String], visible: TestArea) throws {
        let v = visible.area.rect
        for stageManager in [false, true] {
            let presets = try ids.map { try #require(PresetLibrary.preset(id: stageManager ? $0 + "-sm" : $0)) }
            let inset: CGFloat = stageManager ? 72 : 0
            let covered = CGRect(x: v.minX + inset, y: v.minY, width: v.width - inset, height: v.height)
            let frames = presets.map { preset in
                UsableArea(visibleFrame: v, scale: visible.area.scale, preset: preset, stageManagerInset: 72)
                    .frame(for: preset.rect!)
            }
            expectExactTiling(frames, of: covered)
            Self.expectSharedEdges(presets.map { $0.rect! }, frames)
        }
    }

    // MARK: Center

    @Test("Center keeps the size and centers on the usable area, snapped to the pixel grid")
    func centerPreset() {
        #expect(Fixtures.laptop.centeredFrame(size: CGSize(width: 800, height: 600))
                == CGRect(x: 335, y: 162, width: 800, height: 600))
        #expect(Fixtures.laptop.centeredFrame(size: CGSize(width: 801, height: 601))
                == CGRect(x: 334.5, y: 161.5, width: 801, height: 601))
        #expect(Fixtures.laptop1x.centeredFrame(size: CGSize(width: 801, height: 601))
                == CGRect(x: 335, y: 162, width: 801, height: 601))
        // Stage Manager area: centered on x 72…1470.
        #expect(Fixtures.laptopStageManager.centeredFrame(size: CGSize(width: 800, height: 600)).minX == 371)
        // Larger than the area: aligned to the leading edges.
        #expect(Fixtures.laptop.centeredFrame(size: CGSize(width: 2000, height: 1000))
                == CGRect(x: 0, y: 34, width: 2000, height: 1000))
    }
}
