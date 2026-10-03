import AppKit
import SwiftUI
import TilerCore

/// Size and spacing of the palette in Apple's current style (SPEC §4 "Visual spec"), measured
/// from the native menu at 2× (`docs/reference/apple-native-menu-*@2x.png`, icons 25 × 20 pt
/// there) and kept in proportion to the icon width, so everything scales with the palette size
/// and follows `IconGeometry.iconSize`. With u = icon width / 25 (one native-menu point):
/// selection tile = icon + 20.5 u left+right (45.5 × 36 native, 91 px @2x — SPEC §10.1: the
/// native tile pitch is 107 px / icon-pitch minus the 8 u gap works out to 45.5 u, not the 45 u
/// first guess) + 8 u top/bottom, 8 u between tiles, highlight radius 8 u, panel corner radius
/// 12 u (measured on the panel's own rounded corners, not the 16 u first guess). Tile insets and
/// spacing are whole device pixels (2×), so icons sit on the pixel grid.
///
/// Shared by the live palette (`PaletteGeometry`, C3) and the editor's preview
/// (`PalettePreviewPanel`, below): `PresetIcon.drawTile(_:in:metrics:…)` draws a tile at a rect
/// `PaletteGeometry` computes from these metrics.
nonisolated struct PaletteMetrics: Sendable {
    /// Icon size (`IconGeometry.iconSize(paletteSize:)`).
    let icon: CGSize
    /// Selection tile (highlight) size.
    let tile: CGSize
    /// Space between neighbouring tiles.
    let tileGap: CGFloat
    /// Corner radius of the glass panel (`GlassContainerView.cornerRadius`).
    let cornerRadius: CGFloat
    /// Corner radius of the selection highlight.
    let highlightRadius: CGFloat
    /// Room around the panel for a drawn shadow (editor preview, renders).
    let shadowMargin: CGFloat
    /// Native-menu points per point at this size.
    let unit: CGFloat

    init(paletteSize: Double) {
        icon = IconGeometry.iconSize(paletteSize: paletteSize)
        let u = icon.width / 25
        tile = CGSize(width: icon.width + Self.snap(20.5 * u), height: icon.height + 2 * Self.snap(8 * u))
        tileGap = Self.snap(8 * u)
        cornerRadius = 12 * u
        highlightRadius = 8 * u
        shadowMargin = Self.snap(24 * u)
        unit = u
    }

    /// Rounds to the 2× pixel grid.
    static func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}

/// The soft drop shadow of the panel, drawn only outside the panel shape (the material stays
/// untouched). Matches the native menu's falloff: darkest just below the bottom edge, ~18 pt
/// long, lighter on the sides and top.
final class PanelShadowView: NSView {
    var panel = CGRect.zero { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 16 { didSet { needsDisplay = true } }
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        Self.drawShadow(in: context, bounds: bounds, panel: panel, cornerRadius: cornerRadius, scale: scale, dark: dark)
    }

    /// The panel shadow + hairline outside `panel`, clipped so the material inside stays
    /// untouched: offset -4u down (device space, y up), blur 16u, alpha 0.55 dark / 0.28 light;
    /// plus, only for the flat static-material stand-in used offscreen
    /// (`GlassContainerView.usesStaticMaterial`), a half-point hairline hugging the outside of
    /// the edge like live glass shows, alpha 0.35 dark / 0.18 light. Shared by the editor
    /// preview (this view) and the live palette's headless render (`PaletteSnapshotView`,
    /// `Sources/Tiler/Palette/PaletteSnapshot.swift`) — the render and the editor preview are
    /// already different view stacks; this keeps the one piece they must not drift on in one
    /// place.
    static func drawShadow(in context: CGContext, bounds: CGRect, panel: CGRect, cornerRadius: CGFloat,
                           scale: CGFloat, dark: Bool) {
        guard !panel.isEmpty else { return }
        let shape = CGPath(roundedRect: panel, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.saveGState()
        // Clip to everything outside the panel.
        context.addRect(bounds)
        context.addPath(shape)
        context.clip(using: .evenOdd)
        context.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 16 * scale,
                          color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.28))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
        guard GlassContainerView.usesStaticMaterial else { return }
        context.saveGState()
        context.addRect(bounds)
        context.addPath(shape)
        context.clip(using: .evenOdd)
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 0, alpha: dark ? 0.35 : 0.18))
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }
}

/// The editor's live preview (SPEC §5 "a live preview of the resulting palette"): the same
/// `PaletteView` the live palette itself draws — header, tiles (blanks stay empty space), the
/// Revert column and the "Tiler Settings…" footer, hovering and tooltips included — in a
/// `GlassContainerView` with a drawn menu-like shadow around it (an embedded view has no
/// window-server shadow of its own; `PanelShadowView`, shared with the headless render). Unlike
/// the live palette's own floating panel, this sits inside the Settings window's content, so its
/// `GlassContainerView` blends `.withinWindow`.
final class PalettePreviewPanel: NSView {
    /// Natural size (panel + shadow margin) for `content`, without building any views.
    static func viewSize(content: PaletteContent) -> CGSize {
        let geometry = PaletteGeometry(content: content)
        let margin = geometry.metrics.shadowMargin
        return CGSize(width: geometry.size.width + 2 * margin, height: geometry.size.height + 2 * margin)
    }

    private(set) var content: PaletteContent
    let paletteView: PaletteView
    private let shadowView = PanelShadowView()
    private let glass: GlassContainerView

    init(content: PaletteContent) {
        self.content = content
        paletteView = PaletteView(content: content)
        glass = GlassContainerView(cornerRadius: paletteView.geometry.metrics.cornerRadius, blendingMode: .withinWindow)
        super.init(frame: .zero)
        glass.contentView = paletteView
        addSubview(shadowView)
        addSubview(glass)
        relayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { Self.viewSize(content: content) }

    /// Replaces the content (a new layout, target or setting) and relays out — skipped when
    /// nothing actually changed, so hovering the preview survives unrelated edits elsewhere in
    /// the form (SwiftUI re-renders this view on every change to the settings window, not only
    /// ones that touch the palette).
    func update(_ content: PaletteContent) {
        guard content.layout != self.content.layout || content.paletteSize != self.content.paletteSize
            || content.header != self.content.header || content.hasTarget != self.content.hasTarget
            || content.hasHistory != self.content.hasHistory
        else { return }
        self.content = content
        paletteView.update(content)
        relayout()
    }

    private func relayout() {
        let metrics = paletteView.geometry.metrics
        let margin = metrics.shadowMargin
        let size = Self.viewSize(content: content)
        let panel = CGRect(origin: CGPoint(x: margin, y: margin), size: paletteView.geometry.size)
        setFrameSize(size)
        shadowView.frame = CGRect(origin: .zero, size: size)
        shadowView.panel = panel
        shadowView.cornerRadius = metrics.cornerRadius
        shadowView.scale = metrics.unit
        glass.frame = panel
        glass.cornerRadius = metrics.cornerRadius
        invalidateIntrinsicContentSize()
    }
}

// MARK: SwiftUI

/// SwiftUI host of `PalettePreviewPanel` (the editor's live preview).
struct PalettePreview: NSViewRepresentable {
    let content: PaletteContent

    func makeNSView(context: Context) -> PalettePreviewPanel {
        PalettePreviewPanel(content: content)
    }

    func updateNSView(_ view: PalettePreviewPanel, context: Context) {
        view.update(content)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PalettePreviewPanel, context: Context) -> CGSize? {
        PalettePreviewPanel.viewSize(content: content)
    }
}

/// The editor's live preview: the exact `PaletteView` the live palette draws, for a
/// representative target (SPEC §4.B's own header example) with no move history to revert, at
/// the real `paletteSize` — never a scale below the supported minimum (SPEC §10.1 "Settings":
/// 0.8–2.0) — then shrunk purely as a *display* transform when it does not fit `box`, with a
/// one-line caption. Shrinking the finished drawing (rather than feeding a smaller scale into
/// the icon geometry) is what keeps every icon and arrange slot intact down to 0.8: below that
/// scale `IconGeometry` starts dropping slots. The shrink is 100 % whenever the palette at the
/// CURRENT size already fits `box`, so the common sizes show full size instead of always being
/// squeezed to whatever the maximum setting (2.0) would need.
struct PalettePreviewBox: View {
    let layout: PaletteLayout
    let paletteSize: Double
    let box: CGSize

    /// A representative target for the preview, with no move history (a Revert well shows
    /// dimmed) — the editor itself has none.
    private var content: PaletteContent {
        PaletteContent(layout: layout, paletteSize: paletteSize, header: "Obsidian — Notes.md",
                       hasTarget: true, hasHistory: false)
    }

    var body: some View {
        let grid = layout.paletteGrid
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preview").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(caption(grid)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            ZStack {
                if grid.isEmpty {
                    Text("The palette is empty. Drag presets from the library into the wells.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    let content = self.content
                    let natural = PalettePreviewPanel.viewSize(content: content)
                    let display = fit(natural)
                    PalettePreview(content: content)
                        .frame(width: natural.width, height: natural.height)
                        .scaleEffect(display)
                        .frame(width: natural.width * display, height: natural.height * display)
                }
            }
            .frame(width: box.width, height: box.height)
        }
    }

    /// Fraction of natural size the preview is DISPLAYED at — a post-render shrink, never fed
    /// into `PalettePreview`'s own `paletteSize`. 100 % whenever the palette at the current
    /// size already fits `box`; shrunk, never enlarged, only when it doesn't.
    private func fit(_ natural: CGSize) -> Double {
        min(1, box.width / natural.width, box.height / natural.height)
    }

    private func caption(_ grid: [[String?]]) -> String {
        guard let columns = grid.first?.count else { return "" }
        let size = Int((paletteSize * 100).rounded())
        let shown = Int((fit(PalettePreviewPanel.viewSize(content: content)) * 100).rounded())
        let base = "\(columns) × \(grid.count) · size \(size) %"
        return shown < 100 ? base + " · shown at \(shown) %" : base
    }
}
