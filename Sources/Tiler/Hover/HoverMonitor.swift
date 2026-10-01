import AppKit
import ApplicationServices
import TilerCore

/// Opt-in green-button hover trigger (SPEC §4.C). Active only while
/// `TilerSettings.hoverTriggerEnabled` is true — `start(config:)`/`stop()` are called from
/// `PaletteController.start`/`.stop` (the pause/resume/quit hook already wired to `AppDelegate`,
/// SPEC §7), and this class reacts to `.tilerConfigDidChange` on its own so the trigger turns on
/// and off live: zero monitors installed while the setting is off.
///
/// Pipeline (SPEC §4.C steps 1–8; proven in `docs/research.md` CRITIC section and
/// `tools/probes/poster.swift`):
/// 1. A global `.mouseMoved` monitor (no permission needed for mouse events), throttled to 40 ms
///    leading-edge, with one trailing query scheduled for the end of the window whenever an
///    event is dropped by the throttle — otherwise a fast straight move that stops mid-window
///    loses its final on-button event, the cursor rests with nothing left to re-trigger a query,
///    and Apple's native menu wins the ~0.6 s race unopposed.
/// 2. `AXUIElementCopyElementAtPosition(systemWide, …)` at the AX point, with the engine's 0.1 s
///    messaging timeout: accept role AXButton with subrole AXFullScreenButton or AXZoomButton.
///    The window is the button's `kAXWindowAttribute` (not `kAXParent`, a titlebar AXGroup); skip
///    when the window is `AXFullScreen`.
/// 3. If ⌘ is held at detection (inverted by `showMacOSMenuByDefault`), do nothing — the native
///    menu shows on its own ~0.9 s schedule; releasing ⌘ before it appears just lets the hat go
///    up and suppress that still-pending timer instead, so whichever wins the race wins cleanly.
///    Once the native menu is actually on screen, `nativeMenuIsOpen()` — a ground-truth
///    `CGWindowList` check, done only on a button hit — keeps the hat/palette away for as long
///    as it stays up: it does not close itself on ⌘ release or a mere cursor move, only on Esc
///    or a click, so a later tick, even after the cursor left this button and came back (or
///    landed on a different one), must not let Tiler's own UI appear over it (critic gap: the
///    prior "remembered per button, holds until the cursor leaves it" version was dropped the
///    instant the cursor left, exactly when the native menu is most likely already open).
/// 4. Otherwise immediately order front `HatPanel` over the button rect inflated by 3 pt — this
///    suppresses the native menu with no `defaults write`.
/// 5. After `hoverDelay`, show the palette under the button through
///    `PaletteController.shared.present(target:placement:keyboard:)` — the `.below` placement
///    and the target/dismiss plumbing were already there for this trigger (SPEC §7).
/// 6. The hat's `mouseUp` toggles full screen (forwarded on release, not on press — see the
///    ghost-hat note on `HatPanel`: forwarding on `mouseDown` let `dismissNow`'s `hat.orderOut`
///    race the window server's own full-screen mouse-tracking, since the AX set below still ran
///    while the mouse button was physically held down, and lost 4/6 times, leaving a real hat
///    window on screen that AppKit believed already hidden). For an `AXFullScreenButton`, `AXPress`
///    on a button under a resting cursor is unreliable once the window has round-tripped through
///    full screen once (returns success or -25204 without moving the window — measured 8/14
///    failures on a release build; a probe-owned hat with no Tiler at all reproduces it, so it is
///    an AX quirk of that subrole, not a bug in the hit-test or the forward): set the window's
///    (undocumented) `"AXFullScreen"` attribute to the inverse of its current value instead,
///    which is reliable (3/3, 15–26 ms). `AXPress` remains the primary path for `AXZoomButton` (green
///    buttons on non-full-screen-capable windows), and is the fallback if the `AXFullScreen` set
///    itself fails.
/// 7. Own-process events never reach the global monitor once the cursor is over the hat or the
///    palette, so leaving the hot region is tracked two ways instead: the hat's own
///    `NSTrackingArea` (`.activeAlways, .mouseEnteredAndExited, .mouseMoved`, immediate), and a
///    local `.mouseMoved` monitor (fires for events delivered to any of our own windows,
///    including the palette panel `Sources/Tiler/Palette` owns, without adding a tracking area
///    there). Both re-check the cursor against the hot region (button + hat + palette, with a
///    small corridor tolerance) and (re)start a 250 ms grace timer. The local monitor also fires
///    with `event.window == nil` whenever Tiler is the active app and the cursor is over another
///    app's window (Settings focused, say) — the global monitor is not delivered those events at
///    all, so those `window == nil` events are fed into the same throttled detection path as
///    step 1, or the trigger would go dead while Settings — the only place to turn it on — has
///    focus. This local monitor therefore runs the whole time hover is enabled, not just during
///    an open hover session.
/// 8. Applying a preset, hover highlight on a tile, tooltips, etc. are `PaletteController`'s job;
///    this class only supplies the hovered window as target and the `.below` placement.
///
/// Known simplification: a palette dismissal that does not originate here (Esc, a click outside,
/// another app activating, the target closing, applying a preset) is not observed directly —
/// `PaletteController` exposes no such signal and adding one was out of scope for a "minimal
/// hook". The hat then lingers (still correctly suppressing the native menu and forwarding
/// clicks) until the mouse leaves the hot region, or the target window moves/closes/resizes
/// (`TargetCloseWatcher`, `Sources/Tiler/Palette/TargetResolver.swift`, which every one of those
/// actions triggers in practice), or the setting is turned off.
@MainActor
final class HoverMonitor {
    static let shared = HoverMonitor()

    /// SPEC §4.C step 1: 30–50 ms.
    private static let throttleInterval: TimeInterval = 0.04
    /// SPEC §4.C step 4.
    private static let hatInset: CGFloat = 3
    /// SPEC §4.C step 7.
    private static let dismissGrace: TimeInterval = 0.25
    /// SPEC §4.C step 7: watched in addition to destruction so the hat's frame doesn't go stale
    /// while the target window moves or resizes under it.
    private static let watchedNotifications = [
        kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
    ]
    /// Small slack around the hat/palette/corridor union, in points — only enough to swallow
    /// rounding and event-timing jitter, NOT a general margin. SPEC §4.C step 7's hot region is
    /// "button rect + hat + palette + corridor between them", not their bounding box padded by a
    /// wide uniform inset: a flat 24 pt inset here used to reach most of the way up a window
    /// (palette sits flush under the button — AX button bottom 224, palette top 223 by default —
    /// so a 24 pt margin above the palette's top edge covered the whole titlebar strip and the
    /// space above the window), so leaving along the titlebar never dismissed the palette. See
    /// `isInsideHotRegion` for the actual corridor rect.
    private static let hotRegionSlack: CGFloat = 2

    /// Hit-tested at the AX point on every throttled `.mouseMoved` tick; timeout set once here
    /// (SPEC §3), not per call — `AXUIElementCreateSystemWide()` as a `static let` is the
    /// documented Swift 6 trap (SPEC §0), so this is a plain instance property set from `init`.
    private let systemWide: AXUIElement

    private var store: ConfigStore?
    private var configObserver: NSObjectProtocol?
    private var enabled = false

    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var lastQueryAt: TimeInterval = 0
    /// Set only while an event has been dropped by the throttle and no later event has fired
    /// the trailing query yet (SPEC §4.C step 1) — nil whenever the cursor is idle, so no timer
    /// runs with nothing moving.
    private var trailingQueryWork: DispatchWorkItem?

    private let hat = HatPanel()
    private var window: AXUIElement?
    private var button: AXUIElement?
    /// `button`'s subrole, captured once at detection time — read again on click, not on every
    /// throttled tick (SPEC §4.C step 6: `AXFullScreenButton` toggles `AXFullScreen`, everything
    /// else forwards `AXPress`).
    private var buttonSubrole: String?
    /// The hat's rect (NSScreen space) — half of the hot region test (SPEC §4.C step 7).
    private var hatFrame: CGRect?
    private var watcher: TargetCloseWatcher?
    private var showPaletteWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?

    private init() {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, AX.messagingTimeout)
        systemWide = element
        hat.onPress = { [weak self] in self?.pressGreenButton() }
        hat.onEnter = { [weak self] in self?.cancelDismiss() }
        hat.onExit = { [weak self] in self?.scheduleDismissIfOutside() }
        hat.onMoved = { [weak self] in self?.scheduleDismissIfOutside() }
    }

    // MARK: Lifecycle

    /// Starts observing `config`; installs the global monitor only if
    /// `settings.hoverTriggerEnabled` is already true, and whenever it changes afterwards.
    func start(config: ConfigStore) {
        store = config
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .tilerConfigDidChange, object: config, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncEnabled() }
            }
        }
        syncEnabled()
    }

    /// Tears down everything: the config observer, the global monitor, and any open hover
    /// session (hat, local monitor, watcher, pending timers).
    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        store = nil
        setEnabled(false)
    }

    private func syncEnabled() {
        setEnabled(store?.config.settings.hoverTriggerEnabled ?? false)
    }

    private func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            installGlobalMonitor()
            installLocalMonitor()
        } else {
            dismissNow()
            uninstallGlobalMonitor()
            uninstallLocalMonitor()
        }
    }

    private func installGlobalMonitor() {
        guard globalMoveMonitor == nil else { return }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.globalMouseMoved() }
        }
    }

    private func uninstallGlobalMonitor() {
        if let globalMoveMonitor { NSEvent.removeMonitor(globalMoveMonitor) }
        globalMoveMonitor = nil
        trailingQueryWork?.cancel()
        trailingQueryWork = nil
    }

    /// Installed for as long as hover is enabled (paired with the global monitor, not only while
    /// a hover session is open) — see the class doc's step 7 note: it both tracks the hot-region
    /// exit for an open session and, via `event.window == nil`, stands in for the global monitor
    /// while Tiler is the active app.
    private func installLocalMonitor() {
        guard localMoveMonitor == nil else { return }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.localMouseMoved(event) }
            return event
        }
    }

    private func uninstallLocalMonitor() {
        if let localMoveMonitor { NSEvent.removeMonitor(localMoveMonitor) }
        localMoveMonitor = nil
    }

    // MARK: Steps 1–3: detection

    private func globalMouseMoved() {
        // A global event firing at all means the cursor is no longer over one of our own windows
        // (SPEC §4.C step 7's "own windows don't receive global-monitor events"), so it always
        // doubles as a "maybe outside the hot region" signal, throttle or not.
        scheduleDismissIfOutside()
        detectHoverThrottled()
    }

    /// The global monitor above goes silent while Tiler is the active app (Settings focused,
    /// say): mouse moves over another app's window then arrive only here, as local events with
    /// `event.window == nil` (see the class doc's step 7 note). Route those into the same
    /// throttled detection path; events for one of our own windows (`event.window != nil`) still
    /// feed the hot-region check but never detection, matching the global monitor's behaviour.
    private func localMouseMoved(_ event: NSEvent) {
        scheduleDismissIfOutside()
        guard event.window == nil else { return }
        detectHoverThrottled()
    }

    private func detectHoverThrottled() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastQueryAt >= Self.throttleInterval else {
            // Leading-edge-only throttling drops every event inside the window, including a
            // fast straight move's last event if it happens to land there — the cursor then
            // rests with no further events to re-trigger a query, so the hat never goes up and
            // Apple's native menu wins the race (SPEC §4.C step 1). Schedule one trailing query
            // at the end of the current window instead; a later throttled event replaces it
            // rather than stacking another timer, so an idle cursor leaves nothing scheduled.
            scheduleTrailingQuery()
            return
        }
        lastQueryAt = now
        trailingQueryWork?.cancel()
        trailingQueryWork = nil
        queryHoverTarget(at: NSEvent.mouseLocation)
    }

    private func scheduleTrailingQuery() {
        trailingQueryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireTrailingQuery() }
        trailingQueryWork = work
        let deadline = lastQueryAt + Self.throttleInterval
        let delay = max(deadline - ProcessInfo.processInfo.systemUptime, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fireTrailingQuery() {
        trailingQueryWork = nil
        lastQueryAt = ProcessInfo.processInfo.systemUptime
        // Read the cursor fresh rather than the location captured when this was scheduled: if
        // the cursor kept moving, later events already replaced this timer (see above); if it
        // stopped, `NSEvent.mouseLocation` at fire time IS the resting point (SPEC §4.C step 1:
        // "schedule ONE trailing hit-test at NSEvent.mouseLocation at the end of the throttle
        // window").
        queryHoverTarget(at: NSEvent.mouseLocation)
    }

    private func queryHoverTarget(at location: CGPoint) {
        guard !isInsideOwnWindow(location), let settings = store?.config.settings else { return }
        // A palette opened by the menu-bar icon or the hotkey is already on screen — hover must
        // not detect a new target while it's up: `beginHover` would show the hat and, after the
        // delay, `showPalette` would call `PaletteController.present(.below)`, which replaces
        // whatever is currently open (integration defect: moving the cursor across a green
        // button on the way to an open hotkey/menu-bar palette closed or swapped it).
        guard !PaletteController.shared.hasNonHoverSessionOpen else { return }
        guard let hit = hitTestButton(at: location) else { return }
        // Apple's own menu, once actually on screen, does not close on ⌘ release or a mere
        // cursor move — only Esc or a click do that (SPEC §4.C step 3) — so it can still be open
        // long after the cursor left this exact button and came back, or landed on a different
        // one entirely. Ground truth, not "has the cursor stayed on the same button since ⌘ was
        // detected" (the prior, insufficient check — critic gap: that hold was dropped the
        // instant the cursor left, which is exactly when the real menu is most likely already
        // up). Checked only here, on an actual button hit, so it costs nothing the rest of the
        // time the cursor is moving but not over a green button.
        guard !nativeMenuIsOpen() else { return }
        let cmdHeld = NSEvent.modifierFlags.contains(.command)
        let showsTilerPalette = settings.showMacOSMenuByDefault ? cmdHeld : !cmdHeld
        // ⌘ held now (or the inverted setting) → do nothing and let the native menu's own timer
        // run its course; there is nothing to remember across ticks for this — if ⌘ gets
        // released before that timer fires, the next tick's `beginHover` below puts the hat up
        // and suppresses it instead (step 4), and if it fires first, `nativeMenuIsOpen()` above
        // is what keeps the hat/palette off afterwards, however long the cursor lingers or comes
        // back.
        guard showsTilerPalette else { return }
        beginHover(
            window: hit.window, button: hit.button, subrole: hit.subrole, pid: hit.pid,
            axButtonFrame: hit.frame, delay: settings.hoverDelay
        )
    }

    /// SPEC §4.C step 3's ground truth for whether Apple's own green-button menu is on screen
    /// right now: an on-screen window owned by `ThemeWidgetControlViewService` at the pop-up-menu
    /// level (SPEC §8, `docs/research.md` CRITIC section). Not cached and not window-scoped —
    /// only one such menu can exist system-wide at a time, and it is checked fresh on every
    /// button hit rather than remembered, since nothing short of Esc or a click ever closes it.
    private func nativeMenuIsOpen() -> Bool {
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return info.contains {
            $0[kCGWindowOwnerName as String] as? String == "ThemeWidgetControlViewService"
                && $0[kCGWindowLayer as String] as? Int == popUpLevel
        }
    }

    /// SPEC §4.C step 1's "skip when the cursor is inside any of our own windows" — a defensive
    /// check on top of the fact that a global monitor is not delivered those events at all.
    /// A frame-containment test is wrong here: it ignores stacking order, so a green button that
    /// merely sits inside a large background Tiler window's frame (e.g. Settings, which can
    /// cover most of the screen) reads as "own" even while some other app's window is on top of
    /// it there. Ask the window server which window is actually topmost at the point instead —
    /// `belowWindowWithWindowNumber: 0` starts from the very front — and only call it "own" when
    /// that topmost window number belongs to one of our own visible windows.
    private func isInsideOwnWindow(_ screenPoint: CGPoint) -> Bool {
        let topNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard topNumber != 0 else { return false }
        return NSApp.windows.contains { $0.isVisible && $0.windowNumber == topNumber }
    }

    private struct ButtonHit {
        let button: AXUIElement
        let window: AXUIElement
        let pid: pid_t
        /// AX space.
        let frame: CGRect
        /// `kAXFullScreenButtonSubrole` or `kAXZoomButtonSubrole` — which of the two determines
        /// how a click on the hat is forwarded (SPEC §4.C step 6).
        let subrole: String
    }

    /// SPEC §4.C step 2. `TILER_ONLY_PIDS`-filtered like every other window touch (SPEC §0), so a
    /// live test run never shows the hat/palette over a window outside its own test helper.
    private func hitTestButton(at screenPoint: CGPoint) -> ButtonHit? {
        let axPoint = ScreenGeometry.flip(screenPoint)
        var value: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &value) == .success,
              let value
        else { return nil }
        let button = AX.prepare(value)
        guard AX.string(button, kAXRoleAttribute) == kAXButtonRole else { return nil }
        guard let subrole = AX.string(button, kAXSubroleAttribute),
              subrole == kAXFullScreenButtonSubrole || subrole == kAXZoomButtonSubrole
        else { return nil }
        guard let window = AXWindowEngine.shared.window(ofButton: button), !AXWindowEngine.shared.isFullScreen(window)
        else { return nil }
        guard let pid = AX.pid(window), WindowEnumerator.isAllowed(pid: pid) else { return nil }
        guard let frame = AX.frame(button) else { return nil }
        return ButtonHit(button: button, window: window, pid: pid, frame: frame, subrole: subrole)
    }

    // MARK: Steps 4–5: hat, then the palette

    private func beginHover(
        window: AXUIElement, button: AXUIElement, subrole: String, pid: pid_t, axButtonFrame: CGRect,
        delay: TimeInterval
    ) {
        if let current = self.window, CFEqual(current, window) { return }
        if self.window != nil { dismissNow() }

        self.window = window
        self.button = button
        self.buttonSubrole = subrole
        let screenFrame = ScreenGeometry.flip(axButtonFrame.insetBy(dx: -Self.hatInset, dy: -Self.hatInset))
        hatFrame = screenFrame
        hat.setFrame(screenFrame, display: true)
        hat.orderFrontRegardless()

        // Reuses `TargetCloseWatcher` (`Sources/Tiler/Palette/TargetResolver.swift`), which by
        // default only watches destruction, with the move/resize notifications hover also needs
        // (the hat's frame would otherwise go stale) — rather than a second, near-identical
        // AXObserver wrapper.
        watcher = TargetCloseWatcher(window: window, pid: pid, notifications: Self.watchedNotifications) {
            [weak self] in self?.dismissNow()
        }

        let work = DispatchWorkItem { [weak self] in self?.showPalette(for: window, axButtonFrame: axButtonFrame) }
        showPaletteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: work)
    }

    private func showPalette(for window: AXUIElement, axButtonFrame: CGRect) {
        showPaletteWork = nil
        guard self.window.map({ CFEqual($0, window) }) == true else { return }
        // `beginHover` only checks the target window is unchanged, never that the cursor is
        // still on the button — without this, `hoverDelay` did not work as a hover delay at all:
        // a cursor that crossed the button on its way to, say, minimize still got the palette
        // (100+ ms after it had already left) and it stayed open while the cursor sat elsewhere.
        // `isInsideHotRegion` is the wrong check here: its corridor tolerance, meant for the gap
        // between the hat and the palette once both exist, is wide enough to still read a
        // neighbouring titlebar button as "inside". Require the cursor be on the hat right now
        // instead, and end the whole session (hides the hat too) otherwise.
        guard hatFrame?.contains(NSEvent.mouseLocation) == true else {
            dismissNow()
            return
        }
        // Another trigger's palette may have opened during the hover delay (e.g. the hotkey
        // pressed while the cursor sat on the button) — `present(.below)` below would replace
        // it, so end this hover session instead (SPEC §4.C step 1).
        guard !PaletteController.shared.hasNonHoverSessionOpen else {
            dismissNow()
            return
        }
        let screen = AXWindowEngine.shared.screen(of: window) ?? ScreenGeometry.screen(forWindowFrame: axButtonFrame)
        guard let screen else { return }
        let target = TargetResolver.target(for: window, fallbackScreen: screen)
        PaletteController.shared.present(target: target, placement: .below(axButtonFrame), keyboard: false)
    }

    // MARK: Step 6: click-through

    private func pressGreenButton() {
        guard let button else { return }
        // The window is about to move (full screen / un-full-screen); no need for the pending
        // palette to appear on top of that. `TargetCloseWatcher` dismisses the rest once the
        // resize notification arrives.
        showPaletteWork?.cancel()
        showPaletteWork = nil
        // `AXPress` on an `AXFullScreenButton` under a resting cursor is unreliable once the
        // window has round-tripped through full screen once — it returns `.success` (or
        // `-25204`) without the window ever changing state (measured 8/14 failures on a release
        // build; reproduces with a probe-owned hat and no Tiler at all, so it's an AX quirk of
        // this subrole/cursor combination, not this class). Toggling `AXFullScreen` on the window
        // directly from the same `mouseUp` is reliable (3/3, 15–26 ms); fall back to `AXPress`
        // if the set itself fails. `AXZoomButton` (non-full-screen-capable windows) has no such
        // attribute and always goes through `AXPress`.
        if buttonSubrole == kAXFullScreenButtonSubrole, let window {
            let wasFullScreen = AXWindowEngine.shared.isFullScreen(window)
            if AX.set(window, "AXFullScreen", NSNumber(value: !wasFullScreen)) { return }
        }
        AX.perform(button, kAXPressAction)
    }

    // MARK: Step 7: hot-region dismissal

    private func cancelDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    private func scheduleDismissIfOutside() {
        guard window != nil else { return }
        guard !isInsideHotRegion(NSEvent.mouseLocation) else {
            cancelDismiss()
            return
        }
        guard dismissWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismissIfStillOutside() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissGrace, execute: work)
    }

    private func dismissIfStillOutside() {
        dismissWork = nil
        guard !isInsideHotRegion(NSEvent.mouseLocation) else { return }
        dismissNow()
    }

    /// Point-in-(hat OR palette OR the explicit corridor between them) (SPEC §4.C step 7), each
    /// inflated by a couple of points of slack — three independent containment tests, NOT
    /// `hatFrame.union(paletteFrame)` inset by a margin. `CGRect.union` always returns the
    /// bounding box of both rects: since the palette (up to several hundred points wide) is far
    /// wider than the hat (~22 pt, the button + inset), that bounding box's x-range is the
    /// palette's own width, and its y-range spans from the palette's bottom up through the hat's
    /// top — so the union alone, before any inset, already reconstitutes the whole titlebar
    /// strip above the palette across the palette's full width (confirmed live: hat (351,735)
    /// 22×22, palette (354,540) 265×199 in NSScreen space — their union's y-range already reaches
    /// up to 757, 18 pt above the palette's own top edge at 739, across all 265 pt of the
    /// palette's width). That was the real cause of the critic-reported gap (a flat 24 pt inset
    /// on top of this union made it worse, but removing the inset alone would not have fixed it).
    /// Coordinates are NSScreen space throughout (`hatFrame`, `paletteFrame`, y up).
    private func isInsideHotRegion(_ point: CGPoint) -> Bool {
        guard let hatFrame else { return false }
        if hatFrame.insetBy(dx: -Self.hotRegionSlack, dy: -Self.hotRegionSlack).contains(point) { return true }
        // `hoverPaletteFrame`, not `PaletteController.shared.paletteFrame` — nil whenever the
        // open palette belongs to another trigger, so a foreign palette is never folded into
        // this hot region (SPEC §4.C step 1).
        guard let paletteFrame = PaletteController.shared.hoverPaletteFrame else { return false }
        if paletteFrame.insetBy(dx: -Self.hotRegionSlack, dy: -Self.hotRegionSlack).contains(point) { return true }
        // The vertical gap between the hat's bottom edge and the palette's top edge, restricted
        // to the hat's own x-range — zero (or negative) height once they touch or overlap, which
        // is the common case (the palette sits flush under the button), so this is then a no-op.
        let gapHeight = hatFrame.minY - paletteFrame.maxY
        guard gapHeight > 0 else { return false }
        let corridor = CGRect(x: hatFrame.minX, y: paletteFrame.maxY, width: hatFrame.width, height: gapHeight)
        return corridor.insetBy(dx: -Self.hotRegionSlack, dy: -Self.hotRegionSlack).contains(point)
    }

    /// Ends the session (hat, watcher, timers) and dismisses the palette if it is showing. The
    /// local monitor stays installed — it runs for as long as hover is enabled, not just for one
    /// session (see the class doc's step 7 note); `setEnabled(false)` tears it down.
    private func dismissNow() {
        guard window != nil else { return }
        showPaletteWork?.cancel()
        showPaletteWork = nil
        cancelDismiss()
        watcher?.invalidate()
        watcher = nil
        window = nil
        button = nil
        buttonSubrole = nil
        hatFrame = nil
        hat.orderOut(nil)
        // Only ever dismiss a session hover itself opened (SPEC §4.C step 1) — a palette another
        // trigger opened must be left alone. `hasNonHoverSessionOpen` is false both when nothing
        // is open (dismiss is already a no-op then) and when the open session is hover's own.
        if !PaletteController.shared.hasNonHoverSessionOpen {
            PaletteController.shared.dismiss(animated: true)
        }
    }
}
