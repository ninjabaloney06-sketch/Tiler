import Foundation
import Testing
@testable import TilerCore

@Suite("PresetLibrary")
struct PresetLibraryTests {
    @Test("All 15 move & resize presets (incl. Center) exist with stable ids, in SPEC order")
    func moveResizePresets() {
        #expect(PresetLibrary.moveResize.map(\.id) == [
            "fill", "left-half", "right-half", "top-half", "bottom-half", "center",
            "top-left-quarter", "top-right-quarter", "bottom-left-quarter", "bottom-right-quarter",
            "left-third", "middle-third", "right-third", "left-two-thirds", "right-two-thirds",
        ])
        let center = PresetLibrary.preset(id: "center")
        #expect(center?.kind == .center)
        #expect(center?.rects.isEmpty == true)
        #expect(PresetLibrary.moveResize.filter { $0.id != "center" }.allSatisfy { $0.kind == .moveResize && $0.rect != nil })
    }

    @Test("All 13 arrange presets exist with the right slot counts")
    func arrangePresets() {
        let expected: [(String, Int)] = [
            ("arrange-2x1", 2), ("arrange-1x2", 2), ("arrange-2x2", 4), ("arrange-3x2", 6),
            ("arrange-3x3", 9), ("arrange-4x3", 12), ("arrange-4x4", 16),
            ("arrange-1+3", 4), ("arrange-2+3", 5),
            ("arrange-1+4-grid", 5), ("arrange-1+4-rows", 5),
            ("arrange-2+4-grid", 6), ("arrange-2+4-rows", 6),
        ]
        #expect(PresetLibrary.arrange.map(\.id) == expected.map(\.0))
        for (id, count) in expected {
            let preset = PresetLibrary.preset(id: id)
            #expect(preset?.kind == .arrange)
            #expect(preset?.slots.count == count, "\(id)")
        }
    }

    @Test("Grid presets are named columns × rows")
    func gridShapes() {
        for (id, columns, rows) in [("arrange-2x1", 2, 1), ("arrange-1x2", 1, 2), ("arrange-2x2", 2, 2),
                                    ("arrange-3x2", 3, 2), ("arrange-3x3", 3, 3), ("arrange-4x3", 4, 3),
                                    ("arrange-4x4", 4, 4)] {
            let slots = PresetLibrary.preset(id: id)!.slots
            #expect(Set(slots.map(\.minX)).count == columns, "\(id)")
            #expect(Set(slots.map(\.minY)).count == rows, "\(id)")
            #expect(slots.first == UnitRect(minX: 0, minY: 0, maxX: 1 / Double(columns), maxY: 1 / Double(rows)))
        }
    }

    @Test("Split layouts: 50 % left column, then the right side as named")
    func splitShapes() {
        // (id, left rows, right columns, right rows)
        for (id, leftRows, rightColumns, rightRows) in [
            ("arrange-1+3", 1, 1, 3), ("arrange-2+3", 2, 1, 3),
            ("arrange-1+4-grid", 1, 2, 2), ("arrange-1+4-rows", 1, 1, 4),
            ("arrange-2+4-grid", 2, 2, 2), ("arrange-2+4-rows", 2, 1, 4),
        ] {
            let slots = PresetLibrary.preset(id: id)!.slots
            let left = slots.filter { $0.maxX <= 0.5 }
            let right = slots.filter { $0.minX >= 0.5 }
            #expect(left.count == leftRows, "\(id)")
            #expect(left.allSatisfy { $0.minX == 0 && $0.maxX == 0.5 }, "\(id)")
            #expect(right.count == rightColumns * rightRows, "\(id)")
            #expect(Set(right.map(\.minX)).count == rightColumns, "\(id)")
            #expect(Set(right.map(\.minY)).count == rightRows, "\(id)")
            #expect(Array(slots.prefix(leftRows)) == left, "left column listed first in \(id)")
        }
    }

    @Test("Ids and names are unique; lookup works; unknown ids return nil")
    func idsAndLookup() {
        #expect(PresetLibrary.all.count == 56)
        #expect(Set(PresetLibrary.all.map(\.id)).count == 56)
        #expect(Set(PresetLibrary.all.map(\.name)).count == 56)
        #expect(PresetLibrary.all.allSatisfy { !$0.name.isEmpty })
        for preset in PresetLibrary.all {
            #expect(PresetLibrary.preset(id: preset.id) == preset)
        }
        #expect(PresetLibrary.preset(id: "nope") == nil)
    }

    @Test("Every preset has a Stage Manager variant: <id>-sm, <Name> · Stage Manager, same kind and rects")
    func stageManagerVariants() {
        let full = PresetLibrary.moveResize + PresetLibrary.arrange
        let variants = PresetLibrary.moveResizeStageManager + PresetLibrary.arrangeStageManager
        #expect(PresetLibrary.all == full + variants)
        #expect(variants.count == full.count)
        for (base, variant) in zip(full, variants) {
            #expect(!base.isStageManagerVariant)
            #expect(variant.isStageManagerVariant)
            #expect(variant.id == base.id + "-sm")
            #expect(variant.name == base.name + " · Stage Manager")
            #expect(variant.kind == base.kind && variant.rects == base.rects)
            #expect(PresetLibrary.preset(id: variant.id) == variant)
            #expect(PresetLibrary.variant(of: base, stageManager: true) == variant)
            #expect(PresetLibrary.variant(of: variant, stageManager: false) == base)
            #expect(PresetLibrary.variant(of: base, stageManager: false) == base)
            #expect(PresetLibrary.variant(of: variant, stageManager: true) == variant)
        }
        #expect(PresetLibrary.preset(id: "left-half-sm")?.name == "Left half · Stage Manager")
        #expect(PresetLibrary.variant(of: .center(id: "custom", name: "Custom"), stageManager: true) == nil)
        // Default wells keep the full-width presets.
        #expect(PaletteLayout.default.wells.values.allSatisfy { !$0.hasSuffix("-sm") })
    }

    @Test("Every preset rect is valid unit space")
    func rectsValid() {
        #expect(PresetLibrary.all.allSatisfy { $0.rects.allSatisfy(\.isValid) })
    }

    @Test("Presets round-trip through JSON; mismatched rects are rejected")
    func codable() throws {
        let data = try JSONEncoder().encode(PresetLibrary.all)
        #expect(try JSONDecoder().decode([Preset].self, from: data) == PresetLibrary.all)

        // Presets encoded before the width variants existed decode as full width.
        let legacy = """
        {"id": "x", "name": "X", "kind": "moveResize", "rects": [{"minX": 0, "minY": 0, "maxX": 0.5, "maxY": 1}]}
        """
        #expect(try JSONDecoder().decode(Preset.self, from: Data(legacy.utf8)).isStageManagerVariant == false)

        let bad = """
        {"id": "x", "name": "X", "kind": "moveResize", "rects": []}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Preset.self, from: Data(bad.utf8))
        }
        let outOfRange = """
        {"id": "x", "name": "X", "kind": "arrange", "rects": [{"minX": 0, "minY": 0, "maxX": 1.5, "maxY": 1}]}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Preset.self, from: Data(outOfRange.utf8))
        }
    }
}
