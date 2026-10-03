import AppKit
import ApplicationServices
import TilerAX
import TilerCore
import TilerTestSupport

// tiler-palettetest — live test of the palette triggers (SPEC §4.A, §4.B, §8 "Triggers",
// "Idle cost"), C3.
//
//   <build dir>/tiler-palettetest [--lock-held] [--editor]
//
// `--editor` runs only section E (the Settings editor's drag and drop and its persistence
// across a relaunch, SPEC §5 and §8 "Editor"; see that section) instead of steps 1–7.
//
// Takes the live-UI lock (<repo>/.live-test.lock; pass --lock-held if the caller already holds
// it), launches TilerTestWindows (2 windows) and the Tiler executable from the same build
// directory with `--config <temp json>` and TILER_ONLY_PIDS=<helper pid>, so Tiler can only
// touch the test windows. Then, with HID-posted events (every click is hit-tested first and must
// land on Tiler; every key is posted only while the helper is frontmost):
//   1. menu bar: click the status item → palette under the icon within 150 ms, header
//      "TilerTestWindows — TW1", hover highlight + tooltip with the preset name, click
//      "Left half" → TW1 frame;
//   2. hotkey ⌃⌥T → palette within 150 ms, centered on TW1; → → ↓ → select left-half, right-half (blank
//      skipped), arrange-2x1, bottom-half (blank skipped); Return applies; "3" applies Fill;
//      Esc closes; ⌘Q closes the palette without reaching Tiler's menu; the hotkey again closes;
//   1 also: the Revert well is dimmed before any move;
//   3. Revert: the Revert well is enabled after a move and a click restores TW1's frame;
//   4. no target (TW1 has a sheet): header "No window", single-window presets disabled and
//      inert, arrange 2x1 lays out TW1 + TW2; hotkey palette centered on the mouse's screen, keys
//      reach only the arrange preset, a disabled preset's digit does nothing;
//   1b–1d. the menu-bar palette closes on Esc, on a click outside, and when the target window
//      goes away;
//   1e. the status item toggles: a second click closes the palette (no Tiler window at the pop-up
//      menu level within 300 ms, and it stays closed), a third reopens it, a fourth closes it;
//   5. the footer "Tiler Settings…" opens Settings (closed again via AX);
//   5b. the same footer row from the hotkey palette (panel key, Tiler not active beforehand)
//      also activates Tiler, with Settings frontmost of TW1 — not just present;
//   6a. a right click on the status item with the palette open switches to the classic menu; Esc
//      posted to Tiler's pid closes it (dismissal read off the pop-up-menu CG window + AX item);
//   6. pause via the classic menu (opened over an open palette): the hotkey does nothing and a
//      left click shows the menu; resumed, the hotkey works again;
//   status item pill (screencapture of its rect vs. its unhighlighted baseline): shown while the
//      menu-bar palette is open, gone after every dismissal path (apply, Esc, click outside,
//      target closed, second icon click, classic menu, Pause);
//   7. idle CPU of Tiler over 10 s < 1 %.
// Tiler runs with TILER_NO_ANIMATE set (the engine's glide, SPEC §3, is off — expected frames
// are read exact, with no timing dependence).
// After every step: NSWorkspace.frontmostApplication is still the helper, Tiler is not active.
// Before/after snapshot of every other app's layer-0 window: must not change (a user moving
// windows during the run shows up here too).
// Cleanup on every path: Tiler and the helper are killed, the cursor is restored, the temp
// config and the lock are removed. Exit 0 = all passed, 1 = a check failed, 2 = screen locked
// (AX is redacted then; no live check is possible), 3 = the lock could not be taken.
//
// Most of the launch/drive/report scaffolding below (the report table, waiting, HID posting,
// AX/CG lookups, palette-over-AX reading, the live-UI lock, process cleanup) is shared with
// tiler-hovertest via TilerTestSupport — see that module's header. What is local here is what
// genuinely differs: this test drives the status item and the hotkey (not the green button), so
// it posts key events and reads the palette back with a plain alpha check (no hover hat to tell
// it apart from).

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// MARK: Report

let testReport = TestReport(checkColumnWidth: 44)
func report(_ check: String, _ problems: [String], note: String = "") { testReport.report(check, problems, note: note) }
func check(_ name: String, _ condition: Bool, _ problem: @autoclosure () -> String, note: String = "") {
    testReport.check(name, condition, problem(), note: note)
}
func printTable() { testReport.printTable() }

// MARK: Screen lock, trust, paths

if screenIsLocked() {
    report("screen unlocked", ["screen locked — AX redacted, live check impossible"])
    printTable()
    exit(2)
}

let buildDir = buildDirectory()
let helperURL = buildDir.appendingPathComponent("TilerTestWindows")
let tilerURL = buildDir.appendingPathComponent("Tiler")
let repoRootURL = repoRoot(fromCallerFile: #filePath)
let lockPath = repoRootURL.appendingPathComponent(".live-test.lock").path
let lockHeld = CommandLine.arguments.contains("--lock-held")

// State the cleanup (and the signal handler) needs.
nonisolated(unsafe) var helperPID: pid_t = 0
nonisolated(unsafe) var tilerPID: pid_t = 0
nonisolated(unsafe) var ownsLock = false
nonisolated(unsafe) var lockPathC: UnsafeMutablePointer<CChar>? = strdup(lockPath)

let originalCursor = CGEvent(source: nil)?.location ?? .zero
let originalFrontmost = NSWorkspace.shared.frontmostApplication
let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tiler-palettetest-\(getpid())")
let configURL = tempDir.appendingPathComponent("config.json")
/// Tiler's stderr; its tail is printed when a check failed.
let tilerLog = tempDir.appendingPathComponent("tiler.log")

for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    signal(signalNumber) { _ in
        if tilerPID > 0 { kill(tilerPID, SIGKILL) }
        if helperPID > 0 { kill(helperPID, SIGKILL) }
        if ownsLock, let path = lockPathC { rmdir(path) }
        _exit(130)
    }
}

var helper: Process?
var tiler: Process?
var helperInput: Pipe?

func finish() -> Never {
    finishLiveTest(report: testReport, helper: helper, tiler: tiler, helperPID: helperPID, tilerPID: tilerPID,
                   originalCursor: originalCursor, originalFrontmost: originalFrontmost,
                   tempDir: tempDir, tilerLog: tilerLog, ownsLock: ownsLock, lockPath: lockPath,
                   additionalCleanup: { try? helperInput?.fileHandleForWriting.close() })
}

func bail(_ check: String, _ problem: String) -> Never {
    report(check, [problem])
    finish()
}

guard AXIsProcessTrusted() else {
    bail("accessibility", "AXIsProcessTrusted() is false — run from a shell that has Accessibility trust")
}
for url in [helperURL, tilerURL] where !FileManager.default.isExecutableFile(atPath: url.path) {
    bail("binaries", "\(url.path) not found — build the whole package first")
}

// MARK: Live-UI lock (SPEC §0)

ownsLock = acquireLiveUILock(path: lockPath, alreadyHeld: lockHeld, report: testReport)

// MARK: AX / CG helpers

/// The palette panel: Tiler's on-screen window at the pop-up menu level.
func paletteWindow() -> CGWin? {
    cgWindows().first { $0.pid == tilerPID && $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) && $0.alpha > 0.5 }
}

func tilerIsActive() -> Bool { TilerTestSupport.tilerIsActive(tilerPID: tilerPID) }

// MARK: HID events

/// Posts a key press, only while the helper (or `allowed`) is frontmost, so nothing reaches
/// another app.
func pressKey(_ code: CGKeyCode, flags: CGEventFlags = [], allowed: pid_t? = nil) -> Bool {
    let front = frontmostPID()
    guard front == helperPID || (allowed != nil && front == allowed) else {
        report("key \(code)", ["frontmost is pid \(front.map(String.init) ?? "none"), not the helper — not posting keys"])
        return false
    }
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { continue }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        pause(0.02)
    }
    pause(0.05)
    return true
}

/// Posts a key press directly to `target`'s process (`CGEvent.postToPid`), not through the global
/// HID tap. Used where an app is still inside synthetic mouse-down tracking — the classic status
/// menu in 6a is opened by a synthetic click and tracks while the test posts the key — where a
/// HID-tap key races the tracking loop instead of cancelling it.
func pressKeyToPid(_ code: CGKeyCode, flags: CGEventFlags = [], to target: pid_t) -> Bool {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { continue }
        event.flags = flags
        event.postToPid(target)
        pause(0.02)
    }
    pause(0.05)
    return true
}

enum Key {
    static let t: CGKeyCode = 0x11
    static let three: CGKeyCode = 0x14
    static let one: CGKeyCode = 0x12
    static let returnKey: CGKeyCode = 36
    static let escape: CGKeyCode = 53
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
}

func clickTiler(_ point: CGPoint, what: String) -> Bool {
    TilerTestSupport.clickTiler(point, what: what, tilerPID: tilerPID, report: testReport)
}

func pressHotkey() -> Bool {
    pressKey(Key.t, flags: [.maskControl, .maskAlternate])
}

/// ⌃⌥T, polling for the palette between key-down and key-up: the latency from the key-down.
/// nil if the palette did not appear within `timeout` (or the helper was not frontmost).
func pressHotkeyAndWait(timeout: TimeInterval = 1) -> TimeInterval? {
    guard frontmostPID() == helperPID else {
        report("hotkey", ["frontmost is not the helper — not posting keys"])
        return nil
    }
    let flags: CGEventFlags = [.maskControl, .maskAlternate]
    guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: Key.t, keyDown: true),
          let up = CGEvent(keyboardEventSource: eventSource, virtualKey: Key.t, keyDown: false) else { return nil }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    let latency = waitFor(timeout) { paletteVisible() }
    up.post(tap: .cghidEventTap)
    pause(0.05)
    return latency
}

// MARK: Palette via AX

func paletteElement() -> AXUIElement? { TilerTestSupport.paletteElement(tilerPID: tilerPID) }

func readPalette(timeout: TimeInterval = 1) -> PaletteState? {
    TilerTestSupport.readPalette(tilerPID: tilerPID, timeout: timeout, paletteWindow: paletteWindow)
}

/// The text of Tiler's visible tooltip window, nil if none is on screen.
func toolTipText() -> String? {
    guard cgWindows().contains(where: { $0.pid == tilerPID && $0.layer == Int(CGWindowLevelForKey(.helpWindow)) }),
          let window = AX.elements(AX.application(pid: tilerPID), kAXWindowsAttribute)
            .first(where: { AX.string($0, kAXTitleAttribute) == "Tiler Tooltip" }) else { return nil }
    func text(_ element: AXUIElement, _ depth: Int) -> String? {
        if AX.string(element, kAXRoleAttribute) == kAXStaticTextRole { return AX.string(element, kAXValueAttribute) }
        guard depth < 4 else { return nil }
        return children(element).lazy.compactMap { text($0, depth + 1) }.first
    }
    return text(window, 0)
}

/// The palette (not the classic status menu, also a pop-up-menu-level window) is on screen.
func paletteVisible() -> Bool {
    paletteWindow() != nil && paletteElement() != nil
}

func paletteClosed(timeout: TimeInterval = 0.6) -> TimeInterval? {
    TilerTestSupport.paletteClosed(timeout: timeout, paletteWindow: paletteWindow)
}

func clickItem(_ state: PaletteState, _ id: String) -> Bool {
    TilerTestSupport.clickItem(state, id, tilerPID: tilerPID, report: testReport)
}

// MARK: E. Settings editor (--editor): drag and drop + persistence (SPEC §5, §8 "Editor")
//
// Runs instead of steps 1–7. No helper: Tiler is launched with TILER_ONLY_PIDS=<this process>
// (no windows), so it cannot touch any window; only Tiler's own Settings window is driven.
// Every drag is HID-posted and hit-tested at both ends (must be Tiler). After each step
// config.json is decoded and compared with the layout `PaletteLayout` predicts; then Tiler is
// killed, relaunched on the same config, and the menu-bar palette (read over AX) must show the
// same layout.

if CommandLine.arguments.contains("--editor") {
    // Row 0: left-half, right-half; row 1: –, –, fill; row 2: bottom-half.
    var layout = PaletteLayout()
    layout.add("left-half", at: WellPosition(row: 0, column: 0))
    layout.add("right-half", at: WellPosition(row: 0, column: 1))
    layout.add("fill", at: WellPosition(row: 1, column: 2))
    layout.add("bottom-half", at: WellPosition(row: 2, column: 0))

    do {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: configURL)
        var config = TilerConfig.default
        config.palette = layout
        config.settings.hoverTriggerEnabled = false
        store.config = config
        guard FileManager.default.fileExists(atPath: configURL.path), store.lastSaveError == nil else {
            bail("E config", "could not write \(configURL.path): \(store.lastSaveError ?? "?")")
        }
    } catch {
        bail("E config", "\(error)")
    }
    FileManager.default.createFile(atPath: tilerLog.path, contents: nil)
    let othersBefore = TilerTestSupport.otherWindows(excluding: [tilerPID, getpid()])

    func describeLayout(_ layout: PaletteLayout) -> String {
        layout.wells.sorted { $0.key < $1.key }.map { "\($0.key.row),\($0.key.column)=\($0.value)" }.joined(separator: " ")
    }

    func savedLayout() -> PaletteLayout? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return (try? JSONDecoder().decode(TilerConfig.self, from: data))?.palette
    }

    func launchTiler(showSettings: Bool) {
        let process = Process()
        process.executableURL = tilerURL
        process.arguments = ["--config", configURL.path] + (showSettings ? ["--show-settings"] : [])
        var environment = ProcessInfo.processInfo.environment
        // The only allowed pid is this test process, which has no windows.
        environment[WindowEnumerator.pidFilterVariable] = "\(getpid())"
        environment[FrameSetter.noAnimateVariable] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let log = FileHandle(forWritingAtPath: tilerLog.path)
        _ = try? log?.seekToEnd()
        process.standardError = log
        do { try process.run() } catch { bail("E launch Tiler", "\(error)") }
        tiler = process
        tilerPID = process.processIdentifier
    }

    /// Tiler's status item, once its frame is stable inside the menu bar and not covered.
    func findStatusItem() -> CGRect? {
        let tilerApp = AX.application(pid: tilerPID)
        let menuBarHeight = NSScreen.screens[0].frame.maxY - NSScreen.screens[0].visibleFrame.maxY
        var found: CGRect?
        waitFor(10) {
            guard let bar = AX.element(tilerApp, "AXExtrasMenuBar"), let item = children(bar).first,
                  let first = axFrame(item) else { return false }
            pause(0.25)
            guard let second = axFrame(item), second == first, second.minY >= 0, second.maxY <= menuBarHeight + 1 else { return false }
            found = second
            return true
        }
        guard let found, pidAt(CGPoint(x: found.midX, y: found.midY)) == tilerPID else { return nil }
        return found
    }

    func settingsWindow() -> AXUIElement? {
        AX.elements(AX.application(pid: tilerPID), kAXWindowsAttribute).first { AX.string($0, kAXTitleAttribute) == "Tiler Settings" }
    }

    /// A HID drag from `start` to `end` (left button), only if both points are Tiler's.
    func drag(from start: CGPoint, to end: CGPoint, what: String) -> Bool {
        for point in [start, end] where pidAt(point) != tilerPID {
            report("E \(what)", ["hit-test at \(point) is pid \(pidAt(point).map(String.init) ?? "none"), not Tiler — not dragging"])
            return false
        }
        moveMouse(start)
        postMouse(.leftMouseDown, start)
        pause(0.15)
        let steps = 20
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            postMouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            pause(0.015)
        }
        // A few small moves over the target so the destination sees dragging updates there.
        for dx in [1.0, -1.0, 0.0] as [CGFloat] {
            postMouse(.leftMouseDragged, CGPoint(x: end.x + dx, y: end.y))
            pause(0.04)
        }
        pause(0.15)
        postMouse(.leftMouseUp, end)
        pause(0.4)
        return true
    }

    /// An item of Tiler's open context menu, via AX.
    func contextMenuItem(_ title: String) -> AXUIElement? {
        func find(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
            if AX.string(element, kAXRoleAttribute) == kAXMenuItemRole, AX.string(element, kAXTitleAttribute) == title {
                return element
            }
            guard depth < 4 else { return nil }
            for child in children(element) {
                if let found = find(child, depth + 1) { return found }
            }
            return nil
        }
        return find(AX.application(pid: tilerPID), 0)
    }

    /// Runs `action` (which reports its own failure and returns false), then waits for
    /// config.json to hold `expected`.
    func step(_ name: String, expected: PaletteLayout, _ action: () -> Bool) {
        guard action() else { return }
        var saved: PaletteLayout?
        let took = waitFor(1.5) {
            saved = savedLayout()
            return saved == expected
        }
        check("E \(name): config.json", took != nil,
              "saved \(saved.map(describeLayout) ?? "unreadable"), expected \(describeLayout(expected))",
              note: describeLayout(expected))
    }

    // Launch with Settings open.
    launchTiler(showSettings: true)
    var window: AXUIElement?
    waitFor(10) {
        window = settingsWindow()
        return window != nil
    }
    guard let window else { bail("E settings window", "no \"Tiler Settings\" window within 10 s") }
    pause(0.5)
    let elements = identifiedElements(window, depth: 30)
    func wellFrame(_ row: Int, _ column: Int) -> CGRect? { elements["well:\(row)-\(column)"].flatMap(axFrame) }
    guard let grid = elements["editor-wells"].flatMap(axFrame),
          let libraryTopHalf = elements["library:top-half"].flatMap(axFrame),
          wellFrame(0, 0) != nil else {
        bail("E editor AX", "missing editor-wells / well:0-0 / library:top-half (found \(elements.count) identified elements)")
    }
    // Whether Tiler became active is informational only: every drag point is hit-tested anyway.
    report("E editor", [], note: "wells \(describe(grid)), library Top half \(describe(libraryTopHalf)), Tiler active \(tilerIsActive())")
    func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    func wellCenter(_ row: Int, _ column: Int, _ what: String) -> CGPoint? {
        guard let frame = wellFrame(row, column) else {
            report("E \(what)", ["no AX element well:\(row)-\(column)"])
            return nil
        }
        return center(frame)
    }

    // a. library → empty well: adds.
    layout.add("top-half", at: WellPosition(row: 0, column: 4))
    step("a library → empty well adds", expected: layout) {
        guard let target = wellCenter(0, 4, "a") else { return false }
        return drag(from: center(libraryTopHalf), to: target, what: "a library → well")
    }

    // b. well → empty well: moves.
    layout.move(from: WellPosition(row: 0, column: 0), to: WellPosition(row: 1, column: 0))
    step("b well → empty well moves", expected: layout) {
        guard let source = wellCenter(0, 0, "b"), let target = wellCenter(1, 0, "b") else { return false }
        return drag(from: source, to: target, what: "b well → well")
    }

    // c. well → occupied well: swaps (left-half at 1,0 ↔ right-half at 0,1).
    layout.move(from: WellPosition(row: 1, column: 0), to: WellPosition(row: 0, column: 1))
    step("c well → occupied well swaps", expected: layout) {
        guard let source = wellCenter(1, 0, "c"), let target = wellCenter(0, 1, "c") else { return false }
        return drag(from: source, to: target, what: "c well → occupied well")
    }

    // d. well → outside the wells (the pane header above the grid, still Tiler's window): removes.
    layout.remove(at: WellPosition(row: 0, column: 4))
    step("d well → outside removes", expected: layout) {
        guard let source = wellCenter(0, 4, "d") else { return false }
        return drag(from: source, to: CGPoint(x: grid.midX, y: grid.minY - 20), what: "d well → outside")
    }

    // e. right-click › Remove.
    layout.remove(at: WellPosition(row: 2, column: 0))
    step("e right-click › Remove", expected: layout) {
        guard let point = wellCenter(2, 0, "e") else { return false }
        moveMouse(point)
        guard pidAt(point) == tilerPID else {
            report("E e right-click", ["hit-test at \(point) is not Tiler — not clicking"])
            return false
        }
        postMouse(.rightMouseDown, point, button: .right)
        pause(0.06)
        postMouse(.rightMouseUp, point, button: .right)
        var item: AXUIElement?
        waitFor(1.5) {
            item = contextMenuItem("Remove")
            return item != nil
        }
        guard let item else {
            report("E e right-click", ["no context menu with Remove"])
            return false
        }
        _ = AX.perform(item, kAXPressAction)
        return true
    }

    // Relaunch: the menu-bar palette must show the final layout.
    let expected = layout
    if let running = tiler, running.isRunning {
        running.terminate()
        if waitFor(3, { !running.isRunning }) == nil { kill(tilerPID, SIGKILL) }
    }
    waitFor(2) { tiler?.isRunning != true }
    check("E config.json unchanged by quitting", savedLayout() == expected,
          "saved \(savedLayout().map(describeLayout) ?? "unreadable")")
    launchTiler(showSettings: false)
    if let statusItem = findStatusItem() {
        let point = CGPoint(x: statusItem.midX, y: statusItem.midY)
        moveMouse(point)
        postMouse(.leftMouseDown, point)
        waitFor(1) { paletteWindow() != nil }
        postMouse(.leftMouseUp, point)
        if let state = readPalette() {
            var problems: [String] = []
            let shown = Set(state.elements.keys.filter { $0.hasPrefix("preset:") }.map { String($0.dropFirst("preset:".count)) })
            let wanted = Set(expected.wells.values)
            if shown != wanted { problems.append("palette presets \(shown.sorted()), expected \(wanted.sorted())") }
            // Tile positions: on every axis, tile centers must sit on one pitch in well order.
            let tiles: [(position: WellPosition, frame: CGRect)] = expected.wells.compactMap { entry in
                state.frame("preset:\(entry.value)").map { (position: entry.key, frame: $0) }
            }
            func axis(_ name: String, _ index: (WellPosition) -> Int, _ coordinate: (CGRect) -> CGFloat) {
                guard let a = tiles.first else { return }
                var far = a
                for tile in tiles where abs(index(tile.position) - index(a.position)) > abs(index(far.position) - index(a.position)) {
                    far = tile
                }
                let span = index(far.position) - index(a.position)
                let pitch = span == 0 ? 0 : (coordinate(far.frame) - coordinate(a.frame)) / CGFloat(span)
                if span != 0 && pitch <= 0 { problems.append("\(name) order reversed") }
                for tile in tiles {
                    let predicted = coordinate(a.frame) + CGFloat(index(tile.position) - index(a.position)) * pitch
                    if abs(coordinate(tile.frame) - predicted) > 2 {
                        problems.append("\(tile.position.row),\(tile.position.column) \(name) \(Int(coordinate(tile.frame))), expected \(Int(predicted))")
                    }
                }
            }
            axis("x", { $0.column }, { $0.midX })
            axis("y", { $0.row }, { $0.midY })
            report("E relaunch: palette shows the saved layout", problems, note: describeLayout(expected))
            // Close it again with a second click on the status item.
            if pidAt(point) == tilerPID {
                moveMouse(point)
                postMouse(.leftMouseDown, point)
                pause(0.06)
                postMouse(.leftMouseUp, point)
                check("E relaunch: palette closes", paletteClosed() != nil, "palette still visible")
            }
        } else {
            report("E relaunch palette", ["no palette after clicking the status item"])
        }
    } else {
        report("E relaunch status item", ["Tiler's status item did not appear or is covered"])
    }

    let after = TilerTestSupport.otherWindows(excluding: [tilerPID, getpid()])
    var moved: [String] = []
    for (id, bounds) in othersBefore {
        guard let now = after[id] else { continue }
        if edgeError(now, bounds) > 1 { moved.append("window \(id) \(describe(bounds)) → \(describe(now))") }
    }
    report("E other apps' windows untouched", moved, note: "\(othersBefore.count) windows")
    finish()
}

// MARK: Config

let testLayout: PaletteLayout = {
    // Row 0: left-half, blank, right-half, fill; row 1: top-half, arrange-2x1, blank, bottom-half.
    var layout = PaletteLayout()
    let wells: [(Int, Int, String)] = [
        (0, 0, "left-half"), (0, 2, "right-half"), (0, 3, "fill"),
        (1, 0, "top-half"), (1, 1, "arrange-2x1"), (1, 3, "bottom-half"),
        // Revert is a well item (SPEC §3); at the end of row 1 it leaves every arrow/digit path
        // below unchanged.
        (1, 4, PaletteLayout.revertID),
    ]
    for (row, column, id) in wells { layout.add(id, at: WellPosition(row: row, column: column)) }
    return layout
}()

do {
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let store = ConfigStore(fileURL: configURL)
    var config = TilerConfig.default
    config.palette = testLayout
    config.settings.paletteHotkey = .defaultPalette
    config.settings.hoverTriggerEnabled = false
    store.config = config
    guard FileManager.default.fileExists(atPath: configURL.path), store.lastSaveError == nil else {
        bail("config", "could not write \(configURL.path): \(store.lastSaveError ?? "?")")
    }
    let missing = testLayout.readingOrder.compactMap { testLayout.presetID(at: $0) }.filter { !PaletteLayout.isPlaceable($0) }
    guard missing.isEmpty else { bail("config", "unknown preset ids \(missing)") }
}

// MARK: Helper

let lines = LineReader()

do {
    let process = Process()
    process.executableURL = helperURL
    process.arguments = ["2", "--control"]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    let reader = lines
    output.fileHandleForReading.readabilityHandler = { handle in reader.append(handle.availableData) }
    do { try process.run() } catch { bail("launch helper", "\(error)") }
    helper = process
    helperInput = input
    helperPID = process.processIdentifier
    guard lines.next(timeout: 10) == "PID \(helperPID)" else { bail("launch helper", "no PID line") }
}
setenv(WindowEnumerator.pidFilterVariable, "\(helperPID)", 1)

func send(_ command: String) -> Bool {
    try? helperInput?.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    return lines.next(timeout: 3) == "OK \(command)"
}

func testWindow(_ title: String) -> AXUIElement? { TilerTestSupport.testWindow(title, helperPID: helperPID) }

guard waitFor(10, { testWindow("TW1") != nil && testWindow("TW2") != nil }) != nil else {
    bail("helper windows", "TW1/TW2 not found via AX")
}

func tw(_ title: String) -> AXUIElement { testWindow(title)! }

func frameOf(_ title: String) -> CGRect? { TilerTestSupport.frameOfHelperWindow(title, helperPID: helperPID) }

/// Direct AX placement (not the engine, so no revert history).
func place(_ title: String, _ frame: CGRect) {
    TilerTestSupport.placeHelperWindow(title, frame, helperPID: helperPID)
}

/// Brings TW1 (and the helper) to the front through AX.
func raiseHelper() -> Bool { TilerTestSupport.raiseHelper(tw("TW1"), helperPID: helperPID) }

guard raiseHelper() else {
    bail("helper frontmost", "TilerTestWindows did not become frontmost (front: \(frontmostPID().map(String.init) ?? "none"))")
}

guard let screen = ScreenGeometry.screen(forWindowFrame: frameOf("TW1") ?? .zero) else { bail("screen", "no screen for TW1") }
let visible = ScreenGeometry.axVisibleFrame(of: screen)
let start1 = CGRect(x: visible.minX + 300, y: visible.minY + 120, width: 520, height: 360).integral
let start2 = CGRect(x: visible.minX + 420, y: visible.minY + 260, width: 460, height: 300).integral
place("TW1", start1)
place("TW2", start2)
_ = raiseHelper()
report("helper", [], note: "pid \(helperPID), TW1 \(describe(frameOf("TW1"))), frontmost")

func expectedFrame(_ id: String) -> CGRect { TilerTestSupport.expectedFrame(id, screen: screen) }

// Every other app's window on this Space, by CGWindowID, with its AX frame (read only), once the
// helper is on stage. AX, not CG bounds: with Stage Manager on, CG reports a strip thumbnail for
// windows of inactive apps, and those move whenever the active app changes.
func otherWindows() -> [CGWindowID: CGRect] {
    TilerTestSupport.otherWindows(excluding: [helperPID, tilerPID, getpid()])
}

let othersBefore = otherWindows()

// MARK: Tiler

do {
    let process = Process()
    process.executableURL = tilerURL
    process.arguments = ["--config", configURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment[WindowEnumerator.pidFilterVariable] = "\(helperPID)"
    environment[FrameSetter.noAnimateVariable] = "1"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    FileManager.default.createFile(atPath: tilerLog.path, contents: nil)
    process.standardError = FileHandle(forWritingAtPath: tilerLog.path)
    do { try process.run() } catch { bail("launch Tiler", "\(error)") }
    tiler = process
    tilerPID = process.processIdentifier
}

/// Tiler's status item, once its frame is stable inside the menu bar.
var statusItem = CGRect.null
do {
    let tilerApp = AX.application(pid: tilerPID)
    let menuBarHeight = NSScreen.screens[0].frame.maxY - NSScreen.screens[0].visibleFrame.maxY
    waitFor(10) {
        guard let bar = AX.element(tilerApp, "AXExtrasMenuBar"), let item = children(bar).first,
              let first = axFrame(item) else { return false }
        pause(0.25)
        guard let second = axFrame(item), second == first, second.minY >= 0, second.maxY <= menuBarHeight + 1 else { return false }
        statusItem = second
        return true
    }
    guard !statusItem.isNull else { bail("status item", "Tiler's status item did not appear in the menu bar") }
    let center = CGPoint(x: statusItem.midX, y: statusItem.midY)
    guard pidAt(center) == tilerPID else {
        bail("status item", "status item at \(describe(statusItem)) is covered (hit-test pid \(pidAt(center).map(String.init) ?? "none")) — hidden by the notch or a menu bar manager?")
    }
    report("status item", [], note: "\(describe(statusItem)), Tiler pid \(tilerPID)")
}

if frontmostPID() != helperPID { _ = raiseHelper() }
check("Tiler launch keeps focus", frontmostPID() == helperPID && !tilerIsActive(),
      "frontmost pid \(frontmostPID().map(String.init) ?? "none"), Tiler active \(tilerIsActive())")

func focusChecks(_ step: String) {
    TilerTestSupport.focusChecks(step, helperPID: helperPID, tilerPID: tilerPID, report: testReport)
}

let targetHeader = "TilerTestWindows — TW1"
/// The native status menu's top: 1 pt below the menu bar (the status item's window).
let menuBarBottom = ScreenGeometry.axVisibleFrame(of: NSScreen.screens[0]).minY

func clickStatusItem() -> TimeInterval? {
    let center = CGPoint(x: statusItem.midX, y: statusItem.midY)
    moveMouse(center)
    guard pidAt(center) == tilerPID else {
        report("status item click", ["hit-test at the status item is not Tiler — not clicking"])
        return nil
    }
    postMouse(.leftMouseDown, center)
    let latency = waitFor(1) { paletteWindow() != nil }
    postMouse(.leftMouseUp, center)
    return latency
}

// MARK: Status item highlight (pixel sample)
//
// SPEC §4.A "menu-like dropdown": every native status menu, Tiler's own classic menu included,
// keeps its icon highlighted with the pill while open. `PaletteController` calls
// `button.highlight(true)` once the opening click's own mouse-up tracking has ended, and
// `highlight(false)` in `dismiss`. These checks sample the status item rect with `screencapture
// -R` while the palette is open (pill present) and after every dismissal path (pill gone),
// compared against a baseline of the button's own unhighlighted appearance (captured once, before
// the first click) rather than a hard-coded color, so they hold in light and dark mode.
//
// `screencapture` (not `CGWindowListCreateImage`, deprecated/obsoleted in newer SDKs, or
// ScreenCaptureKit, async) keeps this synchronous and warning-free.

typealias RGB = (r: Double, g: Double, b: Double)

/// Average RGB (0–255 per channel) of `image`, drawn into an RGBA buffer owned by the context.
func averageColor(of image: CGImage) -> RGB? {
    let width = image.width, height = image.height
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let base = context.data else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let count = width * height
    let pixels = base.bindMemory(to: UInt8.self, capacity: count * 4)
    var sumR = 0.0, sumG = 0.0, sumB = 0.0
    for i in 0..<count {
        sumR += Double(pixels[i * 4])
        sumG += Double(pixels[i * 4 + 1])
        sumB += Double(pixels[i * 4 + 2])
    }
    let n = Double(count)
    return (sumR / n, sumG / n, sumB / n)
}

/// Captures `rect` (top-left global points, same frame as `statusItem`) with the `screencapture`
/// CLI to a temp PNG and returns its average color; nil if the capture or decode failed.
func captureAverageColor(of rect: CGRect) -> RGB? {
    let path = tempDir.appendingPathComponent("statusitem-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: path) }
    let x = Int(rect.minX.rounded(.down)), y = Int(rect.minY.rounded(.down))
    let width = Int(rect.width.rounded(.up)), height = Int(rect.height.rounded(.up))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R", "\(x),\(y),\(width),\(height)", path.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0, let provider = CGDataProvider(url: path as CFURL),
          let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    return averageColor(of: image)
}

func colorDistance(_ a: RGB, _ b: RGB) -> Double {
    let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
    return (dr * dr + dg * dg + db * db).squareRoot()
}

/// The button's own unhighlighted appearance, captured once before the first click. nil (capture
/// failed, e.g. no Screen Recording grant) skips the highlight checks with a note.
let statusItemUnhighlighted: RGB? = captureAverageColor(of: statusItem)
if statusItemUnhighlighted == nil {
    report("status item highlight baseline", [], note: "screencapture unavailable — highlight checks skipped")
}

/// Distance (RGB, 0–255 per channel) from the unhighlighted baseline past which the average color
/// counts as "pill present"; well above capture noise, well below the pill's own contrast.
let highlightDistanceThreshold = 10.0

/// Checks the status item's pill: `on` = present (palette open), else gone (after a dismissal).
/// Polls up to 1 s — the pill goes up one run-loop turn after the mouse-up and comes down with
/// the fade-out — and reports the last measured distance.
func checkHighlight(_ step: String, on: Bool) {
    guard let baseline = statusItemUnhighlighted else { return }
    var distance: Double?
    let settled = waitFor(1) {
        guard let color = captureAverageColor(of: statusItem) else { return false }
        let d = colorDistance(color, baseline)
        distance = d
        return on ? d > highlightDistanceThreshold : d <= highlightDistanceThreshold
    }
    let measured = distance.map { String(format: "distance %.1f", $0) } ?? "no capture"
    check("\(step) status item pill \(on ? "shown" : "gone")", settled != nil,
          "\(measured) from the unhighlighted icon (threshold \(Int(highlightDistanceThreshold)))",
          note: measured)
}

// MARK: 1. Menu-bar trigger

do {
    guard frontmostPID() == helperPID else { bail("1 setup", "helper not frontmost") }
    let latency = clickStatusItem()
    check("1 status item: palette within 150 ms", (latency ?? 1) <= 0.15, "palette after \(ms(latency))", note: ms(latency))
    guard let state = readPalette() else { bail("1 palette", "no palette window / AX content") }
    let bounds = state.window.bounds
    let expectedX = min(max(statusItem.minX - 12, visible.minX), visible.maxX - bounds.width)
    check("1 placement under the icon", abs(bounds.minY - menuBarBottom) <= 0.5 && abs(bounds.minX - expectedX) <= 1,
          "palette \(describe(bounds)), expected top \(menuBarBottom), left \(expectedX)", note: describe(bounds))
    check("1 header", state.header == targetHeader, "header \(state.header ?? "nil")", note: state.header ?? "")
    let presetIDs = testLayout.readingOrder.compactMap { testLayout.presetID(at: $0) }
    let disabled = presetIDs.filter { $0 != PaletteLayout.revertID && state.enabled("preset:\($0)") != true }
    check("1 presets enabled with a target", disabled.isEmpty && state.elements["settings"] != nil,
          "disabled: \(disabled), settings row \(state.elements["settings"] != nil)")
    check("1 Revert well dimmed before any move", state.enabled("preset:revert") == false,
          "revert well \(state.enabled("preset:revert").map(String.init(describing:)) ?? "missing")")
    focusChecks("1 palette open")
    checkHighlight("1 palette open:", on: true)

    // Hover highlight and tooltip.
    if let frame = state.frame("preset:left-half") {
        moveMouse(CGPoint(x: frame.midX - 2, y: frame.midY))
        moveMouse(CGPoint(x: frame.midX, y: frame.midY))
        pause(0.1)
        let selected = readPalette()?.selected ?? []
        check("1 hover highlight", selected == ["preset:left-half"], "selected \(selected)")
        let name = PresetLibrary.preset(id: "left-half")?.name ?? "?"
        var shown: String?
        let tip = waitFor(3) {
            shown = toolTipText()
            return shown == name
        }
        check("1 tooltip with the preset name", tip != nil, "tooltip \(shown ?? "none") within 3 s, expected \(name)",
              note: "\"\(name)\" after \(ms(tip))")
    }

    let before = frameOf("TW1")
    if clickItem(state, "preset:left-half") {
        let closed = paletteClosed()
        check("1 palette fades out after apply", closed != nil, "palette still visible", note: ms(closed))
        checkHighlight("1 after apply:", on: false)
        let expected = expectedFrame("left-half")
        let applied = waitFor(1) { edgeError(frameOf("TW1"), expected) <= 1 }
        check("1 click Left Half moves TW1", applied != nil,
              "TW1 \(describe(frameOf("TW1"))) (before \(describe(before))), expected \(describe(expected))",
              note: describe(frameOf("TW1")))
    }
    focusChecks("1 after apply")
}

// MARK: Esc-delivery sniffer (1b tightening, critic gap)
//
// Critic gap: for the menu-bar palette (non-key panel), Esc used to be observed only by a
// passive `NSEvent` global monitor, which cannot stop delivery — the key that closed the palette
// also reached whichever app owned the keyboard underneath (Terminal, a Save sheet, Finder
// rename, a full-screen video). Tiler's fix (`PaletteController.EscConsumingTap`) is an active
// `CGEventTap` at `.cgSessionEventTap`/`.headInsertEventTap` that drops keycode 53 before the
// window server hands it onward. `readPalette`/`paletteClosed` only prove the palette closed —
// not that the helper never got the key (it did before, and simply ignored it; see the old
// comment this replaces) — so this sniffer proves non-delivery directly: a listen-only tap one
// station further down the pipeline, at `.cgAnnotatedSessionEventTap` (the last stop before
// per-app delivery), which can only ever observe an event, never swallow one. If Tiler's own tap
// let Esc through, this sniffer sees it; if Tiler's tap dropped it, this sniffer — running in
// this process, independent of the helper — never does. Verified stand-alone before wiring it in
// here: with the upstream tap swallowing, the downstream sniffer saw nothing in 5/5 runs; with it
// passing events through, the sniffer saw every one.
final class EscDeliverySniffer {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var sawEscape = false

    init?() {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: escDeliverySnifferCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    fileprivate func noteKeycode(_ keycode: Int64) {
        if keycode == 53 { sawEscape = true }
    }

    /// Explicit teardown (not `deinit`, which runs nonisolated and cannot call a `MainActor`
    /// method synchronously — see `PaletteController.EscConsumingTap`, which hit the same thing).
    func invalidate() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }
}

/// C function pointer (no captures); reads `keycode` here, before crossing into the `MainActor`-
/// isolated `noteKeycode`, because `CGEvent` is not `Sendable` (mirrors
/// `PaletteController.escConsumingTapCallback`). `.listenOnly` taps must return the event
/// unchanged, hence the unconditional pass-through.
private nonisolated func escDeliverySnifferCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let address = UInt(bitPattern: userInfo)
        MainActor.assumeIsolated {
            Unmanaged<EscDeliverySniffer>.fromOpaque(UnsafeRawPointer(bitPattern: address)!)
                .takeUnretainedValue().noteKeycode(keycode)
        }
    }
    return Unmanaged.passRetained(event)
}

// MARK: 1b–1d. Dismissal of the menu-bar palette

do {
    // Esc: the panel is not key (menu-bar trigger); Tiler's `EscConsumingTap` (an active
    // `CGEventTap`, critic gap fix) consumes the key instead of a passive monitor, so unlike
    // before it never reaches the helper — proven with `EscDeliverySniffer`, not merely "the
    // helper ignores it".
    _ = clickStatusItem()
    if readPalette() != nil {
        let sniffer = EscDeliverySniffer()
        check("1b sniffer installed", sniffer != nil, "CGEventTapCreate failed (Accessibility trust missing?)")
        let posted = pressKey(Key.escape)
        let closed = paletteClosed()
        check("1b Esc closes the menu-bar palette", closed != nil, "palette still visible", note: ms(closed))
        checkHighlight("1b after Esc:", on: false)
        if posted {
            check("1b Esc never reaches the helper", sniffer?.sawEscape != true,
                  "a listen-only tap downstream of Tiler's own Esc-consuming tap (.cgAnnotatedSessionEventTap, the last stop before per-app delivery) saw the Esc — it was not dropped upstream")
        }
        sniffer?.invalidate()
    } else {
        report("1b palette", ["no palette"])
    }

    // A click outside: on TW1 (the helper's window, already frontmost).
    _ = clickStatusItem()
    if let state = readPalette(), let target = frameOf("TW1") {
        let point = CGPoint(x: target.minX + 40, y: target.maxY - 40)
        let covered = state.window.bounds.contains(point)
        moveMouse(point)
        if !covered, pidAt(point) == helperPID {
            postMouse(.leftMouseDown, point)
            pause(0.05)
            postMouse(.leftMouseUp, point)
            let closed = paletteClosed()
            check("1c click outside closes", closed != nil, "palette still visible", note: ms(closed))
            checkHighlight("1c after click outside:", on: false)
        } else {
            report("1c click outside", ["no free point of TW1 at \(point) (covered \(covered), pid \(pidAt(point).map(String.init) ?? "none"))"])
        }
    } else {
        report("1c palette", ["no palette"])
    }
    focusChecks("1c after click outside")

    // The target window goes away (the helper orders its windows out).
    _ = clickStatusItem()
    if readPalette() != nil, send("show 0") {
        let closed = paletteClosed(timeout: 1)
        check("1d target window closed closes", closed != nil, "palette still visible", note: ms(closed))
        checkHighlight("1d after target closed:", on: false)
    } else {
        report("1d palette", ["no palette or helper did not hide its windows"])
    }
    if paletteVisible() { _ = clickStatusItem() }
    guard send("show 2"), waitFor(3, { testWindow("TW1") != nil && testWindow("TW2") != nil }) != nil, raiseHelper() else {
        bail("1d restore", "TW1/TW2 did not come back")
    }
}

// MARK: 1e. The status item toggles the palette

/// Any Tiler window at the pop-up menu level, at any alpha (a fading-out palette counts too).
func anyPaletteLevelWindow() -> CGWin? {
    cgWindows().first { $0.pid == tilerPID && $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
}

/// A left click on the status item while the palette is open; passes when it closes within 300 ms
/// and is still closed 400 ms later (the click must not dismiss and immediately re-present it).
func statusItemClickCloses(_ step: String) {
    let center = CGPoint(x: statusItem.midX, y: statusItem.midY)
    moveMouse(center)
    guard pidAt(center) == tilerPID else {
        report("\(step) status item click closes", ["hit-test at the status item is not Tiler — not clicking"])
        return
    }
    postMouse(.leftMouseDown, center)
    pause(0.06)
    postMouse(.leftMouseUp, center)
    let closed = waitFor(0.3) { anyPaletteLevelWindow() == nil }
    pause(0.4)
    let reopened = anyPaletteLevelWindow() != nil
    check("\(step) status item click closes within 300 ms", closed != nil && !reopened,
          closed == nil ? "Tiler window at the pop-up menu level still on screen after 300 ms"
                        : "palette closed after \(ms(closed)) but came back",
          note: ms(closed))
    checkHighlight("\(step):", on: false)
}

do {
    if frontmostPID() != helperPID { _ = raiseHelper() }
    let opened = clickStatusItem()
    if opened != nil, readPalette() != nil {
        statusItemClickCloses("1e second click")
        let reopened = paletteVisible() ? nil : clickStatusItem()
        check("1e third click reopens", reopened != nil && readPalette() != nil, "no palette after the third click",
              note: ms(reopened))
        if reopened != nil {
            checkHighlight("1e third click:", on: true)
            statusItemClickCloses("1e fourth click")
        }
    } else {
        report("1e palette", ["no palette after the first click"])
    }
    if paletteVisible() { _ = pressKey(Key.escape); _ = paletteClosed() }
    focusChecks("1e after toggling")
}

// MARK: 2. Hotkey trigger

func openWithHotkey(_ step: String) -> PaletteState? {
    let latency = pressHotkeyAndWait()
    guard let latency, let state = readPalette() else {
        report("\(step) hotkey opens the palette", ["no palette after ⌃⌥T"])
        return nil
    }
    report("\(step) hotkey opens the palette within 150 ms", latency <= 0.15 ? [] : ["palette after \(ms(latency))"],
           note: ms(latency))
    return state
}

do {
    place("TW1", start1)
    guard frontmostPID() == helperPID else { bail("2 setup", "helper not frontmost") }
    if let state = openWithHotkey("2a") {
        let bounds = state.window.bounds
        let target = frameOf("TW1") ?? .zero
        let centered = abs(bounds.midX - target.midX) <= 1 && abs(bounds.midY - target.midY) <= 1
        check("2a centered on TW1", centered, "palette \(describe(bounds)) center (\(bounds.midX),\(bounds.midY)), TW1 center (\(target.midX),\(target.midY))",
              note: describe(bounds))
        check("2a header", state.header == targetHeader, "header \(state.header ?? "nil")")
        focusChecks("2a palette open (key)")

        // Keyboard: → → ↓ → selects left-half, right-half (blank skipped), arrange-2x1, bottom-half.
        let steps: [(CGKeyCode, String, String)] = [
            (Key.right, "→", "preset:left-half"), (Key.right, "→", "preset:right-half"),
            (Key.down, "↓", "preset:arrange-2x1"), (Key.right, "→", "preset:bottom-half"),
        ]
        var sequence: [String] = []
        var problems: [String] = []
        for (code, name, expected) in steps {
            guard pressKey(code) else { break }
            let selected = readPalette()?.selected ?? []
            sequence.append("\(name)\(selected.first ?? "none")")
            if selected != [expected] { problems.append("after \(name): \(selected), expected \(expected)") }
        }
        report("2a arrows skip blanks", problems, note: sequence.joined(separator: " "))
        if pressKey(Key.returnKey) {
            let closed = paletteClosed()
            let expected = expectedFrame("bottom-half")
            let applied = waitFor(1) { edgeError(frameOf("TW1"), expected) <= 1 }
            check("2a Return applies Bottom Half", closed != nil && applied != nil,
                  "palette closed \(closed != nil), TW1 \(describe(frameOf("TW1"))), expected \(describe(expected))")
        }
        focusChecks("2a after Return")
    }

    if openWithHotkey("2b") != nil, pressKey(Key.three) {
        let closed = paletteClosed()
        let expected = expectedFrame("fill")
        let applied = waitFor(1) { edgeError(frameOf("TW1"), expected) <= 1 }
        check("2b key 3 applies the 3rd preset (Fill)", closed != nil && applied != nil,
              "palette closed \(closed != nil), TW1 \(describe(frameOf("TW1"))), expected \(describe(expected))")
        focusChecks("2b after 3")
    }

    if openWithHotkey("2c") != nil {
        let before = frameOf("TW1")
        if pressKey(Key.escape) {
            let closed = paletteClosed()
            check("2c Esc closes, nothing moves", closed != nil && edgeError(frameOf("TW1"), before) <= 1,
                  "palette closed \(closed != nil), TW1 \(describe(frameOf("TW1"))) vs \(describe(before))", note: ms(closed))
        }
        focusChecks("2c after Esc")
    }

    if openWithHotkey("2e") != nil, pressKey(0x0C, flags: .maskCommand) {
        let closed = paletteClosed()
        pause(0.3)
        check("2e ⌘Q closes the palette, Tiler keeps running", closed != nil && tiler?.isRunning == true,
              "palette closed \(closed != nil), Tiler running \(tiler?.isRunning == true)")
        guard tiler?.isRunning == true else { bail("2e", "Tiler quit on ⌘Q") }
        focusChecks("2e after ⌘Q")
    }

    if openWithHotkey("2d") != nil, pressHotkey() {
        let closed = paletteClosed()
        check("2d hotkey again closes", closed != nil, "palette still visible", note: ms(closed))
        focusChecks("2d after hotkey")
    }
}

// MARK: 3. Revert

do {
    guard frontmostPID() == helperPID else { bail("3 setup", "helper not frontmost") }
    _ = clickStatusItem()
    if let state = readPalette() {
        check("3 Revert well enabled after a move", state.enabled("preset:revert") == true, "no enabled revert well")
        if state.elements["preset:revert"] != nil, clickItem(state, "preset:revert") {
            let closed = paletteClosed()
            let restored = waitFor(1) { edgeError(frameOf("TW1"), start1) <= 1 }
            check("3 Revert restores TW1", closed != nil && restored != nil,
                  "TW1 \(describe(frameOf("TW1"))), expected \(describe(start1))")
        }
    } else {
        report("3 palette", ["no palette"])
    }
    focusChecks("3 after Revert")
}

// MARK: 4. No target (TW1 has a sheet)

do {
    place("TW1", start1)
    place("TW2", start2)
    guard send("sheet on") else { bail("4 setup", "helper did not attach the sheet") }
    pause(0.4)
    guard frontmostPID() == helperPID else { bail("4 setup", "helper not frontmost") }
    _ = clickStatusItem()
    if let state = readPalette() {
        check("4a header No window", state.header == "No window", "header \(state.header ?? "nil")")
        let single = ["left-half", "right-half", "fill", "top-half", "bottom-half"]
        let wrong = single.filter { state.enabled("preset:\($0)") != false }
        check("4a single-window presets disabled", wrong.isEmpty && state.enabled("preset:arrange-2x1") == true,
              "enabled: \(wrong), arrange-2x1 enabled \(state.enabled("preset:arrange-2x1").map(String.init) ?? "nil")")
        let frames = (frameOf("TW1"), frameOf("TW2"))
        if clickItem(state, "preset:left-half") {
            pause(0.4)
            let stillOpen = paletteWindow() != nil
            let unchanged = edgeError(frameOf("TW1"), frames.0) <= 1 && edgeError(frameOf("TW2"), frames.1) <= 1
            let selected = readPalette()?.selected ?? []
            check("4a disabled preset is inert", stillOpen && unchanged && selected.isEmpty,
                  "palette open \(stillOpen), windows unchanged \(unchanged), selected \(selected)")
        }
        if let open = readPalette(), clickItem(open, "preset:arrange-2x1") {
            let closed = paletteClosed()
            let halves = [expectedFrame("left-half"), expectedFrame("right-half")]
            let arranged = waitFor(1.5) {
                let got = [frameOf("TW1"), frameOf("TW2")]
                return halves.allSatisfy { half in got.contains { edgeError($0, half) <= 1 } }
            }
            check("4a arrange 2x1 works without a target", closed != nil && arranged != nil,
                  "TW1 \(describe(frameOf("TW1"))), TW2 \(describe(frameOf("TW2"))), expected halves \(halves.map(describe))")
        }
    } else {
        report("4a palette", ["no palette"])
    }
    focusChecks("4a after arrange")

    if let state = openWithHotkey("4b") {
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let mouseScreen = ScreenGeometry.screen(containing: mouse) ?? screen
        let area = ScreenGeometry.axVisibleFrame(of: mouseScreen)
        let bounds = state.window.bounds
        check("4b centered on the mouse's screen", abs(bounds.midX - area.midX) <= 1 && abs(bounds.midY - area.midY) <= 1,
              "palette \(describe(bounds)), screen visibleFrame \(describe(area))")
        check("4b header No window", state.header == "No window", "header \(state.header ?? "nil")")
        var problems: [String] = []
        if pressKey(Key.right) {
            let selected = readPalette()?.selected ?? []
            if selected != ["preset:arrange-2x1"] { problems.append("→ selected \(selected), expected arrange-2x1") }
        }
        if pressKey(Key.down) {
            let selected = readPalette()?.selected ?? []
            if selected != ["settings"] { problems.append("↓ selected \(selected), expected settings") }
        }
        if pressKey(Key.up) {
            let selected = readPalette()?.selected ?? []
            if selected != ["preset:arrange-2x1"] { problems.append("↑ selected \(selected), expected arrange-2x1") }
        }
        report("4b keys reach only enabled items", problems)
        let frames = (frameOf("TW1"), frameOf("TW2"))
        if pressKey(Key.one) {
            pause(0.3)
            let unchanged = edgeError(frameOf("TW1"), frames.0) <= 1 && edgeError(frameOf("TW2"), frames.1) <= 1
            check("4b key 1 (disabled Left Half) is inert", paletteWindow() != nil && unchanged,
                  "palette open \(paletteWindow() != nil), windows unchanged \(unchanged)")
        }
        if pressKey(Key.escape) {
            check("4b Esc closes", paletteClosed() != nil, "palette still visible")
        }
        focusChecks("4b after Esc")
    }
    _ = send("sheet off")
    pause(0.3)
}

// MARK: 5. Settings footer

do {
    if frontmostPID() != helperPID { _ = raiseHelper() }
    guard frontmostPID() == helperPID else { bail("5 setup", "helper not frontmost") }
    _ = clickStatusItem()
    if let state = readPalette(), clickItem(state, "settings") {
        let closed = paletteClosed()
        var settingsWindow: AXUIElement?
        let shown = waitFor(3) {
            settingsWindow = AX.elements(AX.application(pid: tilerPID), kAXWindowsAttribute)
                .first { AX.string($0, kAXTitleAttribute) == "Tiler Settings" }
            return settingsWindow != nil
        }
        check("5 Tiler Settings… opens Settings", closed != nil && shown != nil,
              "palette closed \(closed != nil), settings window \(shown != nil)", note: ms(shown))
        if let settingsWindow, let close = AX.element(settingsWindow, kAXCloseButtonAttribute) {
            _ = AX.perform(close, kAXPressAction)
            waitFor(2) {
                !AX.elements(AX.application(pid: tilerPID), kAXWindowsAttribute).contains { AX.string($0, kAXTitleAttribute) == "Tiler Settings" }
            }
        }
    } else {
        report("5 palette", ["no palette / settings row"])
    }
    _ = raiseHelper()
}

// MARK: 5b. Settings footer from the hotkey palette (critic gap)
//
// The hotkey palette's panel is key while Tiler itself is not active (SPEC §4.B); picking
// "Tiler Settings…" there used to order the key panel out and only then ask for
// `NSApp.activate()`, which macOS silently refused (Tiler stayed inactive, Settings opened
// behind the frontmost window). Unlike check 5 (menu-bar palette, panel never key), this must
// assert Tiler actually becomes active AND that Settings ends up frontmost, not just that the
// window exists.

do {
    if frontmostPID() != helperPID { _ = raiseHelper() }
    guard frontmostPID() == helperPID else { bail("5b setup", "helper not frontmost") }
    if let state = openWithHotkey("5b"), clickItem(state, "settings") {
        let closed = paletteClosed()
        var settingsWindow: AXUIElement?
        let shown = waitFor(3) {
            settingsWindow = AX.elements(AX.application(pid: tilerPID), kAXWindowsAttribute)
                .first { AX.string($0, kAXTitleAttribute) == "Tiler Settings" }
            return settingsWindow != nil
        }
        // Let the window server settle the activation/ordering before reading either back.
        pause(0.3)
        let active = tilerIsActive()
        var settingsFrontOfTW1 = false
        if let settingsWindow, let settingsID = AX.windowID(settingsWindow), let tw1ID = AX.windowID(tw("TW1")) {
            let order = cgWindows().filter { $0.layer == 0 }.map(\.id) // front-to-back
            if let settingsIndex = order.firstIndex(of: settingsID), let tw1Index = order.firstIndex(of: tw1ID) {
                settingsFrontOfTW1 = settingsIndex < tw1Index
            }
        }
        check("5b hotkey Tiler Settings… activates Tiler, Settings frontmost",
              closed != nil && shown != nil && active && settingsFrontOfTW1,
              "palette closed \(closed != nil), settings window \(shown != nil), Tiler active \(active), Settings ahead of TW1 \(settingsFrontOfTW1)",
              note: ms(shown))
        if let settingsWindow, let close = AX.element(settingsWindow, kAXCloseButtonAttribute) {
            _ = AX.perform(close, kAXPressAction)
            waitFor(2) {
                !AX.elements(AX.application(pid: tilerPID), kAXWindowsAttribute).contains { AX.string($0, kAXTitleAttribute) == "Tiler Settings" }
            }
        }
    } else {
        report("5b palette", ["no palette / settings row from the hotkey"])
    }
    _ = raiseHelper()
}

// MARK: 6. Pause (classic menu → Pause Tiler)

/// An item of Tiler's open status menu, via AX.
func statusMenuItem(_ title: String) -> AXUIElement? {
    guard let bar = AX.element(AX.application(pid: tilerPID), "AXExtrasMenuBar"),
          let item = children(bar).first else { return nil }
    for menu in children(item) {
        if let entry = children(menu).first(where: { AX.string($0, kAXTitleAttribute) == title }) { return entry }
    }
    return nil
}

func openStatusMenu(right: Bool) -> AXUIElement? {
    let center = CGPoint(x: statusItem.midX, y: statusItem.midY)
    moveMouse(center)
    guard pidAt(center) == tilerPID else { return nil }
    postMouse(right ? .rightMouseDown : .leftMouseDown, center, button: right ? .right : .left)
    pause(0.06)
    postMouse(right ? .rightMouseUp : .leftMouseUp, center, button: right ? .right : .left)
    var entry: AXUIElement?
    waitFor(1.5) {
        entry = statusMenuItem("Pause Tiler")
        return entry != nil
    }
    return entry
}

// 6a. Right-clicking the status item while the palette is open switches to the classic menu: the
// palette closes, and once the menu is closed again the pill is gone. (`paletteVisible`, not
// `paletteClosed`: the classic menu is itself a Tiler window at the pop-up menu level.) The Esc
// goes straight to the test Tiler (`pressKeyToPid`) and dismissal is read off the pop-up-menu CG
// window: the old HID-tap Esc raced the menu's synthetic tracking, and the old AX-item wait could
// never fire because the item sits in the AX tree permanently (check bugs, not app bugs —
// new-repo issue #3).
do {
    if frontmostPID() != helperPID { _ = raiseHelper() }
    if clickStatusItem() != nil, readPalette() != nil {
        checkHighlight("6a palette open:", on: true)
        if openStatusMenu(right: true) != nil {
            let closed = waitFor(0.6) { !paletteVisible() }
            check("6a right-click switches to the classic menu", closed != nil, "palette still visible with the menu open",
                  note: ms(closed))
            _ = pressKeyToPid(Key.escape, to: tilerPID)
            // Dismissal reads off the pop-up-menu CG window: the classic menu is Tiler's window at
            // that level and leaves the on-screen list exactly when it closes. The AX item is NOT
            // a signal — StatusMenu exposes "Pause Tiler" in the AX tree permanently (verified
            // against the installed app), so a `statusMenuItem == nil` wait could never fire.
            let menuClosed = waitFor(2.0) { paletteWindow() == nil }
            check("6a Esc closes the classic menu", menuClosed != nil, "menu still open")
            checkHighlight("6a after the classic menu:", on: false)
        } else {
            report("6a classic menu", ["no classic menu with Pause Tiler after a right click"])
        }
    } else {
        report("6a palette", ["no palette"])
    }
    if paletteVisible() { _ = pressKey(Key.escape); _ = paletteClosed() }
    focusChecks("6a after the classic menu")
}

// 6. Pause, reached from an open palette: the palette closes; after resuming, the pill is gone.
do {
    if frontmostPID() != helperPID { _ = raiseHelper() }
    if clickStatusItem() != nil, readPalette() != nil {
        checkHighlight("6 palette open before Pause:", on: true)
    } else {
        report("6 palette before Pause", ["no palette"])
    }
    if let pauseItem = openStatusMenu(right: true) {
        _ = AX.perform(pauseItem, kAXPressAction)
        pause(0.4)
        let latency = pressHotkeyAndWait(timeout: 0.5)
        check("6 paused: hotkey does nothing", latency == nil, "palette appeared after \(ms(latency))")
        if latency != nil { _ = pressKey(Key.escape) }
        // Paused, a left click opens the classic menu (StatusMenu), not the palette.
        if let resumeItem = openStatusMenu(right: false) {
            check("6 paused: status item shows the menu", !paletteVisible(), "palette visible while paused")
            _ = AX.perform(resumeItem, kAXPressAction)
            pause(0.4)
            if let state = openWithHotkey("6 resumed") {
                check("6 resumed: header", state.header == targetHeader, "header \(state.header ?? "nil")")
                _ = pressKey(Key.escape)
                _ = paletteClosed()
            }
            checkHighlight("6 after Pause and resume:", on: false)
        } else {
            report("6 paused: status item shows the menu", ["no menu with Pause Tiler after a left click"])
            _ = pressKey(Key.escape)
        }
    } else {
        report("6 pause", ["no classic menu with Pause Tiler after a right click"])
        _ = pressKey(Key.escape)
    }
    focusChecks("6 after pause/resume")
}

// MARK: Other apps' windows

do {
    let after = otherWindows()
    var problems: [String] = []
    for (id, bounds) in othersBefore {
        guard let now = after[id] else { continue } // closed, or not listed by its app right now
        if edgeError(now, bounds) > 1 { problems.append("window \(id) \(describe(bounds)) → \(describe(now))") }
    }
    report("other apps' windows untouched", problems, note: "\(othersBefore.count) windows")
}

// MARK: 7. Idle CPU

do {
    pause(1)
    func cpuSeconds() -> Double? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "time=", "-p", "\(tilerPID)"]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return nil }
        ps.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // [[hh:]mm:]ss.cc
        guard !text.isEmpty else { return nil }
        return text.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }
    let before = cpuSeconds()
    Thread.sleep(forTimeInterval: 10)
    let after = cpuSeconds()
    if tiler?.isRunning != true {
        report("7 idle CPU", ["Tiler is not running (exit status \(tiler?.terminationStatus ?? -1))"])
    } else if let before, let after {
        let percent = (after - before) / 10 * 100
        check("7 idle CPU over 10 s < 1 %", percent < 1, String(format: "%.2f %%", percent),
              note: String(format: "%.2f %% (%.2f s CPU)", percent, after - before))
    } else {
        report("7 idle CPU", ["ps failed"])
    }
}

finish()
