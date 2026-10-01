import AppKit
import SwiftUI

/// Fixed colors of the settings window, picked per appearance. Light values are measured from
/// `docs/reference/half_top.jpg` (pane #F7F7F7, empty well #F2F2F2, well border #E5E5E5,
/// occupied well white); dark values are our own (Moom's dark editor is not in the
/// references). Explicit colors instead of dynamic system colors keep the headless renders
/// (`--render-editor`) identical to what the live window shows. Preset icons are not themed
/// here: they use `PresetIcon.Ink`, like the palette.
struct EditorTheme {
    let isDark: Bool

    init(dark: Bool) { isDark = dark }
    init(_ scheme: ColorScheme) { isDark = scheme == .dark }

    /// Right pane and window background.
    var paneBackground: NSColor { isDark ? .gray(0x24) : .gray(0xF7) }
    /// The floating sidebar panel.
    var sidebarBackground: NSColor { isDark ? .gray(0x2D) : .gray(0xEE) }
    /// 1 pt highlight along the sidebar panel's edge.
    var sidebarEdge: NSColor { isDark ? .gray(0xFF, 0.07) : .gray(0xFF, 0.9) }
    var sidebarShadow: NSColor { isDark ? .gray(0x00, 0.35) : .gray(0x00, 0.07) }

    /// A well outside the palette's bounding box.
    var wellEmptyFill: NSColor { isDark ? .gray(0x2C) : .gray(0xF2) }
    var wellEmptyBorder: NSColor { isDark ? .gray(0x37) : .gray(0xE5) }
    /// A well that is part of the palette: occupied, or a blank inside the bounding box.
    var wellShownFill: NSColor { isDark ? .gray(0x3E) : .gray(0xFF) }
    var wellShownBorder: NSColor { isDark ? .gray(0x4C) : .gray(0xE3) }
}

extension NSColor {
    /// Opaque (or `alpha`) sRGB gray from an 8-bit level.
    static func gray(_ level: Int, _ alpha: CGFloat = 1) -> NSColor {
        let value = CGFloat(level) / 255
        return NSColor(srgbRed: value, green: value, blue: value, alpha: alpha)
    }
}

extension NSColor {
    /// The same color as a SwiftUI `Color`.
    var swiftUI: Color { Color(nsColor: self) }
}
