import AppKit
import SwiftUI
import TilerCore

/// The single settings window (SPEC §5): SwiftUI `EditorView` in an `NSHostingController`,
/// fixed size, sidebar under a transparent unified titlebar. Created on first use and kept, so
/// reopening brings the same window to the front.
final class SettingsWindowController {
    private let store: ConfigStore
    private let loginItem = LoginItem()
    private var window: NSWindow?
    private var shownOnce = false

    init(store: ConfigStore) {
        self.store = store
    }

    /// Shows the window and activates the app (an accessory app is not active on its own).
    func show() {
        let window = self.window ?? {
            let window = Self.makeWindow(store: store, loginItem: loginItem)
            window.center()
            window.setFrameAutosaveName("TilerSettings")
            // The autosaved frame may come from a build with another fixed size; keep its position only.
            window.setContentSize(EditorView.Layout.windowSize)
            self.window = window
            return window
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // No text field focused on first open (the inset field would grab it and show a focus ring).
        if !shownOnce {
            window.makeFirstResponder(nil)
            shownOnce = true
        }
    }

    /// Builds the window without showing it (also used by `--render-editor`).
    static func makeWindow(store: ConfigStore, loginItem: LoginItem) -> NSWindow {
        let hosting = NSHostingController(rootView: EditorView(store: store, loginItem: loginItem))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: EditorView.Layout.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "Tiler Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar gives the 52 pt titlebar the sidebar layout expects.
        window.toolbar = NSToolbar(identifier: "TilerSettings")
        window.toolbarStyle = .unified
        window.setContentSize(EditorView.Layout.windowSize)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        return window
    }
}
