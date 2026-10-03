/// Everything persisted in `config.json` (SPEC §2):
///
///     { "version": 1, "settings": { … }, "palette": [ { "id": "fill", "row": 2, "column": 3 }, … ] }
///
/// A missing `settings` or `palette` key falls back to its default; a `version` other than 1
/// makes decoding fail (the store then uses defaults). A missing `version` is read as 1.
///
/// `paletteRevision` (written as 2) marks a palette saved since Revert became a well item; an
/// older palette (key missing) gets Revert placed once on load (`placeRevertIfMissing`), so a
/// Revert the user later drags out stays removed.
public struct TilerConfig: Hashable, Sendable, Codable {
    public static let currentVersion = 1
    /// 2: Revert is a well item (SPEC §2).
    public static let currentPaletteRevision = 2

    public var settings: TilerSettings
    public var palette: PaletteLayout

    public init(settings: TilerSettings = .default, palette: PaletteLayout = .defaultWithRevert) {
        self.settings = settings
        self.palette = palette
    }

    public static let `default` = TilerConfig()

    public struct UnsupportedVersion: Error, CustomStringConvertible {
        public let version: Int
        public var description: String { "unsupported config version \(version)" }
    }

    private enum CodingKeys: String, CodingKey {
        case version, settings, palette, paletteRevision
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        guard version == Self.currentVersion else { throw UnsupportedVersion(version: version) }
        settings = (try? c.decodeIfPresent(TilerSettings.self, forKey: .settings)) ?? .default
        palette = (try? c.decodeIfPresent(PaletteLayout.self, forKey: .palette)) ?? .defaultWithRevert
        let revision = (try? c.decodeIfPresent(Int.self, forKey: .paletteRevision)) ?? 1
        if revision < Self.currentPaletteRevision { palette.placeRevertIfMissing() }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(settings, forKey: .settings)
        try c.encode(palette, forKey: .palette)
        try c.encode(Self.currentPaletteRevision, forKey: .paletteRevision)
    }
}

extension PaletteLayout {
    /// The default palette (`default`) with Revert placed left of its top row (SPEC §2).
    public static let defaultWithRevert: PaletteLayout = {
        var layout = PaletteLayout.default
        layout.placeRevertIfMissing()
        return layout
    }()
}
