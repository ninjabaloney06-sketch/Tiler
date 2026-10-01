/// Every preset from SPEC §1, in SPEC order, in both width variants. The editor library shows
/// `moveResize` / `moveResizeStageManager` under "Move & Resize" and `arrange` /
/// `arrangeStageManager` under "Arrange".
public enum PresetLibrary {
    /// The 15 full-width single-window presets (14 move & resize + Center).
    public static let moveResize: [Preset] = {
        let x = UnitRect.split(0, 1, into: 3) // [0, 1/3, 2/3, 1]
        func rect(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> UnitRect {
            UnitRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }
        return [
            .moveResize(id: "fill", name: "Fill", rect: .full),
            .moveResize(id: "left-half", name: "Left half", rect: rect(0, 0, 0.5, 1)),
            .moveResize(id: "right-half", name: "Right half", rect: rect(0.5, 0, 1, 1)),
            .moveResize(id: "top-half", name: "Top half", rect: rect(0, 0, 1, 0.5)),
            .moveResize(id: "bottom-half", name: "Bottom half", rect: rect(0, 0.5, 1, 1)),
            .center(id: "center", name: "Center"),
            .moveResize(id: "top-left-quarter", name: "Top-left quarter", rect: rect(0, 0, 0.5, 0.5)),
            .moveResize(id: "top-right-quarter", name: "Top-right quarter", rect: rect(0.5, 0, 1, 0.5)),
            .moveResize(id: "bottom-left-quarter", name: "Bottom-left quarter", rect: rect(0, 0.5, 0.5, 1)),
            .moveResize(id: "bottom-right-quarter", name: "Bottom-right quarter", rect: rect(0.5, 0.5, 1, 1)),
            .moveResize(id: "left-third", name: "Left third", rect: rect(x[0], 0, x[1], 1)),
            .moveResize(id: "middle-third", name: "Middle third", rect: rect(x[1], 0, x[2], 1)),
            .moveResize(id: "right-third", name: "Right third", rect: rect(x[2], 0, x[3], 1)),
            .moveResize(id: "left-two-thirds", name: "Left two-thirds", rect: rect(x[0], 0, x[2], 1)),
            .moveResize(id: "right-two-thirds", name: "Right two-thirds", rect: rect(x[1], 0, x[3], 1)),
        ]
    }()

    /// The 13 full-width arrange presets: 7 grids (named columns × rows) and 6 split layouts
    /// whose left column is 50 % wide.
    public static let arrange: [Preset] = {
        func grid(_ columns: Int, _ rows: Int, name: String) -> Preset {
            .arrange(id: "arrange-\(columns)x\(rows)", name: name,
                     slots: UnitRect.full.grid(columns: columns, rows: rows))
        }
        let leftColumn = UnitRect(minX: 0, minY: 0, maxX: 0.5, maxY: 1)
        let rightColumn = UnitRect(minX: 0.5, minY: 0, maxX: 1, maxY: 1)
        func split(_ id: String, name: String, leftRows: Int, rightColumns: Int, rightRows: Int) -> Preset {
            .arrange(id: id, name: name,
                     slots: leftColumn.grid(columns: 1, rows: leftRows)
                         + rightColumn.grid(columns: rightColumns, rows: rightRows))
        }
        return [
            grid(2, 1, name: "Left & Right (2x1)"),
            grid(1, 2, name: "Top & Bottom (1x2)"),
            grid(2, 2, name: "Quarters (2x2)"),
            grid(3, 2, name: "3x2"),
            grid(3, 3, name: "3x3"),
            grid(4, 3, name: "4x3"),
            grid(4, 4, name: "4x4"),
            split("arrange-1+3", name: "1+3", leftRows: 1, rightColumns: 1, rightRows: 3),
            split("arrange-2+3", name: "2+3", leftRows: 2, rightColumns: 1, rightRows: 3),
            split("arrange-1+4-grid", name: "1+4 (grid)", leftRows: 1, rightColumns: 2, rightRows: 2),
            split("arrange-1+4-rows", name: "1+4 (rows)", leftRows: 1, rightColumns: 1, rightRows: 4),
            split("arrange-2+4-grid", name: "2+4 (grid)", leftRows: 2, rightColumns: 2, rightRows: 2),
            split("arrange-2+4-rows", name: "2+4 (rows)", leftRows: 2, rightColumns: 1, rightRows: 4),
        ]
    }()

    /// Stage Manager variants of `moveResize`, same order (`<id>-sm`).
    public static let moveResizeStageManager: [Preset] = moveResize.map { $0.stageManagerVariant() }

    /// Stage Manager variants of `arrange`, same order (`<id>-sm`).
    public static let arrangeStageManager: [Preset] = arrange.map { $0.stageManagerVariant() }

    /// All 56 presets: the 28 full-width ones (`moveResize` + `arrange`), then their 28 Stage
    /// Manager variants in the same order.
    public static let all: [Preset] = moveResize + arrange + moveResizeStageManager + arrangeStageManager

    /// The preset with this id, or nil for an unknown id.
    public static func preset(id: String) -> Preset? { byID[id] }

    /// The full-width (`stageManager == false`) or Stage Manager variant of a library preset;
    /// nil for a preset that is not in the library.
    public static func variant(of preset: Preset, stageManager: Bool) -> Preset? {
        guard preset.isStageManagerVariant != stageManager else { return byID[preset.id] }
        let id = stageManager
            ? preset.id + Preset.stageManagerIDSuffix
            : String(preset.id.dropLast(Preset.stageManagerIDSuffix.count))
        return byID[id]
    }

    private static let byID: [String: Preset] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
