import AppKit

/// The palette's window (SPEC §4.C step 5, "Palette panel (all triggers)"): a borderless,
/// nonactivating panel at `.popUpMenu` level on every Space, shown with
/// `orderFrontRegardless()` so Tiler (an `.accessory` app) is never activated and the target's
/// app stays frontmost. It becomes key only when `allowsKey` is set (hotkey trigger, SPEC
/// §4.B) — still without activating Tiler — so the palette gets the arrow keys, Return, 1–9 and
/// Esc. The window server draws the menu-like shadow around the glass's rounded shape.
final class PalettePanel: NSPanel {
    /// Whether the panel may become key (hotkey trigger only).
    var allowsKey = false

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "Tiler Palette"
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
