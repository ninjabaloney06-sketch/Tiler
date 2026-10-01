import AppKit
import ApplicationServices
import CoreGraphics
import TilerCore

/// Owns the live palette and its two default triggers (SPEC §4.A menu-bar icon, §4.B global
/// hotkey). Interface per SPEC §7: the AppDelegate calls `start(config:)` at launch and when
/// Tiler is resumed, `stop()` on pause and quit; the status item calls
/// `statusItemClicked(button:)` on a left mouse-down.
///
/// Every opening captures the target first (`TargetResolver`, before anything can change
/// focus), then shows a `PalettePanel` that never activates Tiler: under the status item, or
/// centered on the target (hotkey; the panel becomes key so the keyboard works). A preset is
/// applied through `AXWindowEngine.apply` (target optional), then the palette fades out.
/// Dismissal: a click outside, Esc, the trigger again, applying a preset, the target window
/// closing, or another app becoming active.
///
/// Idle cost: nothing runs while the palette is closed — the Carbon hotkey and two notification
/// observers only; event monitors and the target watcher exist only while it is open.
final class PaletteController {
    static let shared = PaletteController()

    /// Where the palette appears.
    enum Placement {
        /// SPEC §4.A: a dropdown under the menu-bar icon, aligned like the status menu.
        case statusItem(NSStatusBarButton)
        /// SPEC §4.B: centered on the target window (AX rect), else on `screen`.
        case centered(on: CGRect?, screen: NSScreen)
        /// SPEC §4.C: directly below an AX rect (the green button), for the hover trigger.
        case below(CGRect)
    }

    private(set) var isRunning = false
    /// The palette currently on screen (nil while closed or fading out).
    private(set) var session: Session?

    /// True while a palette opened by another trigger (menu-bar icon or hotkey — any placement
    /// other than `.below`) is on screen. The hover trigger (C5) checks this before detecting a
    /// new hover or touching the open session, so it never steals or closes a palette it did not
    /// open (SPEC §4.C step 1).
    var hasNonHoverSessionOpen: Bool {
        guard let session else { return false }
        if case .below = session.placement { return false }
        return true
    }

    /// The open palette's panel frame (NSScreen coordinates), for the hover trigger's hot region
    /// (SPEC §4.C step 7) — but only while the open session is the hover trigger's own (`.below`
    /// placement); nil while closed, or while a foreign session (another trigger's palette) is
    /// open, so that palette is never folded into the hover trigger's hot region.
    var hoverPaletteFrame: CGRect? {
        guard let session, case .below = session.placement else { return nil }
        return panel.frame
    }

    private var store: ConfigStore?
    private let hotkey = HotkeyTrigger()
    private var isRecordingHotkey = false
    private var notificationObservers: [NSObjectProtocol] = []
    private lazy var panel = PalettePanel()
    private lazy var glass = GlassContainerView(cornerRadius: 16)
    private var paletteView: PaletteView?
    /// Bumped on every show/dismiss so an outdated fade-out does not hide a newer palette.
    private var generation = 0
    /// True if the last applied preset was an arrange (Revert then undoes the whole arrange).
    private var lastApplyWasArrange = false

    /// State of one opening.
    struct Session {
        let target: PaletteTarget
        let placement: Placement
        /// The frontmost app at trigger time; another app becoming active dismisses.
        let frontmostPID: pid_t
        /// System uptime when the palette appeared (same clock as `NSEvent.timestamp`).
        let shownAt: TimeInterval
        /// `NSEvent` monitors.
        var monitors: [Any] = []
        /// `NSWorkspace` notification observers.
        var workspaceObservers: [NSObjectProtocol] = []
        var watcher: TargetCloseWatcher?
        /// Non-nil only for a non-key session (`.statusItem` / `.below` — SPEC §4.A/§4.C): consumes
        /// the Esc key so it never reaches whichever app owns the keyboard. See `EscConsumingTap`.
        var escTap: EscConsumingTap?
    }

    private init() {}

    // MARK: Lifecycle (SPEC §7)

    /// Registers the hotkey from `config` and keeps it (and the engine's settings) in sync with
    /// `.tilerConfigDidChange`. The palette reads presets and size from `config` on every opening,
    /// so editor changes apply without a restart.
    func start(config: ConfigStore) {
        if isRunning { stop() }
        store = config
        isRunning = true
        AXWindowEngine.shared.settings = config.config.settings
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        registerHotkey()
        // SPEC §4.C: the opt-in hover trigger (C5) follows the same start/stop lifecycle as the
        // hotkey — live config changes, pause/resume, and quit all funnel through here already.
        HoverMonitor.shared.start(config: config)

        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: .tilerConfigDidChange, object: config, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.configDidChange() }
            },
            center.addObserver(forName: .tilerHotkeyRecordingDidChange, object: nil, queue: .main) { [weak self] note in
                let recording = note.userInfo?["isRecording"] as? Bool ?? false
                MainActor.assumeIsolated { self?.hotkeyRecordingDidChange(recording) }
            },
        ]
    }

    /// Unregisters the hotkey and dismisses any visible palette (pause, quit).
    func stop() {
        dismiss(animated: false)
        hotkey.unregister()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers = []
        // `.tilerHotkeyRecordingDidChange` is no longer observed once stopped, so this flag can
        // go stale: Pause while Settings is mid-recording (the Settings window stays key, so
        // recording continues), then Esc — the recorder's `isRecording = false` reaches nobody
        // here. Reset it so a later `start()` (Resume) re-registers the hotkey instead of
        // leaving it unregistered until the next recording session.
        isRecordingHotkey = false
        isRunning = false
        store = nil
        HoverMonitor.shared.stop()
    }

    private func configDidChange() {
        guard let store else { return }
        AXWindowEngine.shared.settings = store.config.settings
        if hotkey.registered != store.config.settings.paletteHotkey { registerHotkey() }
    }

    /// While Settings records a new shortcut the hotkey is suspended, so pressing the current one
    /// reaches the recorder instead of opening the palette.
    private func hotkeyRecordingDidChange(_ recording: Bool) {
        isRecordingHotkey = recording
        registerHotkey()
    }

    private func registerHotkey() {
        guard isRunning, !isRecordingHotkey, let wanted = store?.config.settings.paletteHotkey else {
            hotkey.unregister()
            return
        }
        let status = hotkey.register(wanted)
        if status != noErr {
            FileHandle.standardError.write(Data("Tiler: palette hotkey \(wanted) not registered (OSStatus \(status))\n".utf8))
        }
    }

    // MARK: Triggers

    /// Left-click on the menu-bar icon (SPEC §4.A): toggles the palette under `button`.
    func statusItemClicked(button: NSStatusBarButton) {
        guard isRunning else { return }
        if session != nil {
            dismiss(animated: true)
            return
        }
        let screen = button.window?.screen ?? NSScreen.screens.first
        guard let screen else { return }
        let target = TargetResolver.capture(fallbackScreen: screen)
        present(target: target, placement: .statusItem(button), keyboard: false)
    }

    /// Shows the status item's pill for as long as its palette session is on screen (SPEC §4.A
    /// "menu-like dropdown" — every native status menu, Tiler's own classic menu included, keeps
    /// its icon highlighted while open); `dismiss` clears it on every dismissal path. `StatusMenu`
    /// calls this from its `.leftMouseUp` handling, dispatched (not called directly) so the pill
    /// comes up strictly AFTER that same click's own mouse-up tracking has ended — mid-tracking
    /// it would sit under the cell's own press highlight.
    ///
    /// The pill is a drawn overlay (`StatusItemPillView` in StatusMenu.swift), not
    /// `NSStatusBarButton.highlight(_:)`: on macOS 26 (Liquid Glass) that flag is a visual no-op
    /// for status-bar items — see `StatusItemPillView`'s doc comment.
    func statusItemMouseUpDidFinish(button: NSStatusBarButton) {
        guard let session, case .statusItem(let sessionButton) = session.placement, sessionButton === button else { return }
        StatusItemPill.show(on: button)
    }

    /// The global hotkey (SPEC §4.B): toggles the palette centered on the target, with keyboard.
    func hotkeyPressed() {
        guard isRunning else { return }
        if session != nil {
            dismiss(animated: true)
            return
        }
        let mouse = ScreenGeometry.flip(NSEvent.mouseLocation)
        guard let mouseScreen = ScreenGeometry.screen(containing: mouse) ?? NSScreen.screens.first else { return }
        let target = TargetResolver.capture(fallbackScreen: mouseScreen)
        present(target: target, placement: .centered(on: target.frame, screen: target.screen), keyboard: true)
    }

    // MARK: Showing

    /// Shows the palette for `target` (already captured) at `placement`. `keyboard`: the panel
    /// becomes key (without activating Tiler) and takes the arrow keys, Return, 1–9 and Esc.
    func present(target: PaletteTarget, placement: Placement, keyboard: Bool) {
        guard let store else { return }
        dismiss(animated: false)
        generation += 1

        let engine = AXWindowEngine.shared
        let config = store.config
        let showsRevert = engine.hasArrangeHistory || (target.window.map(engine.hasHistory) ?? false)
        let content = PaletteContent(layout: config.palette, paletteSize: config.settings.paletteSize,
                                     header: target.header, hasTarget: target.hasWindow, showsRevert: showsRevert)
        let view: PaletteView
        if let existing = paletteView {
            existing.update(content)
            view = existing
        } else {
            view = PaletteView(content: content)
            paletteView = view
        }
        view.onActivate = { [weak self] item in self?.activate(item) }
        view.onCancel = { [weak self] in self?.dismiss(animated: true) }

        let size = view.geometry.size
        glass.cornerRadius = view.geometry.metrics.cornerRadius
        glass.contentView = view
        glass.frame = CGRect(origin: .zero, size: size)
        // `existing.update(content)` above already set the reused view's frame to `size`
        // directly (`setFrameSize`). `glass.frame` then resizes `materialView`, whose
        // [.width, .height] autoresizing mask (pre-macOS 26 `NSVisualEffectView`; `installContent`
        // in GlassContainerView) adds that same size delta to the view a second time, so on the
        // first opening after the palette size setting changes the view ends up larger (growing)
        // or smaller (shrinking) than `size` — the flipped content then draws shifted/clipped
        // (header or footer cut off). `NSGlassEffectView` (macOS 26+) re-fits its contentView
        // instead, so this doesn't show there. Pin the view back to the container's bounds after
        // both resizes have happened.
        view.frame = CGRect(origin: .zero, size: size)
        panel.contentView = glass
        panel.setFrame(frame(for: size, placement: placement, target: target), display: false)
        panel.allowsKey = keyboard
        panel.invalidateShadow()
        if case .below = placement {
            // SPEC §4.C step 5: "after the hover delay, fade the palette in (~100 ms)" — only
            // the hover trigger fades on the way in (4.A/4.B show at once, matching the native
            // menu). `PalettePanel.animationBehavior = .none` only suppresses AppKit's automatic
            // order-in/out animations; the explicit `.animator()` proxy below still animates
            // (dismiss already relies on the same mechanism for the fade-out).
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let current = generation
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // A dismiss (or a newer `present`) during the fade-in already drives its own
                    // alphaValue (and may already have ordered the panel out); don't stomp that
                    // by forcing alpha back to 1 here. `dismiss(animated:)` bumps `generation`.
                    guard let self, self.generation == current else { return }
                    self.panel.alphaValue = 1
                }
            })
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        if keyboard {
            panel.makeKey()
            panel.makeFirstResponder(view)
        }

        var session = Session(target: target, placement: placement,
                              frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? target.pid,
                              shownAt: ProcessInfo.processInfo.systemUptime)
        session.monitors = installMonitors(keyboard: keyboard, placement: placement)
        // Critic gap: for the non-key panel (§4.A menu-bar, §4.C hover) a passive
        // `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` can only observe Esc, not stop
        // it — the keystroke that closed the palette also reached whichever app owned the
        // keyboard underneath (Terminal, a Save sheet, Finder rename, Safari full-screen video),
        // unlike every native status menu. An active tap can consume it instead (verified live,
        // see `EscConsumingTap`'s doc comment); the keyboard session (§4.B) needs none of this —
        // its key panel already owns Esc.
        if !keyboard {
            session.escTap = EscConsumingTap { [weak self] in self?.dismiss(animated: true) }
        }
        session.workspaceObservers = [observeActivation()]
        if let window = target.window {
            session.watcher = TargetCloseWatcher(window: window, pid: target.pid) { [weak self] in
                self?.dismiss(animated: true)
            }
        }
        self.session = session
    }

    /// The panel frame (NSScreen coordinates) for a palette of `size`, clamped into the screen's
    /// visibleFrame (flipped/moved so it stays fully on screen).
    private func frame(for size: CGSize, placement: Placement, target: PaletteTarget) -> CGRect {
        let screen: NSScreen
        var origin: CGPoint
        switch placement {
        case .statusItem(let button):
            screen = button.window?.screen ?? target.screen
            // Measured on the native status menu (macOS 27): its left edge sits 12 pt left of the
            // item, its top flush with the bottom of the menu bar (`visibleFrame.maxY`).
            let item = screenFrame(of: button) ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
            origin = CGPoint(x: item.minX - 12, y: min(item.minY, screen.visibleFrame.maxY) - size.height)
        case .centered(let rect, let fallback):
            screen = rect.flatMap(ScreenGeometry.screen(forWindowFrame:)) ?? fallback
            let center: CGPoint
            if let rect {
                let flipped = ScreenGeometry.flip(rect)
                center = CGPoint(x: flipped.midX, y: flipped.midY)
            } else {
                center = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
            }
            origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        case .below(let rect):
            let flipped = ScreenGeometry.flip(rect)
            screen = ScreenGeometry.screen(containing: CGPoint(x: rect.midX, y: rect.midY)) ?? target.screen
            origin = CGPoint(x: flipped.minX, y: flipped.minY - size.height)
            if origin.y < screen.visibleFrame.minY { origin.y = flipped.maxY }
        }
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        // Whole points on the 2× grid keep the icons crisp.
        return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: size.width, height: size.height)
    }

    // MARK: Dismissal

    /// Hides the palette: a ~100 ms fade in place, or at once.
    func dismiss(animated: Bool) {
        guard let session else { return }
        self.session = nil
        // SPEC §4.A "menu-like dropdown": drop the status item's pill (see
        // `statusItemMouseUpDidFinish`) on every dismissal path — Esc, click outside, apply, a
        // second icon click, target closed, the classic menu, Pause (`stop`). `.leftMouseUp` on
        // that same button right after this (the second icon click) finds no session and no-ops,
        // so the pill does not flicker back on.
        if case .statusItem(let button) = session.placement { StatusItemPill.hide(on: button) }
        for monitor in session.monitors { NSEvent.removeMonitor(monitor) }
        for observer in session.workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        session.watcher?.invalidate()
        session.escTap?.invalidate()
        paletteView?.selection = nil
        paletteView?.hideToolTip()
        generation += 1
        let current = generation
        let panel = self.panel
        guard animated, panel.isVisible else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    /// Event monitors that exist only while the palette is open.
    private func installMonitors(keyboard: Bool, placement: Placement) -> [Any] {
        var monitors: [Any] = []
        // Clicks in other apps (global monitors need no permission for mouse events). The real
        // HID mouse-down on the status item arrives HERE (the system menu-bar host receives it);
        // AppKit then sends the button a synthesized click ~15–25 ms later. A plain left click on
        // the icon of a menu-bar session is therefore left to `statusItemClicked`, which toggles
        // the palette closed — dismissing it here too made that click reopen it at once.
        // (Global events have no window: `locationInWindow` is in screen coordinates.)
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                let timestamp = event.timestamp
                let location = event.locationInWindow
                let isPlainLeftClick = event.type == .leftMouseDown && !event.modifierFlags.contains(.control)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isPlainLeftClick, self.isOnSessionStatusItem(location) { return }
                    self.dismissForOutsideClick(at: timestamp)
                }
            }) {
            monitors.append(monitor)
        }
        // Clicks in Tiler's own windows other than the palette (status item, Settings). A
        // mouse-down that hit the status item that opened this session is left alone here: the
        // button's own target-action (`statusItemClicked`) already toggles the palette for that
        // click, so dismissing it here too would race the reopen and (with a time-based guard
        // against that race) also swallow the next, unrelated status-item click.
        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window !== self.panel else { return }
                    if case .statusItem(let button) = placement, event.window === button.window { return }
                    self.dismissForOutsideClick(at: event.timestamp)
                }
                return event
            }) {
            monitors.append(monitor)
        }
        // Esc for the non-key panel is handled by `EscConsumingTap` (installed by `present`
        // alongside these monitors, torn down by `dismiss`), not a monitor here — see its doc
        // comment for why a monitor cannot do this job.
        return monitors
    }

    /// A mouse-down outside the palette closes it — only one that happened after the palette
    /// appeared: the click on the menu-bar icon that opened it can reach the global monitor late
    /// (the menu bar forwards it), and must not close it again.
    private func dismissForOutsideClick(at timestamp: TimeInterval) {
        guard let session, timestamp > session.shownAt else { return }
        dismiss(animated: true)
    }

    /// True if `point` (NSScreen coordinates) lies on the status item that opened the current
    /// session (menu-bar placement only).
    private func isOnSessionStatusItem(_ point: CGPoint) -> Bool {
        guard let session, case .statusItem(let button) = session.placement,
              let item = screenFrame(of: button) else { return false }
        return item.contains(point)
    }

    /// The status item button's frame in NSScreen coordinates (nil while it has no window).
    private func screenFrame(of button: NSStatusBarButton) -> CGRect? {
        button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
    }

    /// Another app became active (⌘-Tab, Dock, a click that activates): the palette closes.
    private func observeActivation() -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let session = self.session, pid != session.frontmostPID else { return }
                self.dismiss(animated: true)
            }
        }
    }

    // MARK: Actions

    private func activate(_ item: PaletteItem) {
        switch item {
        case .preset(let position):
            guard let id = store?.config.palette.presetID(at: position),
                  let preset = PresetLibrary.preset(id: id) else { return }
            apply(preset)
        case .revert:
            revert()
        case .settings:
            // Critic gap, reproduced live 3/3 runs (mouse AND keyboard): opening the hotkey
            // palette (§4.B, panel key but Tiler not active) and picking "Tiler Settings…" left
            // Settings behind the frontmost window with Tiler never active. Root cause verified
            // live with debug instrumentation: the new `NSApp.activate()` (called by
            // `SettingsWindowController.show()`) is silently refused whenever the app's most
            // recent key window was THIS nonactivating panel — reordering dismiss/show around it
            // does not help, and it fails identically for a Return keypress and a mouse click.
            // Forcing it here with the pre-macOS-14 `activate(ignoringOtherApps:)` — verified
            // live to activate Tiler reliably for both input devices — makes the plain
            // `NSApp.activate()` inside `show()` a harmless no-op by the time it runs, so the
            // fix stays in this file rather than reaching into C4's SettingsWindow.swift.
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.shared?.showSettings()
            dismiss(animated: false)
        }
    }

    /// Applies `preset` to the target (single-window presets need one; arrange presets act on the
    /// target's screen, else the trigger's screen), then fades the palette out.
    private func apply(_ preset: Preset) {
        guard let session else { return }
        let target = session.target
        guard target.hasWindow || preset.kind == .arrange else { return }
        let result = AXWindowEngine.shared.apply(preset: preset, hoveredWindow: target.window, screen: target.screen)
        if !result.moves.isEmpty {
            lastApplyWasArrange = preset.kind == .arrange
            // SPEC §4.C step 8: the hover trigger's target can be a background (non-frontmost)
            // window (hit-test based, no frontmost check) — a single-window preset applied to it
            // must raise it, or ninja sees the frame change on a window he can't see.
            if case .below = session.placement, preset.kind != .arrange, let window = target.window {
                AXWindowEngine.shared.raise(window)
            }
        }
        dismiss(animated: true)
    }

    /// Restores the frames from before Tiler's last move: the whole last arrange if that was the
    /// last action (or the target has no history of its own), else the target window.
    private func revert() {
        guard let session else { return }
        let engine = AXWindowEngine.shared
        let window = session.target.window
        let windowHasHistory = window.map(engine.hasHistory) ?? false
        if engine.hasArrangeHistory && (lastApplyWasArrange || !windowHasHistory) {
            engine.revertLastArrange()
        } else if let window, windowHasHistory {
            engine.revert(window)
        }
        lastApplyWasArrange = false
        dismiss(animated: true)
    }
}

/// Consumes the Esc key while a non-key palette session (§4.A menu-bar, §4.C hover) is open, so
/// — unlike a passive `NSEvent` global monitor, which can only observe an event, never stop it —
/// the keystroke that dismisses the palette never reaches whichever app currently owns the
/// keyboard underneath it.
///
/// Critic gap, reproduced live: with a TilerTestWindows window frontmost and Terminal running
/// behind it, clicking the menu-bar icon then pressing Esc closed the palette AND delivered Esc
/// to Terminal. `NSWorkspace.frontmostApplication`/`AXUIElementCopyAttributeValue(kAXFocusedApplicationAttribute)`
/// during an open non-key session showed the frontmost/focused app is that other app the whole
/// time — Tiler's panel is never key for this trigger (SPEC §4.C step 5 forbids making it key),
/// so it never owns the keyboard, and a monitor only observes what the system already decided to
/// deliver elsewhere.
///
/// Fix: an active `CGEventTap` at `.cgSessionEventTap`/`.headInsertEventTap` (upstream of
/// per-app delivery), returning `nil` for keyCode 53 to drop it before the window server hands it
/// onward — the same trick every native status/context menu relies on. This needs only the
/// Accessibility trust Tiler already requires; no separate Input Monitoring grant (verified live:
/// `CGEventTapCreate` for a session-wide key tap returns non-nil under AX trust alone). Proven
/// with a standalone round-trip: a listen-only tap one station further down, at
/// `.cgAnnotatedSessionEventTap` (the last stop before per-app delivery), saw a synthetic Esc
/// when this tap let it through and never saw it when this tap returned `nil` instead — the same
/// technique `tiler-palettetest`'s tightened check 1b now uses to prove the real palette's tap
/// keeps Esc off the helper. Both keyDown and keyUp for keycode 53 are dropped, so no app ends up
/// with an unmatched key-up.
///
/// Created in `present`, invalidated in `dismiss`: idle cost is zero while no non-key session is
/// open.
final class EscConsumingTap {
    private static let escapeKeyCode: Int64 = 53

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate let onEscape: () -> Void

    /// nil if `CGEventTapCreate` fails (no Accessibility trust) — `present` then simply has no
    /// active session tap, matching the previous (passive-monitor) behaviour rather than crashing.
    init?(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: escConsumingTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Called on the main thread (AppKit's run loop) by `escConsumingTapCallback`, which has
    /// already read `keycode` out of the `CGEvent` itself — `CGEvent` is not `Sendable`, so it
    /// cannot be captured into this `MainActor`-isolated call from the tap's `nonisolated`
    /// callback. Returns whether to swallow the event. Both the keyDown and the keyUp of an Esc
    /// press are swallowed; `onEscape` (`dismiss(animated:)`, which invalidates this very tap)
    /// only runs once the keyUp has also been swallowed, dispatched rather than called inline —
    /// verified live (round-tripped through a downstream listen-only tap, 5/5 runs) that
    /// invalidating the port/source synchronously on keyDown, still inside this callback's own
    /// frame, tears the tap down before the matching keyUp — posted milliseconds later — arrives,
    /// and that keyUp then leaks through to whatever app owns the keyboard; waiting for keyUp
    /// removes the race instead of racing it, since nothing is left to protect once both halves
    /// are already consumed by the time invalidation runs.
    fileprivate func handle(type: CGEventType, keycode: Int64) -> Bool {
        // The system disables a tap that is too slow to answer, or on user request; re-enable it
        // rather than leaving Esc unconsumed for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard keycode == Self.escapeKeyCode else { return false }
        if type == .keyUp {
            let dismiss = onEscape
            DispatchQueue.main.async { dismiss() }
        }
        return true
    }

    /// Torn down explicitly by `dismiss` on every path (including `stop()`, which calls
    /// `dismiss`); not repeated in `deinit`, which — unlike this MainActor-isolated class's other
    /// methods — always runs in a nonisolated context and cannot call it synchronously.
    func invalidate() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
    }
}

/// C function pointer for `CGEvent.tapCreate` (no captures allowed); hands off to the
/// `EscConsumingTap` passed as `userInfo`. The tap's run-loop source is added to the main run
/// loop, so — like Carbon's `hotkeyEventHandler` in `HotkeyTrigger.swift` — this always runs on
/// the main thread. Reads `keycode` from `event` here, before crossing into the `MainActor`-
/// isolated `handle`, because `CGEvent` itself is not `Sendable`.
private nonisolated func escConsumingTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    // Like `HotkeyTrigger.swift`'s `hotkeyEventHandler`: pass the pointer across as a plain
    // `UInt` address (a trivially Sendable value), not the pointer type itself, and rebuild it
    // inside the isolated closure — see that function's doc comment.
    let address = UInt(bitPattern: userInfo)
    let swallow = MainActor.assumeIsolated {
        let tap = Unmanaged<EscConsumingTap>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
        return tap.handle(type: type, keycode: keycode)
    }
    return swallow ? nil : Unmanaged.passRetained(event)
}
