import AppKit
import SwiftUI
import TilerCore

extension NSPasteboard.PasteboardType {
    /// A preset dragged from the library; the string is the preset id.
    static let tilerPreset = NSPasteboard.PasteboardType("dev.ninja.tiler.preset-id")
    /// A preset dragged out of a well; the string is the preset id.
    static let tilerWell = NSPasteboard.PasteboardType("dev.ninja.tiler.well")
}

/// Metrics and drawing of one well (measured from `docs/reference/half_top.jpg` at 2×: wells
/// 38 pt square on a 43 pt pitch, 1 pt border, ~6 pt corner radius). Icons are the palette's
/// Apple-style icons (SPEC §4) at palette size 1.0, shrunk only if they would not fit.
enum Well {
    static let size: CGFloat = 38
    static let spacing: CGFloat = 5
    static let cornerRadius: CGFloat = 6
    /// Icon size in wells and library rows: at most 26 × 20 pt.
    static let iconSize: CGSize = {
        let reference = IconGeometry.iconSize(paletteSize: 1)
        let k = min(1, 26 / reference.width, 20 / reference.height)
        return IconGeometry.iconSize(paletteSize: k)
    }()

    /// Size of the whole 11 × 6 grid.
    static let gridSize = CGSize(
        width: CGFloat(PaletteLayout.columns) * size + CGFloat(PaletteLayout.columns - 1) * spacing,
        height: CGFloat(PaletteLayout.rows) * size + CGFloat(PaletteLayout.rows - 1) * spacing)

    enum Style {
        /// Outside the palette's bounding box.
        case empty
        /// Part of the palette: occupied, or blank space inside the bounding box.
        case shown
    }

    /// Draws a well into a y-down context. `iconAlpha` < 1 fades the icon (a well being dragged).
    static func draw(in context: CGContext, rect: CGRect, style: Style, preset: Preset?,
                     theme: EditorTheme, iconAlpha: CGFloat = 1) {
        let fill = style == .shown ? theme.wellShownFill : theme.wellEmptyFill
        let border = style == .shown ? theme.wellShownBorder : theme.wellEmptyBorder
        let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: cornerRadius - 0.5, cornerHeight: cornerRadius - 0.5, transform: nil)
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(border.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        if let preset {
            // Centered, snapped to the 2× pixel grid.
            let origin = CGPoint(x: rect.minX + ((rect.width - iconSize.width)).rounded() / 2,
                                 y: rect.minY + ((rect.height - iconSize.height)).rounded() / 2)
            let ink = PresetIcon.color(.normal, appearance: PresetIcon.appearance(dark: theme.isDark))
            PresetIcon.draw(preset, size: iconSize, at: origin,
                            color: ink.copy(alpha: ink.alpha * iconAlpha) ?? ink, in: context)
        }
    }

    /// A 2× image of an occupied well, used as the drag image.
    static func image(for preset: Preset, dark: Bool) -> NSImage {
        let scale: CGFloat = 2
        let pixels = Int(size * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: rep)
        else { return NSImage(size: NSSize(width: size, height: size)) }
        rep.size = NSSize(width: size, height: size)
        let context = graphics.cgContext
        // Flip to the y-down space the drawing code uses.
        context.translateBy(x: 0, y: size * scale)
        context.scaleBy(x: scale, y: -scale)
        draw(in: context, rect: CGRect(x: 0, y: 0, width: size, height: size), style: .shown,
             preset: preset, theme: EditorTheme(dark: dark))
        context.flush()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// What the editor's drag and drop does to the layout (SPEC §5), apart from AppKit's drag
/// machinery so it can be exercised headless.
enum WellDrop {
    enum Source: Equatable {
        /// A library row; the preset id.
        case library(String)
        /// A well of the grid.
        case well(WellPosition)
    }

    /// The layout after dropping `source` onto the well `target`, or nil when the drop is
    /// refused (unknown preset id; a library preset that is not placed yet onto an occupied
    /// well).
    ///
    /// - library → empty well: adds. A library preset that already sits in a well moves there
    ///   instead, swapping with an occupied target.
    /// - well → well: moves; onto an occupied well: swaps.
    static func result(dropping source: Source, onto target: WellPosition, in layout: PaletteLayout) -> PaletteLayout? {
        var next = layout
        switch source {
        case .well(let from):
            guard next.move(from: from, to: target) else { return nil }
        case .library(let id):
            guard PresetLibrary.preset(id: id) != nil else { return nil }
            if let placed = next.position(of: id) {
                next.move(from: placed, to: target)
            } else if !next.add(id, at: target) {
                return nil
            }
        }
        return next
    }

    /// The layout after the preset at `position` is removed: a well dragged anywhere but onto a
    /// well (the library, the rest of the window, other apps), or right-click › Remove.
    static func removing(_ position: WellPosition, from layout: PaletteLayout) -> PaletteLayout {
        var next = layout
        next.remove(at: position)
        return next
    }
}

/// The editor's 11 × 6 wells (SPEC §2, §5). AppKit, because it is both drag source and drop
/// target and must see how a drag ends: a well dropped anywhere except on a well — outside the
/// grid, on the library, outside the window — is removed.
///
/// - library → well: adds (only onto an empty well); a preset that is already placed moves,
///   swapping with an occupied target.
/// - well → well: moves; onto an occupied well: swaps.
/// - well → anywhere else, or right-click → Remove: removes.
///
/// While a drag is over the grid, the wells show the layout the drop would produce, so the
/// palette's bounding box (white wells) updates live.
///
/// Accessibility: the grid is a group `editor-wells` with one child per well, identifier
/// `well:<row>-<column>`, value = the preset id ("" when empty), so live tests can find each
/// well's screen frame and read the committed layout back.
final class WellGridView: NSView, NSDraggingSource, NSViewToolTipOwner {
    /// The committed layout (the store's).
    var layout = PaletteLayout() {
        didSet {
            guard layout != oldValue else { return }
            rebuildToolTips()
            updateAccessibilityWells()
            needsDisplay = true
        }
    }

    /// Receives every edit. The view has already switched to the new layout.
    var onChange: ((PaletteLayout) -> Void)?

    /// Result of the drag in flight; drawn instead of `layout`.
    private var pendingLayout: PaletteLayout? { didSet { needsDisplay = true } }
    private var dropTarget: WellPosition? { didSet { needsDisplay = true } }
    /// Source well of a drag that started here.
    private var draggedFrom: WellPosition?
    private var draggedID: String?
    private var dropAccepted = false
    private var mouseDownPoint: CGPoint?
    /// One accessibility element per well.
    private var accessibilityWells: [WellPosition: NSAccessibilityElement] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.tilerPreset, .tilerWell])
        setUpAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Well.gridSize }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var theme: EditorTheme {
        EditorTheme(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Geometry

    private func rect(of position: WellPosition) -> CGRect {
        CGRect(x: CGFloat(position.column) * (Well.size + Well.spacing),
               y: CGFloat(position.row) * (Well.size + Well.spacing),
               width: Well.size, height: Well.size)
    }

    /// The well at `point`. `strict` = only inside a well's square; otherwise the gaps count
    /// toward the nearest well (drops never fall into a crack).
    private func position(at point: CGPoint, strict: Bool = false) -> WellPosition? {
        guard bounds.contains(point) else { return nil }
        let pitch = Well.size + Well.spacing
        let column = min(max(Int((point.x + Well.spacing / 2) / pitch), 0), PaletteLayout.columns - 1)
        let row = min(max(Int((point.y + Well.spacing / 2) / pitch), 0), PaletteLayout.rows - 1)
        let position = WellPosition(row: row, column: column)
        if strict && !rect(of: position).contains(point) { return nil }
        return position
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let theme = self.theme
        let shown = pendingLayout ?? layout
        let box = shown.boundingBox
        for row in 0..<PaletteLayout.rows {
            for column in 0..<PaletteLayout.columns {
                let position = WellPosition(row: row, column: column)
                let wellRect = rect(of: position)
                guard wellRect.intersects(dirtyRect) else { continue }
                let id = shown.presetID(at: position)
                let inBox = box.map {
                    ($0.minRow...$0.maxRow).contains(row) && ($0.minColumn...$0.maxColumn).contains(column)
                } ?? false
                // The well a drag started from, while the drop would leave everything in place.
                let lifted = position == draggedFrom && pendingLayout?.presetID(at: position) == draggedID
                Well.draw(in: context, rect: wellRect, style: inBox ? .shown : .empty,
                          preset: id.flatMap(PresetLibrary.preset(id:)), theme: theme,
                          iconAlpha: lifted ? 0.3 : 1)
                if position == dropTarget {
                    let ring = CGPath(roundedRect: wellRect.insetBy(dx: 1, dy: 1),
                                      cornerWidth: Well.cornerRadius - 1, cornerHeight: Well.cornerRadius - 1,
                                      transform: nil)
                    context.addPath(ring)
                    context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                    context.setLineWidth(2)
                    context.strokePath()
                }
            }
        }
    }

    // MARK: Tooltips and cursor

    private func rebuildToolTips() {
        removeAllToolTips()
        for position in layout.wells.keys {
            addToolTip(rect(of: position), owner: self, userData: nil)
        }
        window?.invalidateCursorRects(for: self)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        position(at: point, strict: true)
            .flatMap { layout.presetID(at: $0) }
            .flatMap(PresetLibrary.preset(id:))?.name ?? ""
    }

    override func resetCursorRects() {
        for position in layout.wells.keys {
            addCursorRect(rect(of: position), cursor: .openHand)
        }
    }

    // MARK: Accessibility

    private func setUpAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Palette wells")
        setAccessibilityIdentifier("editor-wells")
        var children: [NSAccessibilityElement] = []
        for row in 0..<PaletteLayout.rows {
            for column in 0..<PaletteLayout.columns {
                let position = WellPosition(row: row, column: column)
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityIdentifier("well:\(row)-\(column)")
                element.setAccessibilityParent(self)
                // Parent-space frames have the origin at the bottom left, even in a flipped view.
                let wellRect = rect(of: position)
                element.setAccessibilityFrameInParentSpace(CGRect(
                    x: wellRect.minX, y: Well.gridSize.height - wellRect.maxY,
                    width: wellRect.width, height: wellRect.height))
                accessibilityWells[position] = element
                children.append(element)
            }
        }
        setAccessibilityChildren(children)
        updateAccessibilityWells()
    }

    private func updateAccessibilityWells() {
        for (position, element) in accessibilityWells {
            let id = layout.presetID(at: position)
            element.setAccessibilityValue(id ?? "")
            element.setAccessibilityLabel(id.flatMap(PresetLibrary.preset(id:))?.name ?? "Empty well")
        }
    }

    // MARK: Right-click → Remove

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let position = position(at: point, strict: true), layout.presetID(at: position) != nil
        else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove", action: #selector(removeFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [position.row, position.column]
        menu.addItem(item)
        return menu
    }

    @objc private func removeFromMenu(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        let next = WellDrop.removing(WellPosition(row: pair[0], column: pair[1]), from: layout)
        if next != layout {
            commit(next)
        }
    }

    private func commit(_ next: PaletteLayout) {
        layout = next
        onChange?(next)
    }

    // MARK: Drag source (well → elsewhere)

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, draggedFrom == nil,
              let source = position(at: start, strict: true),
              let id = layout.presetID(at: source), let preset = PresetLibrary.preset(id: id)
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
        mouseDownPoint = nil

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id, forType: .tilerWell)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(rect(of: source), contents: Well.image(for: preset, dark: theme.isDark))
        draggedFrom = source
        draggedID = id
        dropAccepted = false
        pendingLayout = layout
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Nothing outside the app may take the preset; a drop there ends with no operation,
        // which removes it.
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let source = draggedFrom
        draggedFrom = nil
        draggedID = nil
        dropTarget = nil
        pendingLayout = nil
        guard !dropAccepted, let source else { return }
        // Dropped outside the wells (library, rest of the window, other apps, desktop): remove.
        let next = WellDrop.removing(source, from: layout)
        if next != layout {
            commit(next)
        }
    }

    // MARK: Drop target (library → well, well → well)

    /// What a drop at the dragging location would do, or nil if it would do nothing.
    private func resolveDrop(_ info: NSDraggingInfo) -> (target: WellPosition, layout: PaletteLayout, operation: NSDragOperation)? {
        let point = convert(info.draggingLocation, from: nil)
        guard let target = position(at: point) else { return nil }
        let source: WellDrop.Source
        if (info.draggingSource as AnyObject?) === self, let from = draggedFrom {
            source = .well(from)
        } else if let id = info.draggingPasteboard.string(forType: .tilerPreset) {
            source = .library(id)
        } else {
            return nil
        }
        guard let next = WellDrop.result(dropping: source, onto: target, in: layout) else { return nil }
        if case .well = source { return (target, next, .move) }
        return (target, next, .copy)
    }

    private func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let drop = resolveDrop(info) else {
            dropTarget = nil
            pendingLayout = draggedFrom.map { layoutWithoutDragged($0) }
            return []
        }
        dropTarget = drop.target
        if pendingLayout != drop.layout { pendingLayout = drop.layout }
        return drop.operation
    }

    /// The layout a well drag would leave behind if dropped outside the wells.
    private func layoutWithoutDragged(_ source: WellPosition) -> PaletteLayout {
        WellDrop.removing(source, from: layout)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget = nil
        pendingLayout = draggedFrom.map { layoutWithoutDragged($0) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        resolveDrop(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let drop = resolveDrop(sender) else { return false }
        if (sender.draggingSource as AnyObject?) === self {
            dropAccepted = true
        }
        dropTarget = nil
        pendingLayout = nil
        if drop.layout != layout {
            commit(drop.layout)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropTarget = nil
        if draggedFrom == nil { pendingLayout = nil }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropTarget = nil
        if draggedFrom == nil { pendingLayout = nil }
    }
}

/// SwiftUI host of `WellGridView`.
struct WellGrid: NSViewRepresentable {
    let layout: PaletteLayout
    let onChange: (PaletteLayout) -> Void

    func makeNSView(context: Context) -> WellGridView {
        let view = WellGridView(frame: CGRect(origin: .zero, size: Well.gridSize))
        view.layout = layout
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WellGridView, context: Context) {
        view.onChange = onChange
        view.layout = layout
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WellGridView, context: Context) -> CGSize? {
        Well.gridSize
    }
}

/// Makes a library row draggable: an AppKit drag source (so the drag carries our own pasteboard
/// type and a well-shaped drag image) laid over the row.
struct LibraryDragSource: NSViewRepresentable {
    let presetID: String
    let toolTip: String

    func makeNSView(context: Context) -> LibraryDragSourceView {
        let view = LibraryDragSourceView(presetID: presetID)
        view.toolTip = toolTip
        return view
    }

    func updateNSView(_ view: LibraryDragSourceView, context: Context) {
        view.presetID = presetID
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}

/// Accessibility: a button `library:<preset id>` labelled with the preset's name (live tests
/// find the row's screen frame by it).
final class LibraryDragSourceView: NSView, NSDraggingSource {
    var presetID: String {
        didSet { if presetID != oldValue { updateAccessibility() } }
    }
    private var mouseDownPoint: CGPoint?

    init(presetID: String) {
        self.presetID = presetID
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityIdentifier("library:\(presetID)")
        setAccessibilityLabel(PresetLibrary.preset(id: presetID)?.name ?? presetID)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let preset = PresetLibrary.preset(id: presetID) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
        mouseDownPoint = nil

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(presetID, forType: .tilerPreset)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let frame = CGRect(x: point.x - Well.size / 2, y: point.y - Well.size / 2,
                           width: Well.size, height: Well.size)
        item.setDraggingFrame(frame, contents: Well.image(for: preset, dark: dark))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}
