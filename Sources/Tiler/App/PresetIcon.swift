import AppKit
import SwiftUI
import TilerCore

/// THE preset-icon renderer of the Tiler target (SPEC §4 "Icons": one shared renderer for the
/// palette, the library, the editor wells and the preview). Everything it draws comes from
/// `IconGeometry` (C1): the rounded "screen" outline stroked in one color, the target region(s)
/// (`IconGeometry.filledRects`) as filled rounded rects with the exposed corner radii, and — for
/// `-sm` presets — the Stage Manager strip mark.
///
/// Monochrome and template-like: the ink comes from `Ink` resolved for an appearance (label
/// color, dimmed, or white on the accent highlight), so icons follow light/dark mode and the
/// selection state. Coordinates are icon-local, origin top-left, y down; place icons on
/// pixel-aligned origins so the snapped geometry stays crisp.
///
/// Typical calls from the palette (C3), inside `draw(_:)` of a flipped view:
///
///     let context = NSGraphicsContext.current!.cgContext
///     PresetIcon.drawTile(preset, in: metrics.tileRect(row: r, column: c), metrics: metrics,
///                         ink: isSelected ? .highlighted : .normal,
///                         appearance: effectiveAppearance, in: context)
///
/// or just the icon: `PresetIcon.draw(preset, size:, at:, ink:, appearance:, in:)`.
///
/// `nonisolated` so it can be called from any drawing context, including `NSImage` drawing
/// handlers.
nonisolated enum PresetIcon {
    /// Icon ink, like Apple's template images in the green-button menu (measured on
    /// `docs/reference/apple-native-menu-{light,dark}@2x.png`).
    enum Ink: Sendable {
        /// `labelColor`: #262626 on the light menu, #E1E1E1 on the dark menu.
        case normal
        /// `tertiaryLabelColor` (25 %): the native menu's dimmed tone (#BEBEBE light, #6B6B6B
        /// dark) — disabled presets, e.g. single-window presets when there is no target window.
        case dimmed
        /// White, on the accent-colored selection highlight.
        case highlighted
    }

    /// The ink as a CGColor for `appearance` (pass the view's `effectiveAppearance`, so
    /// Increase Contrast and dark mode are honored).
    static func color(_ ink: Ink, appearance: NSAppearance) -> CGColor {
        var color = CGColor(gray: 0, alpha: 1)
        appearance.performAsCurrentDrawingAppearance {
            switch ink {
            case .normal: color = NSColor.labelColor.cgColor
            case .dimmed: color = NSColor.tertiaryLabelColor.cgColor
            case .highlighted: color = NSColor.white.cgColor
            }
        }
        return color
    }

    /// The selection highlight behind a `.highlighted` icon: the accent color, like the native
    /// menu's selected item (#007AFF with the blue accent).
    static func highlightColor(appearance: NSAppearance) -> CGColor {
        var color = CGColor(gray: 0, alpha: 1)
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.controlAccentColor.cgColor
        }
        return color
    }

    /// Light (`.aqua`) or dark (`.darkAqua`) appearance, for callers without a view.
    static func appearance(dark: Bool) -> NSAppearance {
        NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    /// The native menu's selection treatment: an accent-colored rounded rect filling `rect`,
    /// `radius` clamped to half its shorter side. The one place this is drawn — `drawTile`'s
    /// `.highlighted` tile and every other selection highlight (Revert, footer row) call this
    /// instead of repeating the radius clamp / path / fill.
    static func fillHighlight(_ rect: CGRect, radius: CGFloat, appearance: NSAppearance, in context: CGContext) {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(highlightColor(appearance: appearance))
        context.fillPath()
    }

    // MARK: Revert

    /// The Revert well item's icon (SPEC §3): the ↩ symbol in `color`, centered in `rect` on the
    /// half-point grid, sized to the preset icons' height `iconHeight`. The one Revert renderer —
    /// the palette tile, the editor wells and the drag image all call this. `context` is y-down.
    static func drawRevert(in rect: CGRect, iconHeight: CGFloat, color: CGColor, in context: CGContext) {
        let configuration = NSImage.SymbolConfiguration(pointSize: iconHeight * 0.9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color) ?? .labelColor]))
        guard let image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Revert")?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let origin = CGPoint(x: ((rect.midX - size.width / 2) * 2).rounded() / 2,
                             y: ((rect.midY - size.height / 2) * 2).rounded() / 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// One Revert palette tile: the selection highlight for `.highlighted`, then the symbol.
    static func drawRevertTile(in tile: CGRect, metrics: PaletteMetrics, ink: Ink,
                               appearance: NSAppearance, in context: CGContext) {
        if ink == .highlighted {
            fillHighlight(tile, radius: metrics.highlightRadius, appearance: appearance, in: context)
        }
        drawRevert(in: tile, iconHeight: metrics.icon.height, color: color(ink, appearance: appearance), in: context)
    }

    // MARK: Paths

    /// The outline to stroke with `geometry.strokeWidth`.
    static func outlinePath(_ geometry: IconGeometry) -> CGPath {
        let rect = geometry.outlineRect
        let radius = min(geometry.outlineCornerRadius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Every filled region as one path: the target region(s) plus, for `-sm` presets, the
    /// Stage Manager strip mark (`IconGeometry.filledRects`), each with
    /// `geometry.fillCornerRadius` clamped to half its shorter side.
    static func fillPath(_ geometry: IconGeometry) -> CGPath {
        let path = CGMutablePath()
        for rect in geometry.filledRects where rect.width > 0 && rect.height > 0 {
            let radius = min(geometry.fillCornerRadius, rect.width / 2, rect.height / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }

    // MARK: Drawing

    /// Draws the icon of `preset` at `size` into a y-down context with its top-left corner at
    /// `origin`, in `color`.
    static func draw(_ preset: Preset, size: CGSize, at origin: CGPoint, color: CGColor,
                     in context: CGContext, pixelScale: CGFloat = 2) {
        let geometry = IconGeometry(preset: preset, size: size, pixelScale: pixelScale)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(geometry.strokeWidth)
        context.addPath(outlinePath(geometry))
        context.strokePath()
        context.addPath(fillPath(geometry))
        context.fillPath()
        context.restoreGState()
    }

    /// Draws the icon of `preset` in `ink` resolved for `appearance`.
    static func draw(_ preset: Preset, size: CGSize, at origin: CGPoint, ink: Ink,
                     appearance: NSAppearance, in context: CGContext, pixelScale: CGFloat = 2) {
        draw(preset, size: size, at: origin, color: color(ink, appearance: appearance),
             in: context, pixelScale: pixelScale)
    }

    /// One palette tile (y-down context): for `.highlighted` the native menu's selection — an
    /// accent-colored rounded rect filling `tile` with `metrics.highlightRadius` — then the icon
    /// at `metrics.icon`, centered in `tile` on the pixel grid.
    static func drawTile(_ preset: Preset, in tile: CGRect, metrics: PaletteMetrics, ink: Ink,
                         appearance: NSAppearance, in context: CGContext, pixelScale: CGFloat = 2) {
        if ink == .highlighted {
            fillHighlight(tile, radius: metrics.highlightRadius, appearance: appearance, in: context)
        }
        func centered(_ start: CGFloat, _ outer: CGFloat, _ inner: CGFloat) -> CGFloat {
            ((start + (outer - inner) / 2) * pixelScale).rounded() / pixelScale
        }
        let origin = CGPoint(x: centered(tile.minX, tile.width, metrics.icon.width),
                             y: centered(tile.minY, tile.height, metrics.icon.height))
        draw(preset, size: metrics.icon, at: origin, ink: ink, appearance: appearance,
             in: context, pixelScale: pixelScale)
    }

}

/// SwiftUI face of `PresetIcon`: the icon of `preset` at exactly `size`, in `ink` for the
/// current color scheme.
struct PresetIconView: View {
    let preset: Preset
    let size: CGSize
    var ink = PresetIcon.Ink.normal

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let geometry = IconGeometry(preset: preset, size: size)
        let color = Color(cgColor: PresetIcon.color(ink, appearance: PresetIcon.appearance(dark: colorScheme == .dark)))
        ZStack(alignment: .topLeading) {
            Path(PresetIcon.outlinePath(geometry)).stroke(color, lineWidth: geometry.strokeWidth)
            Path(PresetIcon.fillPath(geometry)).fill(color)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityLabel(preset.name)
    }
}
