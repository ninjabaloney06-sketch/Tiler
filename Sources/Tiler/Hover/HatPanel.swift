import AppKit

/// SPEC §4.C step 4: a near-invisible panel that sits over a window's green button and
/// suppresses the native macOS menu with no `defaults write` (proven: docs/research.md CRITIC
/// section, `tools/probes/poster.swift` variant `hat1`). Its fill is black at `hatAlpha`, the
/// smallest alpha that still captures hover: 1/255 by default, the smallest non-zero value the
/// window server's 8-bit per-pixel alpha can hold (a white titlebar darkens 255→254, below
/// perception; the old 0.02 gave 255→250, a faintly visible square). Never 0.0, which is hover-
/// and click-through and lets the native menu appear (`hat0` in the probe). Verified by
/// `tiler-hovertest --hat-alpha-sweep`.
///
/// Borderless, nonactivating, never key/main (like `PalettePanel`): showing it must never steal
/// focus from the hovered app. Its content view (`HatView`) forwards clicks to the green button
/// (step 6) and reports hover in/out (step 7) through the closures below.
///
/// Critic-reported gap: the forward used to fire on `mouseDown`, so `HoverMonitor.pressGreenButton`
/// set `AXFullScreen` — and the resize notification it triggers dismissed the session, ordering
/// this panel out — while the mouse button was still physically held down. About 1 ms after
/// `orderOut` returned, AppKit believed the panel hidden, but the window server, still mid the
/// same mouse-down tracking sequence as the full-screen space transition, kept the real ~22×22
/// layer-101 window on screen; nothing ever ordered it out again (measured 4/6 round-trip clicks,
/// 5/5 separate single-click runs). Forwarding on `mouseUp` instead — like a real button, whose
/// action fires on release, not on press — let the mouse-down tracking sequence end before the
/// dismiss/orderOut ever runs (0/6 ghosts).
final class HatPanel: NSPanel {
    /// The hat's fill alpha: 1/255 by default; `TILER_HAT_ALPHA` (a Double, clamped to
    /// 1/255…0.05) overrides it for `tiler-hovertest --hat-alpha-sweep`.
    static let hatAlpha: CGFloat = {
        let minimum = 1.0 / 255.0, maximum = 0.05
        guard let raw = ProcessInfo.processInfo.environment["TILER_HAT_ALPHA"],
              let value = Double(raw), value.isFinite else { return CGFloat(minimum) }
        return CGFloat(min(max(value, minimum), maximum))
    }()

    private let hatView = HatView()

    /// Step 6: a click on the hat (which covers the button) forwards `AXPress` to it.
    var onPress: (() -> Void)? {
        get { hatView.onPress }
        set { hatView.onPress = newValue }
    }
    /// Step 7: the cursor entered/left the hat's own rect (`NSTrackingArea`).
    var onEnter: (() -> Void)? {
        get { hatView.onEnter }
        set { hatView.onEnter = newValue }
    }
    var onExit: (() -> Void)? {
        get { hatView.onExit }
        set { hatView.onExit = newValue }
    }
    /// Fired while the cursor moves within the hat, so a slow drift out of the wider hot region
    /// (button + hat + palette + corridor) is still caught between enter/exit events.
    var onMoved: (() -> Void)? {
        get { hatView.onMoved }
        set { hatView.onMoved = newValue }
    }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "Tiler Hover Hat"
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(Self.hatAlpha)
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        ignoresMouseEvents = false
        contentView = hatView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The hat's content view. `NSTrackingArea` (`.activeAlways, .mouseEnteredAndExited,
/// .mouseMoved`) drives its own hover signal, since the hat is one of our own windows and its
/// events never reach the global `.mouseMoved` monitor (SPEC §4.C step 7). `mouseUp` forwards the
/// click instead of letting the hat swallow it silently (step 6) — on release, not on press, so
/// the full-screen round trip it can trigger never starts while AppKit's mouse-down tracking
/// sequence for THIS click is still in progress (see the ghost-hat note on `HatPanel` above).
final class HatView: NSView {
    var onPress: (() -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMoved: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseMoved(with event: NSEvent) { onMoved?() }
    // Consumed, not forwarded: keeps this click from reaching anything else (e.g. window-drag
    // handling further up the responder chain) while still leaving the actual press to mouseUp.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onPress?() }
}
