import AppKit
import TilerCore

/// Accessory (menu-bar only) app: owns the config store, the status item and the settings
/// window, and runs `PaletteController` unless paused.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The running app's delegate; nil in the headless render modes. The palette's
    /// "Tiler Settings…" row opens Settings with `AppDelegate.shared?.showSettings()`.
    private(set) static weak var shared: AppDelegate?

    private let store: ConfigStore
    private let showsSettingsAtLaunch: Bool
    private lazy var settings = SettingsWindowController(store: store)
    private var statusMenu: StatusMenu?

    init(store: ConfigStore, showsSettingsAtLaunch: Bool = false) {
        self.store = store
        self.showsSettingsAtLaunch = showsSettingsAtLaunch
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusMenu = StatusMenu(
            onSettings: { [weak self] in self?.showSettings() },
            onPause: { [weak self] paused in self?.setPaused(paused) })
        PaletteController.shared.start(config: store)
        if showsSettingsAtLaunch { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PaletteController.shared.stop()
    }

    /// `open` on the running app (Finder, Spotlight, install.sh) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Shows the settings window and activates Tiler (from the status menu, ⌘, the palette's
    /// footer, reopening the app, or `--show-settings`).
    @objc func showSettings(_ sender: Any? = nil) {
        settings.show()
    }

    private func setPaused(_ paused: Bool) {
        if paused {
            PaletteController.shared.stop()
        } else {
            PaletteController.shared.start(config: store)
        }
    }

    /// Minimal main menu, visible while the settings window is active: ⌘, ⌘Q, editing keys for
    /// the text field, ⌘W / ⌘M.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Tiler")
        app.addItem(withTitle: "About Tiler",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Tiler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        for submenu in [app, edit, window] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.windowsMenu = window
        return main
    }
}
