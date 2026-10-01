/// One palette action (SPEC §1). Presets are immutable values identified by a stable string `id`
/// that is what the config file stores. Icons are derived from `rects` (see `IconGeometry`).
///
/// Every preset exists in two width variants (SPEC §1 "Width variants"): full width (the whole
/// `visibleFrame`) and a Stage Manager variant (`id` + `-sm`, name + ` · Stage Manager`) whose
/// layout is scaled into the `visibleFrame` minus the Stage Manager inset on the left.
public struct Preset: Hashable, Sendable, Identifiable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        /// Moves and resizes the hovered window to `rect`.
        case moveResize
        /// Keeps the hovered window's size and centers it on the usable area.
        case center
        /// Arranges all visible windows on the hovered window's screen into `slots`.
        case arrange
    }

    /// Stable identifier, e.g. `"left-half"` or `"arrange-3x2"`. Never rename a shipped id.
    public let id: String
    /// Human-readable name, used for tooltips and the editor library.
    public let name: String
    public let kind: Kind
    /// Target regions in unit space: exactly one for `.moveResize`, none for `.center`, one per
    /// slot (at least one) for `.arrange`. Arrange slots are ordered row-major from the top-left;
    /// split layouts list the left column first.
    public let rects: [UnitRect]
    /// True for the `-sm` width variant: the usable area leaves the Stage Manager inset free on
    /// the left (see `UsableArea.init(visibleFrame:scale:preset:stageManagerInset:)`).
    public let isStageManagerVariant: Bool

    private init(id: String, name: String, kind: Kind, rects: [UnitRect], isStageManagerVariant: Bool = false) {
        precondition(Self.isValid(kind: kind, rects: rects), "invalid rects for preset \(id)")
        self.id = id
        self.name = name
        self.kind = kind
        self.rects = rects
        self.isStageManagerVariant = isStageManagerVariant
    }

    public static func moveResize(id: String, name: String, rect: UnitRect) -> Preset {
        Preset(id: id, name: name, kind: .moveResize, rects: [rect])
    }

    public static func center(id: String, name: String) -> Preset {
        Preset(id: id, name: name, kind: .center, rects: [])
    }

    public static func arrange(id: String, name: String, slots: [UnitRect]) -> Preset {
        Preset(id: id, name: name, kind: .arrange, rects: slots)
    }

    /// Suffix of Stage Manager variant ids (`"left-half"` → `"left-half-sm"`).
    public static let stageManagerIDSuffix = "-sm"
    /// Suffix of Stage Manager variant names (`"Left half"` → `"Left half · Stage Manager"`).
    public static let stageManagerNameSuffix = " · Stage Manager"

    /// The Stage Manager width variant of this full-width preset: same kind and rects,
    /// id + `-sm`, name + ` · Stage Manager`.
    public func stageManagerVariant() -> Preset {
        precondition(!isStageManagerVariant, "\(id) already is a Stage Manager variant")
        return Preset(id: id + Self.stageManagerIDSuffix, name: name + Self.stageManagerNameSuffix,
                      kind: kind, rects: rects, isStageManagerVariant: true)
    }

    /// The target rect of a `.moveResize` preset, otherwise nil.
    public var rect: UnitRect? { kind == .moveResize ? rects.first : nil }

    /// The slots of an `.arrange` preset, otherwise empty.
    public var slots: [UnitRect] { kind == .arrange ? rects : [] }

    static func isValid(kind: Kind, rects: [UnitRect]) -> Bool {
        guard rects.allSatisfy(\.isValid) else { return false }
        switch kind {
        case .moveResize: return rects.count == 1
        case .center: return rects.isEmpty
        case .arrange: return !rects.isEmpty
        }
    }

    // MARK: Codable (synthesized encoding, validated decoding)

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, rects, isStageManagerVariant
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let rects = try container.decode([UnitRect].self, forKey: .rects)
        guard Self.isValid(kind: kind, rects: rects) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rects, in: container,
                debugDescription: "rects do not match preset kind \(kind.rawValue)")
        }
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: kind,
            rects: rects,
            isStageManagerVariant: try container.decodeIfPresent(Bool.self, forKey: .isStageManagerVariant) ?? false)
    }
}
