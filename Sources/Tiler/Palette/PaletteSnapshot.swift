import AppKit
import TilerCore

/// The live palette for headless renders (`--render-palette`, SPEC §5): the same `PaletteView`
/// in the same `GlassContainerView` the panel shows, plus the menu shadow drawn around it,
/// because an offscreen snapshot has no window-server shadow. `shadowMargin` of room on every
/// side.
final class PaletteSnapshotView: NSView {
    let paletteView: PaletteView
    private let glass: GlassContainerView
    private let panelRect: CGRect
    private let unit: CGFloat
    private let cornerRadius: CGFloat

    init(content: PaletteContent) {
        paletteView = PaletteView(content: content)
        let geometry = paletteView.geometry
        let margin = geometry.metrics.shadowMargin
        unit = geometry.metrics.unit
        cornerRadius = geometry.metrics.cornerRadius
        panelRect = CGRect(origin: CGPoint(x: margin, y: margin), size: geometry.size)
        glass = GlassContainerView(cornerRadius: cornerRadius)
        super.init(frame: CGRect(x: 0, y: 0, width: geometry.size.width + 2 * margin,
                                 height: geometry.size.height + 2 * margin))
        glass.frame = panelRect
        glass.contentView = paletteView
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The menu shadow outside the panel shape (the material stays untouched): darkest below the
    /// bottom edge, like the window server draws it for the live panel. Draws through
    /// `PanelShadowView.drawShadow` (`Sources/Tiler/App/GlassPaletteView.swift`), the same
    /// routine the editor preview uses, so the render and the editor preview can't drift apart
    /// on the one piece they share.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        PanelShadowView.drawShadow(in: context, bounds: bounds, panel: panelRect, cornerRadius: cornerRadius,
                                   scale: unit, dark: dark)
    }
}
