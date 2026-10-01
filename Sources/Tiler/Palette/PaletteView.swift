import AppKit
import TilerCore

/// One thing in the palette that can be selected and activated.
nonisolated enum PaletteItem: Hashable, Sendable {
    /// The preset in this well (absolute editor position, SPEC §2).
    case preset(WellPosition)
    /// Revert the last move (SPEC §3), shown at the far left when there is history.
    case revert
    /// The footer row "Tiler Settings…" (SPEC §4.A).
    case settings
}

/// What the palette shows for one opening.
struct PaletteContent {
    /// The configured wells; the palette is their bounding box (SPEC §2).
    var layout: PaletteLayout
    /// Palette size setting (metric scale).
    var paletteSize: Double
    /// "App — Window title" or "No window".
    var header: String
    /// False = no target window: single-window presets are dimmed and inert (SPEC §4).
    var hasTarget: Bool
    var showsRevert: Bool

    /// Single-window presets need a target; arrange presets always work.
    func isEnabled(_ preset: Preset) -> Bool {
        hasTarget || preset.kind == .arrange
    }

    /// The layout without disabled presets: keyboard navigation (`PaletteLayout.neighbor`)
    /// skips disabled presets like blanks.
    var enabledLayout: PaletteLayout {
        var enabled = layout
        for position in layout.readingOrder {
            guard let id = layout.presetID(at: position), let preset = PresetLibrary.preset(id: id),
                  !isEnabled(preset) else { continue }
            enabled.remove(at: position)
        }
        return enabled
    }
}

/// The live palette's layout in panel coordinates (y down), measured on Apple's green-button
/// menu (`docs/reference/apple-native-menu-{light,dark}@2x.png`) in native-menu points u and
/// scaled with the palette size through `PaletteMetrics.unit` — tiles, spacing and radii come
/// from `PaletteMetrics` (shared with the editor preview):
///
///     ┌──────────────────────────────────┐  header: 11u semibold, tertiary label color,
///     │  App — Window title              │          baseline 23.5u, left at the tile edge
///     │  [↶] [tile] [tile]  blank [tile] │  tiles:  first row at 33u, 16u side insets,
///     │      [tile] [tile] [tile] [tile] │          Revert in its own column at the far left
///     │  ────────────────────────────────│  separator: 9u below the tiles, 1u thick
///     │  ⚙  Tiler Settings…             │  footer: 13u regular, baseline 23.5u below the
///     └──────────────────────────────────┘          separator, panel ends 35u below it
struct PaletteGeometry {
    let metrics: PaletteMetrics
    let size: CGSize
    /// Well rows/columns of the palette (the bounding box of the occupied wells).
    let box: WellBox?
    let headerFont: NSFont
    let footerFont: NSFont
    /// Text box of the header line (baseline = `minY + headerFont.ascender`).
    let headerRect: CGRect
    /// Top-left of the well grid.
    let gridOrigin: CGPoint
    let revertRect: CGRect?
    let separatorRect: CGRect
    /// The footer row's hit and highlight rect.
    let footerRect: CGRect
    let footerIconCenter: CGPoint
    /// Baseline origin of "Tiler Settings…".
    let footerTextOrigin: CGPoint

    static let footerTitle = "Tiler Settings…"

    init(content: PaletteContent) {
        let metrics = PaletteMetrics(paletteSize: content.paletteSize)
        let u = metrics.unit
        let snap = PaletteMetrics.snap
        self.metrics = metrics
        box = content.layout.boundingBox
        headerFont = NSFont.systemFont(ofSize: 11 * u, weight: .semibold)
        footerFont = NSFont.systemFont(ofSize: 13 * u, weight: .regular)

        let rows = box?.rowCount ?? 0
        let columns = box?.columnCount ?? 0
        let tile = metrics.tile, gap = metrics.tileGap
        let gridWidth = columns > 0 ? CGFloat(columns) * tile.width + CGFloat(columns - 1) * gap : 0
        let gridHeight = rows > 0 ? CGFloat(rows) * tile.height + CGFloat(rows - 1) * gap : 0
        let revertWidth = content.showsRevert ? tile.width + (columns > 0 ? gap : 0) : 0
        let tilesWidth = revertWidth + gridWidth

        // Left margin shared by the header, separator and footer row — measured on the native
        // menu at 16u (SPEC 10.1; ink lands ≈1u further in from font side-bearing).
        let insetX = snap(16 * u)
        // Outer panel padding for the tile grid — measured on the native menu at 17u on both
        // sides (SPEC 10.1: panel interior 240u wide, 4 tiles of 45.5u + 3 gaps of 8u = 206u,
        // leaving 34u = 17u + 17u). Kept separate from `insetX`: the tile grid is centered in
        // the panel from this pad, while the header/separator/footer text hang off the panel's
        // left edge at `insetX`.
        let panelPad = snap(17 * u)
        let footerTextX = snap(20.25 * u)
        let footerTextWidth = (Self.footerTitle as NSString).size(withAttributes: [.font: footerFont]).width
        let footerWidth = footerTextX + ceil(footerTextWidth) + snap(12 * u)
        let contentWidth = (max(tilesWidth, footerWidth) * 2).rounded(.up) / 2
        let width = contentWidth + 2 * panelPad

        // Header line.
        let headerBaseline = snap(23.5 * u)
        headerRect = CGRect(x: insetX, y: headerBaseline - headerFont.ascender, width: contentWidth,
                            height: ceil(headerFont.ascender - headerFont.descender + headerFont.leading))

        // Tiles.
        let gridTop = snap(33 * u)
        let tilesX = panelPad + snap((contentWidth - tilesWidth) / 2)
        gridOrigin = CGPoint(x: tilesX + revertWidth, y: gridTop)
        revertRect = content.showsRevert
            ? CGRect(x: tilesX, y: gridTop + snap(max(gridHeight - tile.height, 0) / 2),
                     width: tile.width, height: tile.height)
            : nil
        let tilesBottom = gridTop + max(gridHeight, content.showsRevert ? tile.height : 0)

        // Separator and footer row: the separator spans the panel's own 16u side margins (1u /
        // 2 px thick at size 1.0 — the native menu's line, not a 0.5 px hairline).
        let separatorY = tilesBottom + (tilesBottom > gridTop ? snap(9 * u) : 0)
        separatorRect = CGRect(x: insetX, y: separatorY, width: width - 2 * insetX, height: snap(u))
        let height = separatorY + snap(35 * u)
        let rowInset = snap(5 * u)
        footerRect = CGRect(x: rowInset, y: separatorRect.maxY + rowInset,
                            width: width - 2 * rowInset,
                            height: height - separatorRect.maxY - 2 * rowInset)
        let footerBaseline = snap(separatorY + 23.5 * u)
        footerIconCenter = CGPoint(x: insetX + snap(6.5 * u), y: footerBaseline - footerFont.capHeight / 2)
        footerTextOrigin = CGPoint(x: insetX + footerTextX, y: footerBaseline)
        size = CGSize(width: width, height: height)
    }

    /// Tile rect of the well at absolute editor position `position`.
    func tileRect(_ position: WellPosition) -> CGRect? {
        guard let box, (box.minRow...box.maxRow).contains(position.row),
              (box.minColumn...box.maxColumn).contains(position.column) else { return nil }
        let tile = metrics.tile, gap = metrics.tileGap
        return CGRect(x: gridOrigin.x + CGFloat(position.column - box.minColumn) * (tile.width + gap),
                      y: gridOrigin.y + CGFloat(position.row - box.minRow) * (tile.height + gap),
                      width: tile.width, height: tile.height)
    }

    func rect(for item: PaletteItem) -> CGRect? {
        switch item {
        case .preset(let position): return tileRect(position)
        case .revert: return revertRect
        case .settings: return footerRect
        }
    }
}

/// The live palette's content (inside `GlassContainerView`): header, preset tiles drawn with
/// the shared `PresetIcon` renderer, the Revert tile, and the "Tiler Settings…" footer row.
///
/// Mouse: hovering selects (accent highlight, white icon, `PaletteToolTip` with the preset
/// name), a click activates. Keyboard (when the panel is key): ←→↑↓ move the selection across enabled
/// presets, skipping blanks and dimmed presets (`PaletteLayout.neighbor`; ← past the first
/// column reaches Revert, ↓ past the last row the footer), Return activates, 1–9 activate the
/// n-th preset in reading order, Esc cancels. Disabled presets never highlight or activate.
/// Each item is an accessibility button (identifiers `preset:<id>`, `revert`, `settings`), the
/// header static text `palette-header`.
final class PaletteView: NSView {
    private(set) var content: PaletteContent
    private(set) var geometry: PaletteGeometry

    /// The selected item (hover or keyboard); drawn with the accent highlight.
    var selection: PaletteItem? {
        didSet {
            guard selection != oldValue else { return }
            if case .preset(let position) = selection { lastColumn = position.column }
            needsDisplay = true
            updateAccessibilitySelection()
        }
    }

    /// Called when an enabled item is clicked or chosen with the keyboard.
    var onActivate: ((PaletteItem) -> Void)?
    /// Esc.
    var onCancel: (() -> Void)?

    private var lastColumn = 0
    private lazy var presetToolTip = PaletteToolTip()
    private var accessibilityItems: [PaletteItem: PaletteAccessibilityButton] = [:]
    private let headerElement = NSAccessibilityElement()

    init(content: PaletteContent) {
        self.content = content
        geometry = PaletteGeometry(content: content)
        super.init(frame: CGRect(origin: .zero, size: geometry.size))
        headerElement.setAccessibilityRole(.staticText)
        headerElement.setAccessibilityIdentifier("palette-header")
        headerElement.setAccessibilityParent(self)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Replaces the content (new opening) and resizes the view.
    func update(_ content: PaletteContent) {
        self.content = content
        geometry = PaletteGeometry(content: content)
        selection = nil
        presetToolTip.hide()
        setFrameSize(geometry.size)
        rebuild()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Model helpers

    func preset(at position: WellPosition) -> Preset? {
        content.layout.presetID(at: position).flatMap(PresetLibrary.preset(id:))
    }

    func isEnabled(_ item: PaletteItem) -> Bool {
        switch item {
        case .preset(let position): return preset(at: position).map(content.isEnabled) ?? false
        case .revert: return content.showsRevert
        case .settings: return true
        }
    }

    /// Every item, in reading order: Revert, the presets, the footer.
    private var items: [PaletteItem] {
        (content.showsRevert ? [.revert] : []) + content.layout.readingOrder.map { .preset($0) } + [.settings]
    }

    private func item(at point: CGPoint) -> PaletteItem? {
        items.first { geometry.rect(for: $0)?.contains(point) == true }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let appearance = effectiveAppearance

        // Header.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (content.header as NSString).draw(
            with: geometry.headerRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: geometry.headerFont, .foregroundColor: NSColor.tertiaryLabelColor,
                         .paragraphStyle: paragraph])

        // Presets.
        for position in content.layout.readingOrder {
            guard let preset = preset(at: position), let rect = geometry.tileRect(position),
                  rect.intersects(dirtyRect) else { continue }
            let ink: PresetIcon.Ink = !content.isEnabled(preset) ? .dimmed
                : selection == .preset(position) ? .highlighted : .normal
            PresetIcon.drawTile(preset, in: rect, metrics: geometry.metrics, ink: ink,
                                appearance: appearance, in: context)
        }

        // Revert.
        if let rect = geometry.revertRect {
            let selected = selection == .revert
            if selected {
                PresetIcon.fillHighlight(rect, radius: geometry.metrics.highlightRadius,
                                         appearance: effectiveAppearance, in: context)
            }
            drawSymbol("arrow.uturn.backward", pointSize: geometry.metrics.icon.height * 0.9, weight: .semibold,
                       color: selected ? .white : .labelColor, center: CGPoint(x: rect.midX, y: rect.midY))
        }

        // Separator.
        NSColor.separatorColor.setFill()
        geometry.separatorRect.fill()

        // Footer row.
        let footerSelected = selection == .settings
        if footerSelected {
            PresetIcon.fillHighlight(geometry.footerRect, radius: geometry.metrics.highlightRadius,
                                     appearance: effectiveAppearance, in: context)
        }
        let textColor: NSColor = footerSelected ? .white : .labelColor
        drawSymbol("gearshape", pointSize: geometry.footerFont.pointSize, weight: .regular, color: textColor,
                   center: geometry.footerIconCenter)
        let font = geometry.footerFont
        (PaletteGeometry.footerTitle as NSString).draw(
            at: CGPoint(x: geometry.footerTextOrigin.x, y: geometry.footerTextOrigin.y - font.ascender),
            withAttributes: [.font: font, .foregroundColor: textColor])
    }

    private func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, center: CGPoint) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let origin = CGPoint(x: ((center.x - size.width / 2) * 2).rounded() / 2,
                             y: ((center.y - size.height / 2) * 2).rounded() / 2)
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) {
        selection = nil
        presetToolTip.hide()
    }

    private func track(_ event: NSEvent) {
        let hovered = item(at: convert(event.locationInWindow, from: nil))
        selection = hovered.flatMap { isEnabled($0) ? $0 : nil }
        presetToolTip.hover(hovered.flatMap(toolTipText(for:)))
    }

    /// The tooltip of an item: the preset's name (dimmed presets too), "Revert"; none for the
    /// footer row, which has its title.
    private func toolTipText(for item: PaletteItem) -> String? {
        switch item {
        case .preset(let position): return preset(at: position)?.name
        case .revert: return "Revert"
        case .settings: return nil
        }
    }

    /// Hides the tooltip (the palette closes).
    func hideToolTip() {
        presetToolTip.hide()
    }

    override func mouseDown(with event: NSEvent) { track(event) }

    override func mouseUp(with event: NSEvent) {
        guard let item = item(at: convert(event.locationInWindow, from: nil)), isEnabled(item) else { return }
        presetToolTip.hide()
        onActivate?(item)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        presetToolTip.hide()
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch Int(event.keyCode) {
        case 53: onCancel?()
        case 36, 76: if let selection, isEnabled(selection) { onActivate?(selection) }
        case 123: move(.left)
        case 124: move(.right)
        case 125: move(.down)
        case 126: move(.up)
        default:
            // Other keys are swallowed silently, as in a menu.
            guard modifiers.isEmpty, let digit = Self.digitKeys[Int(event.keyCode)] else { return }
            let order = content.layout.readingOrder
            guard digit <= order.count else { return }
            let item = PaletteItem.preset(order[digit - 1])
            guard isEnabled(item) else { return }
            selection = item
            onActivate?(item)
        }
    }

    /// ⌘ / ⌃ shortcuts close the palette instead of reaching Tiler's main menu: the panel is key
    /// while another app is frontmost, so ⌘Q, ⌘W or ⌘, meant for that app must not quit Tiler or
    /// open its Settings.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !event.modifierFlags.intersection([.command, .control]).isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        onCancel?()
        return true
    }

    /// Number row and keypad digits 1–9 by key position, so every keyboard layout works
    /// (AZERTY types digits only with ⇧).
    private static let digitKeys: [Int: Int] = [
        0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5, 0x16: 6, 0x1A: 7, 0x1C: 8, 0x19: 9,
        0x53: 1, 0x54: 2, 0x55: 3, 0x56: 4, 0x57: 5, 0x58: 6, 0x59: 7, 0x5B: 8, 0x5C: 9,
    ]

    /// Arrow-key navigation over the enabled items.
    func move(_ direction: PaletteLayout.Direction) {
        let enabled = content.enabledLayout
        let order = enabled.readingOrder
        guard let selection else {
            // Like a menu opened from the keyboard: the first arrow selects the first item.
            self.selection = order.first.map { .preset($0) } ?? (content.showsRevert ? .revert : .settings)
            return
        }
        let bottomRow = (content.layout.boundingBox?.maxRow ?? 0) + 1
        switch selection {
        case .preset(let position):
            if let next = enabled.neighbor(of: position, direction: direction) {
                self.selection = .preset(next)
            } else if direction == .left, content.showsRevert {
                self.selection = .revert
            } else if direction == .down {
                self.selection = .settings
            }
        case .revert:
            let topRow = order.first?.row ?? 0
            switch direction {
            case .right:
                if let first = order.first(where: { $0.row == topRow }) { self.selection = .preset(first) }
            case .down:
                self.selection = .settings
            case .left, .up:
                break
            }
        case .settings:
            guard direction == .up else { return }
            if let above = enabled.neighbor(of: WellPosition(row: bottomRow, column: lastColumn), direction: .up) {
                self.selection = .preset(above)
            } else if content.showsRevert {
                self.selection = .revert
            }
        }
    }

    // MARK: Tooltips and accessibility

    private func rebuild() {
        var elements: [PaletteItem: PaletteAccessibilityButton] = [:]
        for item in items {
            guard let rect = geometry.rect(for: item) else { continue }
            let label: String
            let identifier: String
            switch item {
            case .preset(let position):
                guard let preset = preset(at: position) else { continue }
                label = preset.name
                identifier = "preset:\(preset.id)"
            case .revert:
                label = "Revert"
                identifier = "revert"
            case .settings:
                label = PaletteGeometry.footerTitle
                identifier = "settings"
            }
            let element = PaletteAccessibilityButton(item: item, view: self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(label)
            element.setAccessibilityTitle(label)
            element.setAccessibilityIdentifier(identifier)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(unflipped(rect))
            element.setAccessibilityEnabled(isEnabled(item))
            elements[item] = element
        }
        accessibilityItems = elements
        headerElement.setAccessibilityValue(content.header)
        headerElement.setAccessibilityLabel(content.header)
        headerElement.setAccessibilityFrameInParentSpace(unflipped(geometry.headerRect))
        updateAccessibilitySelection()
    }

    /// `NSAccessibilityElement` takes parent-space frames with the origin at the bottom left,
    /// even in a flipped view.
    private func unflipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: geometry.size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func updateAccessibilitySelection() {
        for (item, element) in accessibilityItems {
            element.setAccessibilitySelected(item == selection)
        }
    }

    /// Accessibility press: activates like a click.
    fileprivate func press(_ item: PaletteItem) -> Bool {
        guard isEnabled(item) else { return false }
        onActivate?(item)
        return true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Tiler palette" }
    override func accessibilityChildren() -> [Any]? {
        [headerElement] + items.compactMap { accessibilityItems[$0] }
    }
}

/// An accessibility button for one palette item. Nonisolated like its superclass; AppKit calls
/// accessibility on the main thread.
private nonisolated final class PaletteAccessibilityButton: NSAccessibilityElement {
    let item: PaletteItem
    nonisolated(unsafe) weak var view: PaletteView?

    init(item: PaletteItem, view: PaletteView) {
        self.item = item
        self.view = view
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        let item = self.item
        let view = self.view
        return MainActor.assumeIsolated { view?.press(item) ?? false }
    }
}
