import AppKit
import TilerCore

// Entry point. Flags: see `LaunchOptions` (SPEC §5). Without a render flag, Tiler runs as an
// accessory (menu-bar only) app.

let options: LaunchOptions
do {
    options = try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("Tiler: \(error)\n\(LaunchOptions.usage)\n".utf8))
    exit(2)
}

let store = ConfigStore(fileURL: options.configURL ?? ConfigStore.defaultFileURL)

switch options.mode {
case .renderPalette(let url):
    DebugRender.runAndExit { try DebugRender.palette(
        store: store, dark: options.dark, size: options.size, highlight: options.highlight,
        header: options.header, noTarget: options.noTarget, revert: options.revert, to: url) }
case .renderEditor(let url):
    DebugRender.runAndExit { try DebugRender.editor(store: store, dark: options.dark, to: url) }
case .run:
    let app = NSApplication.shared
    // Debug-only, undocumented (not a LaunchOptions flag): force the run mode into light or
    // dark appearance without touching System Settings, the same `app.appearance` override
    // DebugRender already uses for the headless render modes above. Exists so live glass tints
    // (GlassContainerView) can be measured and re-measured with `screencapture` regardless of
    // this Mac's actual system appearance.
    if let forced = ProcessInfo.processInfo.environment["TILER_FORCE_APPEARANCE"] {
        app.appearance = NSAppearance(named: forced == "light" ? .aqua : .darkAqua)
    }
    let delegate = AppDelegate(store: store, showsSettingsAtLaunch: options.showSettings)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
