import AppKit
import Carbon.HIToolbox
import SwiftUI
import TilerCore

extension Notification.Name {
    /// Posted when the Settings hotkey recorder starts and stops recording; `userInfo["isRecording"]`
    /// is a `Bool`. While it records, the palette's global hotkey should be suspended, so pressing
    /// the current shortcut reaches the recorder instead of toggling the palette.
    static let tilerHotkeyRecordingDidChange = Notification.Name("TilerHotkeyRecordingDidChange")
}

/// Checks a recorded palette hotkey (SPEC §4.B "validate, show conflicts as an error").
enum HotkeyValidation {
    /// Why `hotkey` cannot be the palette hotkey, or nil if it can. `current` is the hotkey Tiler
    /// has registered now; it is not tested against itself.
    static func problem(with hotkey: Hotkey, current: Hotkey?) -> String? {
        let name = displayName(hotkey)
        // Without ⌃ or ⌘ a key types text (⌥ and ⇧ pick characters, e.g. ⌥L = @ on German
        // layouts); F-keys type nothing.
        if hotkey.modifiers & (Hotkey.command | Hotkey.control) == 0 && !isFunctionKey(hotkey.keyCode) {
            return "\(name) would block typing. Add ⌃ or ⌘."
        }
        if hotkey.modifiers == Hotkey.command && !isFunctionKey(hotkey.keyCode) {
            return "\(name) is an app shortcut. Add ⌃ or ⌥."
        }
        if isSystemShortcut(hotkey) {
            return "\(name) is a macOS shortcut (System Settings › Keyboard › Keyboard Shortcuts)."
        }
        if hotkey != current, let status = registrationStatus(hotkey), status != noErr {
            return status == OSStatus(eventHotKeyExistsErr)
                ? "\(name) is already taken by another app."
                : "\(name) cannot be used as a global shortcut."
        }
        return nil
    }

    /// F1–F20.
    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        Hotkey(keyCode: keyCode, modifiers: 0).keyName.range(of: #"^F\d+$"#, options: .regularExpression) != nil
    }

    /// True if an enabled macOS symbolic hotkey (Spotlight, Mission Control, screenshots, input
    /// sources, …) uses exactly this key and these modifiers.
    static func isSystemShortcut(_ hotkey: Hotkey) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { return false }
            return code == hotkey.keyCode && modifiers & Hotkey.allModifiers == hotkey.modifiers
        }
    }

    /// Registers `hotkey` exclusively and unregisters it at once: `eventHotKeyExistsErr` means
    /// another app holds it exclusively. nil if the test could not run.
    private static func registrationStatus(_ hotkey: Hotkey) -> OSStatus? {
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x544C_5254, id: 0xFFFF) // 'TLRT', a throwaway id
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status
    }

    /// "⌃⌥T", with character keys named after the current keyboard layout (e.g. the key US
    /// layouts call Y reads Z on a German layout).
    static func displayName(_ hotkey: Hotkey) -> String {
        hotkey.modifierSymbols + keyName(hotkey.keyCode)
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        let usName = Hotkey(keyCode: keyCode, modifiers: 0).keyName
        // Character keys of the ANSI/ISO block; Return, Tab and Space keep their names.
        guard keyCode <= 0x32, ![0x24, 0x30, 0x31].contains(keyCode),
              let character = layoutCharacter(keyCode) else { return usName }
        return character.uppercased()
    }

    /// The character `keyCode` types without modifiers on the current ASCII-capable layout.
    private static func layoutCharacter(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

/// Records the palette hotkey (SPEC §4.B, §5): click the field, press the new shortcut. Esc
/// cancels, ⌫ or the clear button removes the hotkey (the palette then opens from the menu bar
/// only). Invalid or conflicting shortcuts are rejected with the reason shown in red below the
/// field; the saved hotkey stays unchanged.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    /// Shown below the field when there is no error.
    let caption: String

    @State private var recorder = HotkeyRecorderModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                field
                if hotkey != nil && !recorder.isRecording {
                    Button {
                        recorder.error = nil
                        hotkey = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the hotkey")
                    .accessibilityLabel("Remove the palette hotkey")
                }
            }
            Text(recorder.error ?? caption)
                .font(.system(size: 11))
                .foregroundStyle(recorder.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(recorder.error ?? caption)
        }
        .onDisappear { recorder.stop() }
    }

    private var field: some View {
        let recording = recorder.isRecording
        let dark = colorScheme == .dark
        let text: String = if recording {
            recorder.liveModifiers.isEmpty ? "Type shortcut…" : recorder.liveModifiers + "…"
        } else {
            hotkey.map(HotkeyValidation.displayName) ?? "Record Shortcut"
        }
        return Button {
            if recording {
                recorder.stop()
            } else {
                recorder.start(current: hotkey) { hotkey = $0 }
            }
        } label: {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(hotkey == nil && !recording ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: 116, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(NSColor.gray(dark ? 0x1E : 0xFF).swiftUI))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : NSColor.gray(dark ? 0x4A : 0xD9).swiftUI,
                                      lineWidth: recording ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Press the new shortcut. Esc cancels, ⌫ removes the hotkey." : "Click to record a new shortcut")
        .accessibilityLabel("Palette hotkey")
        .accessibilityValue(hotkey.map(HotkeyValidation.displayName) ?? "none")
    }
}

/// Recording state of `HotkeyRecorder`: a local key monitor that swallows key events while
/// recording.
@Observable
final class HotkeyRecorderModel {
    private(set) var isRecording = false
    /// Modifiers held right now while recording, e.g. "⌃⌥".
    private(set) var liveModifiers = ""
    /// Why the last recorded shortcut was rejected.
    var error: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var current: Hotkey?
    @ObservationIgnored private var onRecord: ((Hotkey?) -> Void)?

    func start(current: Hotkey?, onRecord: @escaping (Hotkey?) -> Void) {
        stop()
        self.current = current
        self.onRecord = onRecord
        error = nil
        liveModifiers = ""
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let isKeyDown = event.type == .keyDown
            let keyCode = UInt32(event.keyCode)
            let modifiers = Self.carbonModifiers(event.modifierFlags)
            MainActor.assumeIsolated {
                self.handle(isKeyDown: isKeyDown, keyCode: keyCode, modifiers: modifiers)
            }
            return nil // consumed while recording
        }
        // Switching away from the window cancels.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        NotificationCenter.default.post(name: .tilerHotkeyRecordingDidChange, object: nil,
                                        userInfo: ["isRecording": true])
    }

    func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        onRecord = nil
        isRecording = false
        liveModifiers = ""
        NotificationCenter.default.post(name: .tilerHotkeyRecordingDidChange, object: nil,
                                        userInfo: ["isRecording": false])
    }

    private func handle(isKeyDown: Bool, keyCode: UInt32, modifiers: UInt32) {
        guard isKeyDown else {
            liveModifiers = Hotkey(keyCode: 0, modifiers: modifiers).modifierSymbols
            return
        }
        switch (keyCode, modifiers) {
        case (UInt32(kVK_Escape), 0):
            stop()
        case (UInt32(kVK_Delete), 0), (UInt32(kVK_ForwardDelete), 0):
            onRecord?(nil)
            stop()
        default:
            let candidate = Hotkey(keyCode: keyCode, modifiers: modifiers)
            if let problem = HotkeyValidation.problem(with: candidate, current: current) {
                error = problem
            } else {
                onRecord?(candidate)
            }
            stop()
        }
    }

    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Hotkey.command }
        if flags.contains(.shift) { modifiers |= Hotkey.shift }
        if flags.contains(.option) { modifiers |= Hotkey.option }
        if flags.contains(.control) { modifiers |= Hotkey.control }
        return modifiers
    }
}
