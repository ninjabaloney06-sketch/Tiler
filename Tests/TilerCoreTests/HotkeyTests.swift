import Carbon.HIToolbox
import Foundation
import Testing
@testable import TilerCore

@Suite("Hotkey")
struct HotkeyTests {
    @Test("Modifier flags and key codes carry the Carbon values")
    func carbonValues() {
        #expect(Hotkey.command == UInt32(cmdKey))
        #expect(Hotkey.shift == UInt32(shiftKey))
        #expect(Hotkey.option == UInt32(optionKey))
        #expect(Hotkey.control == UInt32(controlKey))
        #expect(Hotkey.keyCodeT == UInt32(kVK_ANSI_T))
        #expect(Hotkey.keyCodeT == 0x11)
    }

    @Test("Default palette hotkey is ⌃⌥T")
    func defaultPalette() {
        let hotkey = Hotkey.defaultPalette
        #expect(hotkey.keyCode == UInt32(kVK_ANSI_T))
        #expect(hotkey.modifiers == UInt32(controlKey | optionKey))
        #expect(hotkey.description == "⌃⌥T")
        #expect("\(hotkey)" == "⌃⌥T")
    }

    @Test("Modifier symbols follow Apple's menu order ⌃⌥⇧⌘")
    func modifierOrder() {
        let all = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.description == "⌃⌥⇧⌘A")
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)).description == "⇧⌘4")
        #expect(Hotkey(keyCode: UInt32(kVK_F5), modifiers: 0).description == "F5")
        #expect(Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)).description == "⌥Space")
    }

    /// Every table entry, checked against the SDK's kVK_* constants.
    static let expectedNames: [(Int, String)] = [
        (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
        (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
        (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
        (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
        (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
        (kVK_ANSI_Z, "Z"),
        (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
        (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        (kVK_ANSI_Equal, "="), (kVK_ANSI_Minus, "-"), (kVK_ANSI_RightBracket, "]"),
        (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Semicolon, ";"),
        (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Slash, "/"),
        (kVK_ANSI_Period, "."), (kVK_ANSI_Grave, "`"), (kVK_ISO_Section, "§"),
        (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Space, "Space"), (kVK_Delete, "⌫"),
        (kVK_Escape, "⎋"), (kVK_ForwardDelete, "⌦"), (kVK_Help, "Help"), (kVK_Home, "↖"),
        (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"),
        (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_DownArrow, "↓"), (kVK_UpArrow, "↑"),
        (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"),
        (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"),
        (kVK_F11, "F11"), (kVK_F12, "F12"), (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"),
        (kVK_F16, "F16"), (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
        (kVK_ANSI_Keypad0, "Keypad 0"), (kVK_ANSI_Keypad1, "Keypad 1"), (kVK_ANSI_Keypad2, "Keypad 2"),
        (kVK_ANSI_Keypad3, "Keypad 3"), (kVK_ANSI_Keypad4, "Keypad 4"), (kVK_ANSI_Keypad5, "Keypad 5"),
        (kVK_ANSI_Keypad6, "Keypad 6"), (kVK_ANSI_Keypad7, "Keypad 7"), (kVK_ANSI_Keypad8, "Keypad 8"),
        (kVK_ANSI_Keypad9, "Keypad 9"), (kVK_ANSI_KeypadDecimal, "Keypad ."),
        (kVK_ANSI_KeypadMultiply, "Keypad *"), (kVK_ANSI_KeypadPlus, "Keypad +"),
        (kVK_ANSI_KeypadClear, "Keypad Clear"), (kVK_ANSI_KeypadDivide, "Keypad /"),
        (kVK_ANSI_KeypadEnter, "Keypad Enter"), (kVK_ANSI_KeypadMinus, "Keypad -"),
        (kVK_ANSI_KeypadEquals, "Keypad ="),
    ]

    @Test("Key names match the kVK_* constants; the table has no other entries")
    func keyNames() {
        for (code, name) in Self.expectedNames {
            #expect(Hotkey(keyCode: UInt32(code), modifiers: 0).keyName == name, "kVK \(code)")
        }
        #expect(Set(Self.expectedNames.map { UInt32($0.0) }) == Set(Hotkey.keyNames.keys))
        #expect(Self.expectedNames.count == Hotkey.keyNames.count)
    }

    @Test("Codes without a name (modifier keys) read \"Key <code>\"")
    func unknownKey() {
        #expect(Hotkey(keyCode: UInt32(kVK_Function), modifiers: UInt32(controlKey)).description == "⌃Key 63")
    }

    @Test("JSON round-trip; unknown modifier bits dropped; out-of-range key codes rejected")
    func codable() throws {
        let hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey))
        let data = try JSONEncoder().encode(hotkey)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == hotkey)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["keyCode"] as? Int == kVK_ANSI_P)
        #expect(json?["modifiers"] as? Int == cmdKey | shiftKey)

        let noisy = #"{"keyCode": 17, "modifiers": \#(controlKey | optionKey | alphaLock | rightShiftKey)}"#
        #expect(try JSONDecoder().decode(Hotkey.self, from: Data(noisy.utf8)) == .defaultPalette)

        for bad in [#"{"keyCode": 128, "modifiers": 0}"#, #"{"keyCode": -1, "modifiers": 0}"#,
                    #"{"keyCode": 17}"#, #"{"modifiers": 0}"#, #""T""#] {
            #expect(throws: (any Error).self, "\(bad)") {
                try JSONDecoder().decode(Hotkey.self, from: Data(bad.utf8))
            }
        }
    }
}
