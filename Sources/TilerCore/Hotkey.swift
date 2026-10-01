/// A global keyboard shortcut in Carbon terms, ready for `RegisterEventHotKey(keyCode,
/// modifiers, …)` (SPEC §4.B). TilerCore does not import Carbon; the constants below carry the
/// same values as `kVK_*` and `cmdKey` / `shiftKey` / `optionKey` / `controlKey` (checked
/// against the SDK in the tests).
public struct Hotkey: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Virtual key code (`kVK_*`), i.e. a physical key position.
    public var keyCode: UInt32
    /// Carbon modifier flags: any combination of `command`, `shift`, `option`, `control`.
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon modifier flags (Events.h).
    public static let command: UInt32 = 1 << 8   // cmdKey
    public static let shift: UInt32 = 1 << 9     // shiftKey
    public static let option: UInt32 = 1 << 11   // optionKey
    public static let control: UInt32 = 1 << 12  // controlKey
    public static let allModifiers: UInt32 = command | shift | option | control

    /// `kVK_ANSI_T`.
    public static let keyCodeT: UInt32 = 0x11

    /// ⌃⌥T — the default palette hotkey.
    public static let defaultPalette = Hotkey(keyCode: keyCodeT, modifiers: control | option)

    /// Modifier symbols in Apple's menu order ⌃⌥⇧⌘, e.g. "⌃⌥".
    public var modifierSymbols: String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }
            .map(\.1)
            .joined()
    }

    /// Name of the key on a US (ANSI) layout: "T", "5", "Space", "↩", "F1", "Keypad 7"; unknown
    /// codes read "Key <code>". The app may substitute the current layout's character.
    public var keyName: String {
        Self.keyNames[keyCode] ?? "Key \(keyCode)"
    }

    /// Human-readable shortcut, e.g. "⌃⌥T".
    public var description: String {
        modifierSymbols + keyName
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    /// Virtual key codes are 7-bit. Modifier bits other than ⌘⇧⌥⌃ are dropped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try c.decode(UInt32.self, forKey: .keyCode)
        guard keyCode <= 0x7F else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyCode, in: c, debugDescription: "virtual key code \(keyCode) out of range")
        }
        self.init(keyCode: keyCode, modifiers: try c.decode(UInt32.self, forKey: .modifiers) & Self.allModifiers)
    }

    // MARK: Key names (kVK_* → US label)

    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
            0x08: "C", 0x09: "V", 0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
            0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
            0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O",
            0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'",
            0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
            0x30: "⇥", 0x31: "Space", 0x32: "`", 0x33: "⌫", 0x35: "⎋",
            0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x47: "Keypad Clear",
            0x4B: "Keypad /", 0x4C: "Keypad Enter", 0x4E: "Keypad -", 0x51: "Keypad =",
            0x72: "Help", 0x73: "↖", 0x74: "⇞", 0x75: "⌦", 0x77: "↘", 0x79: "⇟",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        ]
        let keypadDigits: [UInt32] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
        for (digit, code) in keypadDigits.enumerated() {
            names[code] = "Keypad \(digit)"
        }
        let functionKeys: [UInt32] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for (index, code) in functionKeys.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()
}
