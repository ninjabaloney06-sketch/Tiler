import AppKit

/// The native menu material as one reusable container (SPEC §4 "Palette panel"): Liquid Glass
/// (`NSGlassEffectView`) on macOS 26+, else `NSVisualEffectView` with material `.menu`, state
/// `.active` — rounded with a menu-like corner radius. Put the content in `contentView`; it is
/// resized with the container. The live palette (C3) and the editor's preview both use it.
///
/// Live palette (C3), in a borderless nonactivating panel:
///
///     let glass = GlassContainerView(cornerRadius: metrics.cornerRadius)
///     glass.contentView = paletteContent           // your views, flipped or not
///     panel.contentView = glass
///     panel.isOpaque = false
///     panel.backgroundColor = .clear
///     panel.hasShadow = true                       // the window server draws the menu shadow
///     // after changing the panel's size: panel.invalidateShadow()
///
/// No shadow of its own: in a window the window server draws it around the rounded shape; the
/// editor preview and the headless renders draw one themselves (`PanelShadowView`, in
/// `GlassPaletteView.swift`).
final class GlassContainerView: NSView {
    /// Headless renders (`--render-palette`, `--render-editor`) set this before building views:
    /// offscreen snapshots draw glass without its tint and far too dark in dark mode, so renders
    /// use a flat stand-in with the tones measured from live glass instead.
    static var usesStaticMaterial = false

    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { applyCornerRadius() } }
    }

    /// The content, placed inside the material and kept at the container's size.
    var contentView: NSView? {
        didSet {
            guard contentView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            installContent()
        }
    }

    private let materialView: NSView

    /// - Parameter blendingMode: for the pre-macOS 26 `NSVisualEffectView` only:
    ///   `.behindWindow` for a panel of its own (the default), `.withinWindow` inside another
    ///   window's content (the editor preview).
    init(cornerRadius: CGFloat, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.cornerRadius = cornerRadius
        if Self.usesStaticMaterial {
            materialView = StaticMaterialView()
        } else if #available(macOS 26, *) {
            materialView = NSGlassEffectView()
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.state = .active
            effect.blendingMode = blendingMode
            materialView = effect
        }
        super.init(frame: .zero)
        // Clip the container itself to the rounded rect. Without this, `NSGlassEffectView`'s own
        // drop shadow (drawn over its full rectangular bounds while the window is key) leaves
        // alpha > 0 outside the rounded corners; the window server then builds the panel's shadow
        // from that rectangle instead of the rounded shape (square notches behind the corners, a
        // rectangular shadow — see the corner-radius fix note below `applyCornerRadius`).
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        materialView.frame = bounds
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView)
        applyCornerRadius()
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    // Live glass looks different in the active window (see `updateTint`), so follow the window's
    // key and main state.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification]
        if let window {
            names.forEach { center.removeObserver(self, name: $0, object: window) }
        }
        if let newWindow {
            names.forEach { center.addObserver(self, selector: #selector(windowActiveStateChanged), name: $0, object: newWindow) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTint()
    }

    @objc private func windowActiveStateChanged(_ notification: Notification) {
        updateTint()
        window?.invalidateShadow()
    }

    private func installContent() {
        guard let contentView else { return }
        contentView.frame = materialView.bounds
        contentView.autoresizingMask = [.width, .height]
        if #available(macOS 26, *), let glass = materialView as? NSGlassEffectView {
            glass.contentView = contentView
        } else {
            materialView.addSubview(contentView)
        }
    }

    private func applyCornerRadius() {
        layer?.cornerRadius = cornerRadius
        if let flat = materialView as? StaticMaterialView {
            flat.cornerRadius = cornerRadius
        } else if #available(macOS 26, *), let glass = materialView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else if let effect = materialView as? NSVisualEffectView {
            effect.maskImage = Self.roundedMask(radius: cornerRadius)
        }
        window?.invalidateShadow()
    }

    /// Tints that give every state the tone of the native menu, which is never active. Dark
    /// values measured on screen with `screencapture` (raw values):
    /// - Inactive window (menu-bar palette; Settings while another app is active): dark needs
    ///   20 % white (plain glass #353535 over #212121, tinted #3A3A3A = the native menu, which
    ///   samples at #393A3A over `apple-native-menu-dark@2x.png`).
    /// - Active window, i.e. key or main (Settings window of the active app, also while the
    ///   palette panel is key; hotkey palette): the glass renders brighter and applies a tint far
    ///   more strongly — 20 % white gave #666666 over the #242424 Settings pane instead of
    ///   #3C3C3C. A light black tint brings it back to the inactive tone: dark 5 % → #3C3C3C.
    /// (Both dark cases are unchanged by this fix.)
    ///
    /// Light active is untinted (23 Sep 2026, e767f7e/this fix): plain glass measured #FBFBFB over
    /// the #F7F7F7 Settings pane, already close to the #FEFEFE target.
    ///
    /// Light inactive is untinted too (this fix, 26 Sep 2026; supersedes the 55 % white tint from
    /// e767f7e, which was never measured and had the wrong sign — see below). Measured live with
    /// `TILER_FORCE_APPEARANCE=light` + `screencapture -l` on both repro cases from SPEC §8's gap
    /// report, window not key/main, over the #F7F7F7 Settings pane:
    /// - `tintColor = nil` (plain glass): **#EDEDED**.
    /// - `tintColor = .white @ 15 %`: #EAEAEA (3 levels darker than plain).
    /// - `tintColor = .white @ 55 %` (the old code) and `tintColor = .black @ 55 %`: **both
    ///   #DFDFDF** — same result regardless of hue. `style = .clear` with no tint: #EEEEEE, no
    ///   real difference from plain `.regular`.
    /// So on this (light, inactive) `NSGlassEffectView` state, `tintColor`'s hue doesn't matter —
    /// only its alpha does, and raising it only darkens (roughly linearly, ~25 levels per unit
    /// alpha), moving further from #FEFEFE, not closer. That is the opposite of what the 55 %
    /// white tint was chosen for (it was extrapolated from the dark-mode fix, assuming white tint
    /// lightens here the way it does in dark mode — it doesn't). `nil` (plain glass, #EDEDED) is
    /// therefore the closest reachable tone to #FEFEFE through this view's public API in this
    /// state: still ~17 levels off and ~10 levels darker than its own #F7F7F7 backdrop, but no
    /// longer the ~31-level-off, visibly-grey-card #DFDFDF the old tint produced. Getting the rest
    /// of the way to #FEFEFE would need something other than `tintColor`/`style` (no public
    /// `NSVisualEffectView`-style "always active" override exists on `NSGlassEffectView`) — a
    /// documented ninja check, not attempted here.
    private func updateTint() {
        guard #available(macOS 26, *), let glass = materialView as? NSGlassEffectView else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let active = window.map { $0.isKeyWindow || $0.isMainWindow } ?? false
        switch (dark, active) {
        case (true, false): glass.tintColor = NSColor(white: 1, alpha: 0.2)
        case (true, true): glass.tintColor = NSColor(white: 0, alpha: 0.05)
        case (false, _): glass.tintColor = nil
        }
    }

    /// Resizable rounded-rect mask for `NSVisualEffectView`.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Stand-in for live glass in headless renders: the flat tone live glass targets over the
/// reference backdrops. Dark (#3A3A3A over #212121) was measured live with `screencapture`;
/// light (#FEFEFE) is the native menu's own tone, sampled directly from
/// `apple-native-menu-light@2x.png` (dominant background pixel (254, 254, 254)) since this Mac's
/// system appearance is Dark and agents may not switch it to Light to re-measure live glass.
private final class StaticMaterialView: NSView {
    var cornerRadius: CGFloat = 16 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let level: CGFloat = dark ? 58 / 255 : 254 / 255
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.setFillColor(CGColor(srgbRed: level, green: level, blue: level, alpha: 1))
        context.fillPath()
    }
}
