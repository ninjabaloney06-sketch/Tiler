import AppKit
import ApplicationServices
import TilerCore

/// The one class that does all Accessibility IPC for Tiler (SPEC §3). Main-actor bound (module
/// default isolation); every element it touches gets a 0.1 s messaging timeout (`AX.prepare`).
///
/// Safety: never touches windows of our own process, and while `TILER_ONLY_PIDS` is set touches
/// only windows of those pids — for single-window presets and reverts too, not only arrange.
public final class AXWindowEngine {
    public static let shared = AXWindowEngine()

    /// Settings the engine reads: `stageManagerInset` (width left free by `-sm` presets). The app
    /// keeps this in sync with `ConfigStore` (assign on start and on `.tilerConfigDidChange`).
    public var settings: TilerSettings = .default

    private let history = RevertHistory()

    public init() {}

    // MARK: Result of `apply`

    public struct Move {
        public let element: AXUIElement
        public let pid: pid_t
        public let windowID: CGWindowID?
        /// Slot index for arrange presets, nil otherwise.
        public let slotIndex: Int?
        /// Frame before the move.
        public let before: CGRect
        /// Frame the engine asked for (slot / preset frame).
        public let target: CGRect
        /// Frame read back afterwards; nil if the window did not answer.
        public let final: CGRect?
        public let sizeSettable: Bool
        public let realigned: Bool
    }

    public struct ApplyResult {
        /// Windows moved, in execution order (hovered first for arrange).
        public var moves: [Move] = []
        /// Arrange only: candidate windows found on the screen (before the slot-count cut).
        public var candidateCount = 0
        /// Why nothing was done, if so.
        public var skippedReason: String?
    }

    // MARK: Preset execution (SPEC §7 contract)

    /// Executes any preset. `.moveResize` / `.center` act on `hoveredWindow` (nil = no target:
    /// nothing moves, `skippedReason` says so); `.arrange` acts on all candidate windows on
    /// `screen` (SPEC §1), hovered first, or in plain front-to-back order when `hoveredWindow` is
    /// nil (menu-bar / hotkey trigger with header "No window", SPEC §4). Frames come from the
    /// usable area of `screen` for the preset's width variant: the whole `visibleFrame`, or minus
    /// `settings.stageManagerInset` on the left for `-sm` presets. Does not raise windows — call
    /// `raise(_:)` if wanted.
    /// Every moved window is recorded for Revert.
    @discardableResult
    public func apply(preset: Preset, hoveredWindow: AXUIElement?, screen: NSScreen) -> ApplyResult {
        if let hoveredWindow { AX.prepare(hoveredWindow) }
        let area = ScreenGeometry.usableArea(
            of: screen, for: preset, stageManagerInset: settings.stageManagerInset)
        switch preset.kind {
        case .moveResize, .center:
            guard let hoveredWindow else {
                var result = ApplyResult()
                result.skippedReason = "no target window"
                return result
            }
            return applySingle(preset: preset, window: hoveredWindow, area: area)
        case .arrange:
            return applyArrange(preset: preset, hoveredWindow: hoveredWindow, screen: screen, area: area)
        }
    }

    private func applySingle(preset: Preset, window: AXUIElement, area: UsableArea) -> ApplyResult {
        var result = ApplyResult()
        guard let pid = AX.pid(window), WindowEnumerator.isAllowed(pid: pid) else {
            result.skippedReason = "window not allowed (own process or TILER_ONLY_PIDS)"
            return result
        }
        guard !isFullScreen(window) else {
            result.skippedReason = "window is full screen"
            return result
        }
        guard let before = AX.frame(window) else {
            result.skippedReason = "window frame unreadable"
            return result
        }
        let target: CGRect
        let edges: FrameSetter.Edges
        if let unit = preset.rect {
            target = area.frame(for: unit)
            edges = .shared(by: unit)
        } else {
            target = area.centeredFrame(size: before.size)
            edges = []
        }
        result.moves = [move(window, pid: pid, windowID: AX.windowID(window), slotIndex: nil,
                             before: before, target: target, edges: edges, area: area).move]
        return result
    }

    private func applyArrange(
        preset: Preset, hoveredWindow: AXUIElement?, screen: NSScreen, area: UsableArea
    ) -> ApplyResult {
        var result = ApplyResult()
        let candidates = WindowEnumerator.candidates(on: screen, hovered: hoveredWindow)
        result.candidateCount = candidates.count
        let hoveredIndex: Int? = hoveredWindow.flatMap { hovered in
            candidates.first.map { WindowEnumerator.isSameWindow($0, hovered) } == true ? 0 : nil
        }
        let plan = Assignment.planArrange(
            windowFrames: candidates.map(\.frame), hoveredIndex: hoveredIndex, preset: preset, area: area)
        guard !plan.isEmpty else {
            result.skippedReason = candidates.isEmpty ? "no candidate windows" : "empty plan"
            return result
        }
        var keys: [RevertHistory.Key] = []
        for step in plan {
            let window = candidates[step.windowIndex]
            let unit = preset.slots[step.slotIndex]
            let (moved, key) = move(window.element, pid: window.pid, windowID: window.windowID, slotIndex: step.slotIndex,
                                    before: window.frame, target: step.frame, edges: .shared(by: unit), area: area)
            result.moves.append(moved)
            keys.append(key)
        }
        history.setLastArrange(keys)
        return result
    }

    /// Sets one frame and records it for Revert; returns the move and its history key.
    private func move(
        _ window: AXUIElement, pid: pid_t, windowID: CGWindowID?, slotIndex: Int?,
        before: CGRect, target: CGRect, edges: FrameSetter.Edges, area: UsableArea
    ) -> (move: Move, key: RevertHistory.Key) {
        let set = FrameSetter.setFrame(target, of: window, sharedEdges: edges, bounds: area.rect, scale: area.scale)
        let key = history.record(element: window, pid: pid, windowID: windowID, before: before, after: set.final ?? target)
        let move = Move(element: window, pid: pid, windowID: windowID, slotIndex: slotIndex, before: before,
                        target: target, final: set.final, sizeSettable: set.sizeSettable, realigned: set.realigned)
        return (move, key)
    }

    // MARK: Primitives for hover / palette (C3)

    /// The target of the menu-bar and hotkey triggers (SPEC §4.A/§4.B): the frontmost app's
    /// focused window (`kAXFocusedWindowAttribute`, 0.1 s timeout on the app element), captured
    /// before anything can change focus. nil = no usable target (header "No window"):
    /// - no frontmost app, or it has no focused window or does not answer in time;
    /// - our own process, or a pid outside `TILER_ONLY_PIDS`;
    /// - not an AXWindow / AXStandardWindow (sheet, AXDialog, AXSystemDialog, floating panel, the
    ///   Finder desktop's AXScrollArea — research §5a), or a window with a sheet attached;
    /// - minimized or `AXFullScreen`;
    /// - not on screen in the current Space's stage (the attribute can point to a window on
    ///   another Space — research §5b — or to a Stage Manager strip thumbnail).
    public func focusedWindow() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              WindowEnumerator.isAllowed(pid: pid),
              let window = AX.element(AX.application(pid: pid), kAXFocusedWindowAttribute),
              AX.pid(window) == pid,
              WindowEnumerator.isStandardWindow(window),
              !hasSheet(window),
              let frame = AX.frame(window),
              WindowEnumerator.isOnCurrentStage(window, pid: pid, frame: frame)
        else { return nil }
        return window
    }

    /// True if a sheet (child with role AXSheet) is attached to the window, i.e. the sheet has focus.
    private func hasSheet(_ window: AXUIElement) -> Bool {
        AX.elements(window, kAXChildrenAttribute).contains { AX.string($0, kAXRoleAttribute) == kAXSheetRole }
    }

    /// The window that owns a traffic-light button: its `kAXWindowAttribute` (NOT kAXParent, which
    /// is a titlebar AXGroup). Timeout set on the result.
    public func window(ofButton button: AXUIElement) -> AXUIElement? {
        AX.element(AX.prepare(button), kAXWindowAttribute)
    }

    /// The window's `AXFullScreen` attribute (false if unreadable).
    public func isFullScreen(_ window: AXUIElement) -> Bool {
        AX.bool(AX.prepare(window), "AXFullScreen") == true
    }

    /// The window's frame in AX space.
    public func frame(of window: AXUIElement) -> CGRect? {
        AX.frame(AX.prepare(window))
    }

    /// The screen the window belongs to (full containment, else largest overlap).
    public func screen(of window: AXUIElement) -> NSScreen? {
        frame(of: window).flatMap(ScreenGeometry.screen(forWindowFrame:))
    }

    /// Brings the window to the front: AXRaise, AXMain, and its app frontmost. Skips our own
    /// process and pids outside `TILER_ONLY_PIDS`.
    public func raise(_ window: AXUIElement) {
        AX.prepare(window)
        guard let pid = AX.pid(window), WindowEnumerator.isAllowed(pid: pid) else { return }
        AX.perform(window, kAXRaiseAction)
        AX.set(window, kAXMainAttribute, NSNumber(value: true))
        AX.set(AX.application(pid: pid), kAXFrontmostAttribute, NSNumber(value: true))
    }

    // MARK: Revert

    /// True if Tiler moved this window and it has not been reverted since.
    public func hasHistory(_ window: AXUIElement) -> Bool {
        historyKey(for: window).flatMap(history.entry(for:)) != nil
    }

    /// True if the last arrange moved windows that can still be reverted.
    public var hasArrangeHistory: Bool {
        !history.lastArrangeKeys.isEmpty
    }

    /// Restores the window's frame from before Tiler's first move. The frame is set through
    /// `window` itself, the caller's element: AppKit replaces a window's AX element when the window
    /// is ordered out and in again (apps that only hide on ⌘W — Slack, Spotify, Discord, Music), so
    /// the element stored at the last move can be dead while the CGWindowID and its history live
    /// on. If `window` does not answer either, the window is looked up again by id.
    ///
    /// The history is forgotten only once the window took the restore (answered with a frame);
    /// if it could not be reached (dead element, hung app, not allowed) the history is kept so
    /// Revert can be retried. Returns true if the window is back within 1 pt per edge; false if
    /// there was no history, the window could not be reached, or the app did not allow the frame.
    @discardableResult
    public func revert(_ window: AXUIElement) -> Bool {
        guard let key = historyKey(for: window), let entry = history.entry(for: key) else { return false }
        let outcome = restore(entry, key: key, preferring: window)
        if outcome.reached { history.remove(key) }
        return outcome.restored
    }

    /// Restores every window of the last arrange that still has history, each through a live
    /// element (the stored one, else the app's window with the same id from `kAXWindowsAttribute`).
    /// Windows that could not be reached (e.g. ordered out right now, or their app hangs) keep
    /// their history and stay in the last-arrange group, so a later Revert restores them; windows
    /// that no longer exist (app quit, CGWindowID gone) are dropped. A hung app costs one round of
    /// timeouts, not one per window. Returns how many windows are back within 1 pt.
    @discardableResult
    public func revertLastArrange() -> Int {
        var restored = 0
        var pending: [RevertHistory.Key] = []
        var hung: Set<pid_t> = []
        for key in history.lastArrangeKeys {
            guard let entry = history.entry(for: key) else { continue }
            let outcome = hung.contains(entry.pid) ? RestoreOutcome() : restore(entry, key: key, preferring: nil)
            if !outcome.appAnswered { hung.insert(entry.pid) }
            if outcome.reached {
                history.remove(key)
                if outcome.restored { restored += 1 }
            } else if windowExists(key, pid: entry.pid) {
                pending.append(key)
            } else {
                history.remove(key)
            }
        }
        history.setLastArrange(pending)
        return restored
    }

    private func historyKey(for window: AXUIElement) -> RevertHistory.Key? {
        AX.prepare(window)
        guard let pid = AX.pid(window) else { return nil }
        let windowID = AX.windowID(window)
        guard windowID != nil || AX.frame(window) != nil else { return nil }
        return RevertHistory.Key(windowID: windowID, pid: pid, frame: AX.frame(window) ?? .zero)
    }

    /// Result of one restore attempt.
    private struct RestoreOutcome {
        /// The window answered with a frame after the restore.
        var reached = false
        /// That frame is within 1 pt of the original frame.
        var restored = false
        /// False if the app did not answer at all (timeout on its window list: hung).
        var appAnswered = true
    }

    /// Sets `entry.originalFrame` on a live element for `key` (see `liveElement`).
    private func restore(
        _ entry: RevertHistory.Entry, key: RevertHistory.Key, preferring window: AXUIElement?
    ) -> RestoreOutcome {
        guard WindowEnumerator.isAllowed(pid: entry.pid) else { return RestoreOutcome() }
        var candidates = [entry.element]
        if let window, !CFEqual(window, entry.element) { candidates.insert(window, at: 0) }
        let live = liveElement(for: key, pid: entry.pid, candidates: candidates)
        guard let element = live.element else { return RestoreOutcome(appAnswered: live.appAnswered) }
        let result = FrameSetter.setFrame(entry.originalFrame, of: element, sharedEdges: [],
                                          bounds: nil, scale: ScreenGeometry.windowGridScale)
        guard let final = result.final else { return RestoreOutcome() }
        return RestoreOutcome(reached: true, restored: FrameSetter.matches(final, entry.originalFrame))
    }

    /// An element for the history `key` that still answers: the first of `candidates` that belongs
    /// to `pid`, has a readable frame and maps to `key` (same CGWindowID; without an id, the frame
    /// Tiler gave the window), else the app's window from `kAXWindowsAttribute` that does. nil if
    /// the window is not reachable (ordered out, other Space, app hung or gone); `appAnswered` is
    /// false when even the app's window list could not be read.
    private func liveElement(
        for key: RevertHistory.Key, pid: pid_t, candidates: [AXUIElement]
    ) -> (element: AXUIElement?, appAnswered: Bool) {
        func answers(_ element: AXUIElement) -> Bool {
            AX.prepare(element)
            guard AX.pid(element) == pid, let frame = AX.frame(element) else { return false }
            return RevertHistory.Key(windowID: AX.windowID(element), pid: pid, frame: frame) == key
        }
        if let element = candidates.first(where: answers) { return (element, true) }
        guard let windows = AX.value(AX.application(pid: pid), kAXWindowsAttribute) as? [AXUIElement] else {
            return (nil, false)
        }
        return (windows.first(where: answers), true)
    }

    /// False once the window is gone for good: its app is no longer running, or (for windows with
    /// an id) the window server no longer knows the CGWindowID. Ordered-out windows still exist.
    private func windowExists(_ key: RevertHistory.Key, pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        guard let id = key.windowID else { return true }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        return !info.isEmpty
    }
}
