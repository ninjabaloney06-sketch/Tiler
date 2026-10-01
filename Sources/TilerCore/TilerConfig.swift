/// Everything persisted in `config.json` (SPEC §2):
///
///     { "version": 1, "settings": { … }, "palette": [ { "id": "fill", "row": 2, "column": 3 }, … ] }
///
/// A missing `settings` or `palette` key falls back to its default; a `version` other than 1
/// makes decoding fail (the store then uses defaults). A missing `version` is read as 1.
public struct TilerConfig: Hashable, Sendable, Codable {
    public static let currentVersion = 1

    public var settings: TilerSettings
    public var palette: PaletteLayout

    public init(settings: TilerSettings = .default, palette: PaletteLayout = .default) {
        self.settings = settings
        self.palette = palette
    }

    public static let `default` = TilerConfig()

    public struct UnsupportedVersion: Error, CustomStringConvertible {
        public let version: Int
        public var description: String { "unsupported config version \(version)" }
    }

    private enum CodingKeys: String, CodingKey {
        case version, settings, palette
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        guard version == Self.currentVersion else { throw UnsupportedVersion(version: version) }
        settings = (try? c.decodeIfPresent(TilerSettings.self, forKey: .settings)) ?? .default
        palette = (try? c.decodeIfPresent(PaletteLayout.self, forKey: .palette)) ?? .default
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(settings, forKey: .settings)
        try c.encode(palette, forKey: .palette)
    }
}
