import AppKit

/// The palette's tooltip (SPEC §4 "tooltip with the preset name"). AppKit's own tooltips
/// (`addToolTip`, `toolTip`) never appear on the palette: Tiler is never the active app while it
/// is open, and even `allowsToolTipsWhenApplicationIsInactive` does not bring them to a
/// nonactivating panel (verified on macOS 27). So this draws one like the system's: the
/// `.toolTip` material, the tooltip font, just below the pointer, after the usual hover delay —
/// immediately when moving on from a tile whose tooltip is showing. It costs nothing while the
/// pointer rests elsewhere: one one-shot timer per hovered tile.
final class PaletteToolTip {
    static let delay: TimeInterval = 0.8

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    /// The text the tooltip shows or is about to show.
    private(set) var text: String?

    init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "Tiler Tooltip"
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let material = NSVisualEffectView()
        material.material = .toolTip
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 5
        material.layer?.masksToBounds = true
        label.font = NSFont.toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        material.addSubview(label)
        panel.contentView = material
    }

    /// The pointer rests on an item named `text` (nil: on nothing). Shows the tooltip after the
    /// delay, or at once when another tooltip is already up.
    func hover(_ text: String?) {
        guard text != self.text else { return }
        let wasVisible = panel.isVisible
        self.text = text
        timer?.invalidate()
        timer = nil
        guard let text else {
            panel.orderOut(nil)
            return
        }
        if wasVisible {
            show(text)
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.show(text) }
            }
        }
    }

    func hide() {
        hover(nil)
    }

    private func show(_ text: String) {
        guard self.text == text else { return }
        label.stringValue = text
        label.sizeToFit()
        let padding = CGSize(width: 6, height: 3)
        let size = CGSize(width: ceil(label.frame.width) + 2 * padding.width,
                          height: ceil(label.frame.height) + 2 * padding.height)
        label.frame.origin = CGPoint(x: padding.width, y: padding.height)

        // Like the system's: left edge at the pointer, top ~22 pt below it; above it when there is
        // no room below, and kept on the pointer's screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: mouse.x, y: mouse.y - 22 - size.height)
        if origin.y < visible.minY { origin.y = mouse.y + 6 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        panel.setFrame(CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }
}
