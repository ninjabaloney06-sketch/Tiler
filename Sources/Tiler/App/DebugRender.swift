import AppKit
import TilerCore

/// `--render-palette` and `--render-editor` (SPEC §5): headless 2× PNGs of the palette and of
/// the settings window, so visuals can be inspected without screen-recording permission.
/// Nothing is shown on screen and the config file is only read.
enum DebugRender {
    static let scale: CGFloat = 2

    /// Runs one render, reports the result and exits (0 on success, 1 on failure).
    static func runAndExit(_ render: () throws -> URL) -> Never {
        do {
            let url = try render()
            print("wrote \(url.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Tiler: render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The live palette (`PaletteSnapshotView`: header, wells as configured with blanks as space,
    /// the "Tiler Settings…" footer) in its glass panel with shadow, on the backdrop of the
    /// native reference captures (white / #212121). `header` names the target (default
    /// "TilerTestWindows — TW1"); `noTarget` renders the "No window" state with single-window
    /// presets dimmed; `revert` renders with move history (a Revert well enabled, else dimmed); `highlight` selects the n-th preset
    /// (reading order, 0-based).
    static func palette(store: ConfigStore, dark: Bool, size: Double?, highlight: Int?, header: String?,
                        noTarget: Bool, revert: Bool, to url: URL) throws -> URL {
        let appearance = prepareApp(dark: dark)
        let range = TilerSettings.paletteSizeRange
        let scale = size.map { min(max($0, range.lowerBound), range.upperBound) }
            ?? store.config.settings.paletteSize
        let layout = store.config.palette
        let content = PaletteContent(
            layout: layout, paletteSize: scale,
            header: noTarget ? PaletteTarget.noWindowHeader : header ?? "TilerTestWindows — TW1",
            hasTarget: !noTarget, hasHistory: revert)
        let palette = PaletteSnapshotView(content: content)
        if let highlight {
            let order = layout.readingOrder
            guard order.indices.contains(highlight) else {
                throw RenderError("--highlight \(highlight): the palette has \(order.count) presets")
            }
            palette.paletteView.selection = .preset(order[highlight])
        }
        let backdrop = NSView(frame: CGRect(origin: .zero, size: palette.frame.size))
        backdrop.wantsLayer = true
        let level: CGFloat = dark ? 0x21 / 255.0 : 1
        backdrop.layer?.backgroundColor = CGColor(srgbRed: level, green: level, blue: level, alpha: 1)
        backdrop.addSubview(palette)

        let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = backdrop
        try snapshot(backdrop, to: url)
        window.close()
        return url
    }

    /// The whole settings window (titlebar area included) as it looks at its fixed size.
    static func editor(store: ConfigStore, dark: Bool, to url: URL) throws -> URL {
        let appearance = prepareApp(dark: dark)
        let window = SettingsWindowController.makeWindow(store: store, loginItem: LoginItem())
        window.appearance = appearance
        guard let content = window.contentView else { throw RenderError("window has no content view") }
        // The frame view also holds the titlebar and the traffic lights.
        try snapshot(content.superview ?? content, to: url)
        window.close()
        return url
    }

    private static func prepareApp(dark: Bool) -> NSAppearance? {
        GlassContainerView.usesStaticMaterial = true
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        app.appearance = appearance
        return appearance
    }

    /// Lets AppKit/SwiftUI lay out and draw, then writes `view` at 2× as PNG.
    private static func snapshot(_ view: NSView, to url: URL) throws {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        view.window?.contentView?.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()

        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded()),
            pixelsHigh: Int((bounds.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw RenderError("could not allocate the bitmap") }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RenderError("PNG encoding failed")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    struct RenderError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
