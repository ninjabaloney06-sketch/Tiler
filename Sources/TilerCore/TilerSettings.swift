/// User settings with the SPEC §1 / §4 defaults. Plain value type; persisted inside `TilerConfig`.
///
/// Decoding is lenient: a missing or mistyped key takes its default, numeric values are clamped
/// to their ranges and unknown keys are ignored — including the removed `gap`,
/// `gapAppliesToScreenEdges` and `leaveRoomForStageManager` of older config files — so a
/// hand-edited or old file never breaks the app. Old files without the trigger keys get the
/// ⌃⌥T hotkey and the hover trigger off.
public struct TilerSettings: Hashable, Sendable, Codable {
    /// Global hotkey that toggles the palette (SPEC §4.B); nil = cleared by the user (no hotkey).
    /// Persisted as `{"keyCode", "modifiers"}` or `null`; a missing or malformed value is ⌃⌥T.
    public var paletteHotkey: Hotkey?
    /// Also show the palette when hovering a window's green button (SPEC §4.C). Opt-in.
    public var hoverTriggerEnabled: Bool
    /// Seconds between hovering the green button and the palette fading in (hover trigger only).
    public var hoverDelay: Double
    /// Palette scale factor; 1.0 = reference icon metrics (SPEC §4).
    public var paletteSize: Double
    /// Width of the Stage Manager strip that `-sm` presets leave free on the left, in points.
    public var stageManagerInset: Double
    /// Hover trigger mode inverted: when true the macOS menu shows by default and ⌘ held at
    /// hover shows the Tiler palette. False (default) = Tiler palette, ⌘ = macOS menu.
    public var showMacOSMenuByDefault: Bool
    /// Kept only so old and hand-edited config files decode; nothing reads or writes it. Whether
    /// Tiler launches at login lives in `SMAppService.mainApp.status` (`LoginItem`, shown and
    /// switched by the Settings toggle), never in the config file.
    public var launchAtLogin: Bool

    public static let hoverDelayRange: ClosedRange<Double> = 0...1
    /// SPEC §10.1: 0.8–2.0 (was 0.6–2.0); old configs below 0.8 clamp up (decoding below).
    public static let paletteSizeRange: ClosedRange<Double> = 0.8...2.0
    /// Not fixed by the SPEC; bounds for the editor's field and for decoding.
    public static let stageManagerInsetRange: ClosedRange<Double> = 0...400

    public init(
        paletteHotkey: Hotkey? = .defaultPalette,
        hoverTriggerEnabled: Bool = false,
        hoverDelay: Double = 0.15,
        paletteSize: Double = 1.0,
        stageManagerInset: Double = 72,
        showMacOSMenuByDefault: Bool = false,
        launchAtLogin: Bool = false
    ) {
        self.paletteHotkey = paletteHotkey
        self.hoverTriggerEnabled = hoverTriggerEnabled
        self.hoverDelay = hoverDelay
        self.paletteSize = paletteSize
        self.stageManagerInset = stageManagerInset
        self.showMacOSMenuByDefault = showMacOSMenuByDefault
        self.launchAtLogin = launchAtLogin
    }

    public static let `default` = TilerSettings()

    // MARK: Codable (lenient decoding; a cleared hotkey is written as null, not omitted)

    private enum CodingKeys: String, CodingKey {
        case paletteHotkey, hoverTriggerEnabled, hoverDelay, paletteSize, stageManagerInset,
             showMacOSMenuByDefault, launchAtLogin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TilerSettings.default
        func number(_ key: CodingKeys, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
            return min(max(value, range.lowerBound), range.upperBound)
        }
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        let hotkey: Hotkey?
        if (try? c.decodeNil(forKey: .paletteHotkey)) == true {
            hotkey = nil
        } else {
            hotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .paletteHotkey)) ?? d.paletteHotkey
        }
        self.init(
            paletteHotkey: hotkey,
            hoverTriggerEnabled: flag(.hoverTriggerEnabled, d.hoverTriggerEnabled),
            hoverDelay: number(.hoverDelay, d.hoverDelay, Self.hoverDelayRange),
            paletteSize: number(.paletteSize, d.paletteSize, Self.paletteSizeRange),
            stageManagerInset: number(.stageManagerInset, d.stageManagerInset, Self.stageManagerInsetRange),
            showMacOSMenuByDefault: flag(.showMacOSMenuByDefault, d.showMacOSMenuByDefault),
            launchAtLogin: flag(.launchAtLogin, d.launchAtLogin))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let paletteHotkey {
            try c.encode(paletteHotkey, forKey: .paletteHotkey)
        } else {
            try c.encodeNil(forKey: .paletteHotkey)
        }
        try c.encode(hoverTriggerEnabled, forKey: .hoverTriggerEnabled)
        try c.encode(hoverDelay, forKey: .hoverDelay)
        try c.encode(paletteSize, forKey: .paletteSize)
        try c.encode(stageManagerInset, forKey: .stageManagerInset)
        try c.encode(showMacOSMenuByDefault, forKey: .showMacOSMenuByDefault)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
    }
}
