import Carbon.HIToolbox
import TilerCore

/// The palette's global hotkey (SPEC §4.B): Carbon `RegisterEventHotKey`, which needs no
/// permission and fires whichever app is active — including while Tiler's own palette panel is
/// key, so pressing the hotkey again closes the palette.
///
/// One registration at a time: `register(_:)` replaces the previous hotkey (live re-registration
/// when the setting changes), `unregister()` removes it (pause, while Settings records a new one).
final class HotkeyTrigger {
    /// 'TLR3': tells our hotkey apart from the recorder's throwaway test registrations.
    private static let signature: OSType = 0x544C_5233
    private static let hotkeyID: UInt32 = 1

    /// Called on the main thread when the registered hotkey is pressed.
    var onPress: (() -> Void)?

    /// The hotkey currently registered with the system, nil if none.
    private(set) var registered: Hotkey?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers `hotkey`, replacing any previous registration; nil only unregisters. Returns the
    /// Carbon status (`noErr`, or e.g. `eventHotKeyExistsErr` when another app holds it
    /// exclusively); on failure nothing is registered.
    @discardableResult
    func register(_ hotkey: Hotkey?) -> OSStatus {
        unregister()
        guard let hotkey else { return noErr }
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return handlerStatus }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: Self.hotkeyID),
            GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            hotKeyRef = reference
            registered = hotkey
        }
        return status
    }

    /// Removes the registration (the event handler stays installed; it costs nothing).
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec,
                                   Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Called by the Carbon handler for every hot-key press of this app.
    fileprivate func handle(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == Self.signature, id.id == Self.hotkeyID, hotKeyRef != nil else {
            return OSStatus(eventNotHandledErr)
        }
        onPress?()
        return noErr
    }
}

/// Carbon event handler (a C function pointer, so no captures): reads the hot-key id and hands it
/// to the `HotkeyTrigger` passed as `userData`. Carbon dispatches application events on the main
/// thread.
private nonisolated func hotkeyEventHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let address = UInt(bitPattern: userData)
    return MainActor.assumeIsolated {
        let trigger = Unmanaged<HotkeyTrigger>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
        return trigger.handle(id)
    }
}
