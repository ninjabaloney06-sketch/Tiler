import AppKit
import ApplicationServices

/// The menu-bar item (SPEC §4.A, §5).
///
/// - Left-click: `PaletteController.shared.statusItemClicked(button:)` — the palette drops down
///   under the icon (on mouse-down, like a menu).
/// - Right-click or ⌃-click (and any click while Tiler is paused): the classic menu — Settings…,
///   the Accessibility status line, Pause Tiler, Quit Tiler. It is refreshed every time it
///   opens, so the Accessibility line is always current.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let accessibilityItem = NSMenuItem()
    private let pauseItem = NSMenuItem(title: "Pause Tiler", action: nil, keyEquivalent: "")

    private let onSettings: () -> Void
    private let onPause: (Bool) -> Void
    private(set) var isPaused = false

    /// Set on a `.leftMouseDown` that should open the classic menu (⌃-click, or any click while
    /// paused) instead of the palette; consumed on the matching `.leftMouseUp`. See
    /// `buttonPressed(_:)`.
    private var awaitingMenuOnMouseUp = false

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    init(onSettings: @escaping () -> Void, onPause: @escaping (Bool) -> Void) {
        self.onSettings = onSettings
        self.onPause = onPause
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.leadinghalf.inset.filled",
                                accessibilityDescription: "Tiler")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Tiler — click for the palette, right-click for the menu"
            button.target = self
            button.action = #selector(buttonPressed(_:))
            // The menu (`showMenu()`) is triggered on the MOUSE-UP of a right-click or ⌃-click,
            // never on the mouse-down — see `buttonPressed(_:)` for why.
            button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
        }

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        let quit = NSMenuItem(title: "Quit Tiler", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(quit)
        menu.delegate = self
        refresh()
    }

    /// `showMenu()` pops up `menu` via `performClick(nil)`, which runs its own modal tracking
    /// loop. Calling that SYNCHRONOUSLY from a `.rightMouseDown`/`.leftMouseDown` action — while
    /// AppKit's button cell is still inside its OWN mouse-tracking loop for that same click,
    /// waiting for the matching mouse-up to end it — hands that mouse-up to the menu's tracking
    /// loop instead. The button's tracking loop then never sees its terminating event and stays
    /// stale, so the NEXT mouse-down is spent closing it instead of reaching this action (the
    /// next left-click after a menu use did nothing). Firing on the mouse-UP instead is safe:
    /// that event is the one the button's own tracking loop is already consuming as it ends, so
    /// there is nothing left for the menu's nested loop to steal.
    @objc private func buttonPressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            showMenu()
        case .leftMouseDown:
            if event.modifierFlags.contains(.control) || isPaused {
                awaitingMenuOnMouseUp = true
            } else {
                PaletteController.shared.statusItemClicked(button: sender)
            }
        case .leftMouseUp:
            if awaitingMenuOnMouseUp {
                awaitingMenuOnMouseUp = false
                showMenu()
            } else {
                // Dispatched, not called directly: this `.leftMouseUp` sendAction fires from
                // INSIDE the button cell's own mouseDown→mouseUp tracking loop. Showing the pill
                // from here would come up mid-press, under the cell's own highlight; deferring to
                // the next run-loop turn brings it up strictly after the tracking has ended, like
                // the native menu's highlight — see `PaletteController.statusItemMouseUpDidFinish`.
                DispatchQueue.main.async {
                    PaletteController.shared.statusItemMouseUpDidFinish(button: sender)
                }
            }
        default:
            break
        }
    }

    /// Opens the menu attached to the item, so the menu bar positions and highlights it like any
    /// other status menu. The menu is detached again afterwards so the next left-click reaches
    /// `buttonPressed` instead of opening the menu.
    private func showMenu() {
        // Switching to the classic menu closes an open palette first (its outside-click monitor
        // normally already has), so `dismiss` drops the palette's status-item pill before the
        // menu puts up its own (system-drawn) highlight.
        PaletteController.shared.dismiss(animated: false)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func refresh() {
        if AXIsProcessTrusted() {
            accessibilityItem.title = "Accessibility: granted"
            accessibilityItem.action = nil
            accessibilityItem.target = nil
        } else {
            accessibilityItem.title = "Accessibility: missing — click to open Settings"
            accessibilityItem.action = #selector(requestAccessibility)
            accessibilityItem.target = self
        }
        pauseItem.state = isPaused ? .on : .off
        statusItem.button?.appearsDisabled = isPaused
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
    }

    @objc private func togglePause() {
        isPaused.toggle()
        onPause(isPaused)
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The status item's pill (SPEC §4.A): a rounded highlight over the button, shown while the
/// §4.A palette session opened from this icon is on screen — the visual the menu bar gives a
/// native status menu while it tracks.
///
/// Drawn by a translucent overlay subview, NOT `NSStatusBarButton.highlight(_:)`: on macOS 26
/// (Liquid Glass) that flag no longer renders for status-bar items — set while a palette is open
/// it measures as a visual no-op (RGB distance 0.0 from the unhighlighted icon via
/// `screencapture -R`, where the system's own menu tracking on the same button measures ≈38),
/// which is why `tiler-palettetest`'s pill checks failed. The overlay is translucent, so the
/// template icon stays visible through it, and `hitTest` returns `nil` so every click (and the
/// button's tooltip) still reaches the button. Installed once on first show, toggled with
/// `isHidden`.
final class StatusItemPillView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Capsule inset 2 pt from the button's bounds, like the system's rounded item highlight;
        // translucent gray that adapts to the menu bar appearance (dark on light, light on dark).
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.18)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }
}

/// Installs and toggles the pill overlay on the status-item button. `show` runs from
/// `PaletteController.statusItemMouseUpDidFinish`, `hide` from `PaletteController.dismiss` —
/// every dismissal path (Esc, click outside, apply, a second icon click, target closed, the
/// classic menu, Pause) funnels through there.
enum StatusItemPill {
    static func show(on button: NSStatusBarButton) {
        pill(in: button).isHidden = false
    }

    static func hide(on button: NSStatusBarButton) {
        pill(in: button).isHidden = true
    }

    private static func pill(in button: NSStatusBarButton) -> StatusItemPillView {
        if let existing = button.subviews.compactMap({ $0 as? StatusItemPillView }).first { return existing }
        let view = StatusItemPillView(frame: button.bounds)
        view.autoresizingMask = [.width, .height]
        button.addSubview(view)
        return view
    }
}
