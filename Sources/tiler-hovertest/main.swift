import AppKit
import ApplicationServices
import TilerAX
import TilerCore
import TilerTestSupport

// tiler-hovertest — live test of the opt-in green-button hover trigger + native-menu suppression
// (SPEC §4.C, §8 "Hover"), C5.
//
//   <build dir>/tiler-hovertest [--lock-held] [--hat-alpha-sweep]
//
// Takes the live-UI lock (<repo>/.live-test.lock; pass --lock-held if the caller already holds
// it), launches TilerTestWindows (2 windows: TW1 frontmost, TW2 behind it) and the Tiler
// executable from the same build directory with `--config <temp json>` (hoverTriggerEnabled =
// true) and TILER_ONLY_PIDS=<helper pid>, so Tiler can only touch the test windows. Then, with
// HID-posted events (every click is hit-tested first and must land on Tiler; the cursor is
// restored and Tiler/the helper are killed on every exit path):
//   1. moving the cursor onto TW1's green button shows the palette within hoverDelay + 150 ms,
//      and the native menu (CGWindowList owner ThemeWidgetControlViewService, layer 101) never
//      appears within 4 s;
//   2. the same with ⌘ held: the native menu appears and the Tiler palette does not;
//   3. clicking a palette preset moves TW1, and the palette fades out;
//   4. moving the cursor away dismisses the palette within ~400 ms;
//   5. clicking the green button itself (through the hat) still toggles full screen, enter then
//      exit then enter again — the second hat-triggered enter, after a full-screen round trip,
//      is the AXPress-on-AXFullScreenButton reliability regression this guards against;
//   6. hovering TW2's green button while TW1 is frontmost still shows the palette (hit-test
//      based, no frontmost check, SPEC §4.C step 2); clicking a preset moves TW2 AND raises it
//      in front of TW1 (SPEC §4.C step 8 — the regression this test guards against);
//   7. idle CPU of Tiler over 10 s < 1 % with the hover trigger ON and the cursor not moving;
//   8. a fast straight move onto the green button (12 raw HID events, 8 ms apart, no final
//      on-target nudge) still shows the palette and the native menu never wins the race —
//      regression check for HoverMonitor's leading-edge throttle dropping the final event.
//   9. a cursor sweeping straight across the green button on its way to minimize (never resting
//      on green for hoverDelay) never shows the palette at all — regression check for
//      `showPalette` firing late on a stale `self.window` check with no "is the cursor still on
//      the button" check; hovering the green button normally still works right after.
// Other apps' layer-0 windows are snapshotted before Tiler launches and compared at the end.
// `--hat-alpha-sweep` runs only the hat-alpha sweep instead (see its MARK below): the check-1
// suppression check at the default hat alpha and at 1/255, 2/255, 3/255, 5/255, plus the hat's
// visibility on a light titlebar at the default.
// Exit 0 = all passed, 1 = a check failed, 2 = screen locked (AX is redacted then; no live check
// is possible), 3 = the lock could not be taken.
//
// Most of the launch/drive/report scaffolding below (the report table, waiting, HID posting,
// AX/CG lookups, palette-over-AX reading, the live-UI lock, process cleanup) is shared with
// tiler-palettetest via TilerTestSupport — see that module's header. What is local here is what
// genuinely differs: this test distinguishes the palette from the near-invisible hover hat (same
// pid, same pop-up-menu level) by a size floor, and drives the green button / hat directly rather
// than the status item or hotkey.

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// MARK: Report

let testReport = TestReport(checkColumnWidth: 48)
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
let hatAlphaSweep = CommandLine.arguments.contains("--hat-alpha-sweep")

nonisolated(unsafe) var helperPID: pid_t = 0
nonisolated(unsafe) var tilerPID: pid_t = 0
nonisolated(unsafe) var ownsLock = false
nonisolated(unsafe) var lockPathC: UnsafeMutablePointer<CChar>? = strdup(lockPath)

let originalCursor = CGEvent(source: nil)?.location ?? .zero
let originalFrontmost = NSWorkspace.shared.frontmostApplication
let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tiler-hovertest-\(getpid())")
let configURL = tempDir.appendingPathComponent("config.json")
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

func finish() -> Never {
    finishLiveTest(report: testReport, helper: helper, tiler: tiler, helperPID: helperPID, tilerPID: tilerPID,
                   originalCursor: originalCursor, originalFrontmost: originalFrontmost,
                   tempDir: tempDir, tilerLog: tilerLog, ownsLock: ownsLock, lockPath: lockPath)
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

/// The palette panel: Tiler's on-screen window at the pop-up menu level, distinguished from the
/// hover hat (SPEC §4.C step 5's `HatPanel`, same level) by a size floor, NOT alpha — `kCGWindowAlpha`
/// reflects the window's own `NSWindow.alphaValue`, which is 1.0 for the hat (its near-invisibility
/// comes from its background fill's alpha, `HatPanel.hatAlpha` (1/255 by default), not the window's) and, since the palette now fades
/// in over ~100 ms (SPEC §4.C step 5), can be anywhere from 0 to 1 for the real palette too — an
/// alpha filter would either match the hat during that fade or miss the real palette entirely. The
/// hat is always exactly the button rect + 3 pt inset (≤ ~25 pt square); the real palette is far
/// larger.
func paletteWindow() -> CGWin? {
    cgWindows().first { $0.pid == tilerPID && $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow))
        && $0.bounds.width > 60 && $0.bounds.height > 60 }
}

func paletteVisible() -> Bool { paletteWindow() != nil }

func paletteClosed(timeout: TimeInterval = 0.6) -> TimeInterval? {
    TilerTestSupport.paletteClosed(timeout: timeout, paletteWindow: paletteWindow)
}

/// The native green-button menu (SPEC §8): owner `ThemeWidgetControlViewService`, layer 101.
func nativeMenuWindowNumbers() -> Set<Int> {
    Set(cgWindows().filter { $0.owner.contains("ThemeWidget") }.map { Int($0.id) })
}

func tilerIsActive() -> Bool { TilerTestSupport.tilerIsActive(tilerPID: tilerPID) }

// MARK: HID events

/// Holds/releases ⌘ as a real key state (not just an event's own flags field), so
/// `NSEvent.modifierFlags` — what `HoverMonitor` reads at detection time — reports it.
func setCommandHeld(_ held: Bool) {
    guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x37, keyDown: held) else { return }
    event.flags = held ? .maskCommand : []
    event.post(tap: .cghidEventTap)
    pause(0.05)
}

func clickTiler(_ point: CGPoint, what: String) -> Bool {
    TilerTestSupport.clickTiler(point, what: what, tilerPID: tilerPID, report: testReport)
}

// MARK: Palette via AX (SPEC §4 accessibility identifiers, shared by every trigger)

func paletteElement() -> AXUIElement? { TilerTestSupport.paletteElement(tilerPID: tilerPID) }

func readPalette(timeout: TimeInterval = 1) -> PaletteState? {
    TilerTestSupport.readPalette(tilerPID: tilerPID, timeout: timeout, paletteWindow: paletteWindow)
}

func clickItem(_ state: PaletteState, _ id: String) -> Bool {
    TilerTestSupport.clickItem(state, id, tilerPID: tilerPID, report: testReport)
}

// MARK: Config (SPEC §8 "Hover (opt-in, only when enabled in the test config)")

let hoverDelay = TilerSettings.default.hoverDelay

do {
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let store = ConfigStore(fileURL: configURL)
    var config = TilerConfig.default
    // `TilerConfig.default`'s own `palette` is already `PaletteLayout.default` — the default
    // placement (SPEC §2), not a minimal test-only layout. Check 5's ghost-hat regression check
    // was reproduced against the default palette (ninja/critic repro), not a stripped-down one,
    // so this leaves it that way rather than overriding it.
    config.settings.hoverTriggerEnabled = true
    // Sweep mode: the longest hover delay (1 s), so the palette (and its shadow) stays off the
    // titlebar while the hat is measured, and the hat alone must hold off the native menu.
    config.settings.hoverDelay = hatAlphaSweep ? 1.0 : hoverDelay
    config.settings.showMacOSMenuByDefault = false
    store.config = config
    guard FileManager.default.fileExists(atPath: configURL.path), store.lastSaveError == nil else {
        bail("config", "could not write \(configURL.path): \(store.lastSaveError ?? "?")")
    }
}

// MARK: Helper (TilerTestWindows)

let lines = LineReader()

do {
    let process = Process()
    process.executableURL = helperURL
    // 2 windows: TW1 (frontmost, used by checks 1-5) and TW2 (background, check 6 — SPEC §4.C
    // step 8's "background windows work too ... the affected window is raised").
    // Sweep mode: `--light` forces the helper to the light (aqua) appearance, the case where the
    // hat's darkening shows most (white titlebar).
    process.arguments = hatAlphaSweep ? ["2", "--light"] : ["2"]
    let output = Pipe()
    process.standardOutput = output
    let reader = lines
    output.fileHandleForReading.readabilityHandler = { handle in reader.append(handle.availableData) }
    do { try process.run() } catch { bail("launch helper", "\(error)") }
    helper = process
    helperPID = process.processIdentifier
    guard lines.next(timeout: 10) == "PID \(helperPID)" else { bail("launch helper", "no PID line") }
}
setenv(WindowEnumerator.pidFilterVariable, "\(helperPID)", 1)

func testWindow(_ title: String = "TW1") -> AXUIElement? { TilerTestSupport.testWindow(title, helperPID: helperPID) }

guard waitFor(10, { testWindow("TW1") != nil && testWindow("TW2") != nil }) != nil else {
    bail("helper window", "TW1/TW2 not found via AX")
}

/// The named test window. Retried for up to 2 s before giving up: right after a full-screen
/// enter/exit the window can be transiently missing from the helper's AX window list while the
/// Space transition settles, and every caller here assumes TW1/TW2 exist once the helper is up
/// — `bail` (not a force unwrap) if that assumption is genuinely false, so a real absence is a
/// reported, cleaned-up failure instead of a raw crash mid-run.
func tw(_ title: String = "TW1") -> AXUIElement {
    if let window = testWindow(title) { return window }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        if let window = testWindow(title) { return window }
    }
    bail("tw(\(title))", "window not found via AX after 2 s")
}

/// `AX.bool(tw(), "AXFullScreen")`, tri-state: `nil` while TW1 is transiently missing from the
/// helper's `kAXWindows` list (that list only holds current-Space windows, and TW1 drops out of
/// it during the full-screen Space transition), `true`/`false` once it can actually be read.
/// Callers must treat `nil` as "unknown, keep waiting" — never coerce it to `false` (that was the
/// bug: `!fullScreen()` under an old `?? false` default read `true` the instant TW1 went missing,
/// which is the START of a transition, not "not full screen").
func fullScreen(_ title: String = "TW1") -> Bool? {
    testWindow(title).flatMap { AX.bool($0, "AXFullScreen") }
}

func frameOfTW(_ title: String = "TW1") -> CGRect? { TilerTestSupport.frameOfHelperWindow(title, helperPID: helperPID) }

func place(_ frame: CGRect, title: String = "TW1") {
    TilerTestSupport.placeHelperWindow(title, frame, helperPID: helperPID)
}

func raiseHelper() -> Bool { TilerTestSupport.raiseHelper(tw(), helperPID: helperPID) }

guard raiseHelper() else {
    bail("helper frontmost", "TilerTestWindows did not become frontmost (front: \(frontmostPID().map(String.init) ?? "none"))")
}

guard let screen = ScreenGeometry.screen(forWindowFrame: frameOfTW() ?? .zero) else { bail("screen", "no screen for TW1") }
let visible = ScreenGeometry.axVisibleFrame(of: screen)
let startFrame = CGRect(x: visible.minX + 300, y: visible.minY + 160, width: 480, height: 320).integral
// TW2 sits fully to the right of TW1 (TW1's right edge is at visible.minX + 780; TW2 starts 40 pt
// past it), so TW2's green button is clear of TW1's rect and the hit-test in check 6 finds TW2's
// button rather than TW1, which is on top everywhere TW1's rect covers.
let startFrame2 = CGRect(x: visible.minX + 820, y: visible.minY + 260, width: 420, height: 280).integral
place(startFrame)
place(startFrame2, title: "TW2")
_ = raiseHelper()
report("helper", [], note: "pid \(helperPID), TW1 \(describe(frameOfTW())), frontmost")

func expectedFrame(_ id: String) -> CGRect { TilerTestSupport.expectedFrame(id, screen: screen) }

/// The green button element + its current AX frame + its center in AX/CG space (top-left origin,
/// y down — the space `AXUIElementCopyElementAtPosition` and `CGEvent(mouseCursorPosition:)` both
/// use), re-read every time (the test window moves between checks). `axFrame` is already in that
/// space, so the center is its own midpoint — no `ScreenGeometry.flip` (that converts to
/// NSScreen's bottom-left, y-up space, which is the wrong space for posting HID mouse events and
/// previously sent every check's cursor to a mirrored, off-target point).
func greenButton(_ title: String = "TW1") -> (button: AXUIElement, axFrame: CGRect, cgCenter: CGPoint)? {
    guard let window = testWindow(title) else { return nil }
    let button = AX.element(window, kAXFullScreenButtonAttribute) ?? AX.element(window, kAXZoomButtonAttribute)
    guard let button, let frame = axFrame(button) else { return nil }
    return (button, frame, CGPoint(x: frame.midX, y: frame.midY))
}

/// The frontmost on-screen window (by CGWindowList z-order, front-to-back — SPEC §1) among the
/// helper's own windows, by title. nil if neither is currently on screen.
func frontmostHelperWindowTitle() -> String? {
    let ids: [String: CGWindowID?] = ["TW1": testWindow("TW1").flatMap(AX.windowID),
                                       "TW2": testWindow("TW2").flatMap(AX.windowID)]
    for win in cgWindows() where win.pid == helperPID {
        if let match = ids.first(where: { $0.value == win.id })?.key { return match }
    }
    return nil
}

func otherWindows() -> [CGWindowID: CGRect] {
    TilerTestSupport.otherWindows(excluding: [helperPID, tilerPID, getpid()])
}

let othersBefore = otherWindows()

// MARK: Tiler

/// Launches the Tiler executable (sets `tiler`/`tilerPID`) and waits for its status item — the
/// simplest reliable "fully launched" signal. `hatAlpha` is passed as `TILER_HAT_ALPHA` (sweep
/// mode); nil leaves `HatPanel`'s default.
func launchTiler(hatAlpha: Double? = nil) {
    let process = Process()
    process.executableURL = tilerURL
    process.arguments = ["--config", configURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment[WindowEnumerator.pidFilterVariable] = "\(helperPID)"
    environment["TILER_HAT_ALPHA"] = hatAlpha.map { "\($0)" }
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    FileManager.default.createFile(atPath: tilerLog.path, contents: nil)
    process.standardError = FileHandle(forWritingAtPath: tilerLog.path)
    do { try process.run() } catch { bail("launch Tiler", "\(error)") }
    tiler = process
    tilerPID = process.processIdentifier

    let tilerApp = AX.application(pid: tilerPID)
    var seen = false
    waitFor(10) {
        guard let bar = AX.element(tilerApp, "AXExtrasMenuBar"), let item = children(bar).first,
              axFrame(item) != nil else { return false }
        seen = true
        return true
    }
    guard seen else { bail("Tiler launch", "no status item within 10 s") }
}

func focusChecks(_ step: String) {
    TilerTestSupport.focusChecks(step, helperPID: helperPID, tilerPID: tilerPID, report: testReport)
}

/// Approaches `point` from a bit below-left, like a real hand, then settles on it — matches the
/// proven approach in `tools/probes/poster.swift`. Returns the moment the cursor actually settled
/// on `point` (right before the final, on-target move) — that, not the start of the approach, is
/// the correct origin for measuring hover latency: the ~130 ms spent getting there must not eat
/// into the budget a check compares against.
@discardableResult
func hoverOnto(_ point: CGPoint) -> Date {
    moveMouse(CGPoint(x: point.x - 40, y: point.y + 40))
    pause(0.1)
    moveMouse(point)
    let settled = Date()
    moveMouse(CGPoint(x: point.x + 0.5, y: point.y))
    return settled
}

/// A fast straight-line approach with NO final on-target nudge (unlike `hoverOnto`): `steps`
/// events, `interval` apart, from well off `point` to exactly `point` on the last event — the
/// regression case (SPEC §4.C step 1) is a cursor that stops moving the instant it lands on the
/// button, so the button-landing event must itself be the last one posted, not followed by a
/// settling correction. Default 12 steps @ 8 ms reproduces the dropped-final-event scenario
/// (`HoverMonitor.globalMouseMoved`'s 40 ms throttle sees accepted queries at +0/40/80 ms and,
/// without the trailing-query fix, drops the +88 ms landing event entirely). Posts raw
/// `.mouseMoved` events (not `moveMouse`, whose extra 30 ms pause per call would itself keep the
/// throttle's leading edge from ever dropping an event). Returns the moment the last event
/// posted.
@discardableResult
func fastStraightMoveOnto(_ point: CGPoint, steps: Int = 12, interval: TimeInterval = 0.008) -> Date {
    let start = CGPoint(x: point.x - 260, y: point.y - 200)
    for i in 0..<steps {
        let t = Double(i) / Double(steps - 1)
        postMouse(.mouseMoved, CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t))
        if i < steps - 1 { Thread.sleep(forTimeInterval: interval) }
    }
    return Date()
}

/// Moves the cursor well away from TW1 and the screen's menu bar, resetting any open hover
/// session.
func moveAway() {
    moveMouse(CGPoint(x: visible.minX + 20, y: visible.minY + 20))
    pause(0.05)
}

// MARK: --hat-alpha-sweep (SPEC §4.C step 4)
//
// The hat must be as invisible as Apple's own button yet still capture hover (alpha 0.0 is
// hover-through). For the default alpha (no TILER_HAT_ALPHA) and for 1/255, 2/255, 3/255, 5/255,
// Tiler is relaunched and check 1's suppression check runs: hover TW1's green button; the native
// menu (owner ThemeWidgetControlViewService, layer 101) must not appear within 4 s. At the
// default, with the helper in the light appearance, the titlebar just right of the green button
// (inside the hat's 3 pt margin, clear of the button) is sampled with and without the hat: the
// difference must be at most 1 level of 255.

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

/// Captures `rect` (AX/CG space, top-left origin) with the `screencapture` CLI (no cursor) and
/// returns its average color; nil if the capture or decode failed.
func captureAverageColor(of rect: CGRect) -> RGB? {
    let path = tempDir.appendingPathComponent("sample-\(UUID().uuidString).png")
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

func describeColor(_ color: RGB) -> String {
    let r = color.r, g = color.g, b = color.b
    return String(format: "(%.1f, %.1f, %.1f)", r, g, b)
}

/// The hover hat: Tiler's small window at the pop-up menu level (the palette is > 60 pt).
func hatWindow() -> CGWin? {
    cgWindows().first { $0.pid == tilerPID && $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow))
        && $0.bounds.width <= 60 && $0.bounds.height <= 60 }
}

/// Moves away and waits until no hat, palette or native menu is left from the previous hover.
func resetHover() {
    moveAway()
    _ = waitFor(2) { hatWindow() == nil && !realPaletteVisible() && nativeMenuWindowNumbers().isEmpty }
    pause(0.3)
}

/// Check 1's suppression check against the running Tiler; true if the native menu stayed away.
func sweepSuppression(_ label: String) -> Bool {
    if frontmostPID() != helperPID { _ = raiseHelper() }
    resetHover()
    guard let (_, _, center) = greenButton() else { bail("sweep \(label)", "no green button on TW1") }
    let start = hoverOnto(center)
    let hatUp = waitFor(0.5) { hatWindow() != nil } != nil
    var nativeSeen: Int?
    let deadline = start.addingTimeInterval(4.0)
    while Date() < deadline, nativeSeen == nil {
        nativeSeen = nativeMenuWindowNumbers().first
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    resetHover()
    check("sweep \(label): native menu never appears within 4 s", nativeSeen == nil,
          "native menu window #\(nativeSeen ?? 0) appeared (hat up: \(hatUp))", note: "hat up: \(hatUp)")
    return nativeSeen == nil
}

/// At the running Tiler's (default) alpha, on the helper's light titlebar: the hat may darken the
/// pixels under it by at most 1 level (1/255). The 0.25 slack absorbs color-conversion rounding
/// between the capture's display profile and the device-RGB buffer.
func measureHatOnLightTitlebar() {
    if frontmostPID() != helperPID { _ = raiseHelper() }
    resetHover()
    guard let (_, buttonFrame, center) = greenButton() else { bail("sweep light titlebar", "no green button on TW1") }
    let region = CGRect(x: buttonFrame.maxX + 0.5, y: buttonFrame.midY - 1, width: 2, height: 2)
    guard let without = captureAverageColor(of: region) else {
        report("sweep light titlebar", [], note: "screencapture unavailable — measurement skipped")
        return
    }
    check("sweep titlebar is light (helper --light)", min(without.r, without.g, without.b) > 200,
          "titlebar sample \(describeColor(without)) — not a light titlebar", note: describeColor(without))
    hoverOnto(center)
    guard waitFor(0.5, { hatWindow() != nil }) != nil, let hat = hatWindow()?.bounds,
          hat.contains(CGPoint(x: region.midX, y: region.midY)) else {
        report("sweep light titlebar: hat over the sample", ["no hat covering \(describe(region)) (hat \(describe(hatWindow()?.bounds)))"])
        resetHover()
        return
    }
    let withHat = captureAverageColor(of: region)
    resetHover()
    guard let withHat else {
        report("sweep light titlebar: hat darkens ≤ 1 level", ["capture with the hat failed"])
        return
    }
    let difference = max(abs(without.r - withHat.r), abs(without.g - withHat.g), abs(without.b - withHat.b))
    let detail = "without hat \(describeColor(without)), with hat \(describeColor(withHat)), Δ \(String(format: "%.2f", difference))"
    check("sweep light titlebar: hat darkens ≤ 1 level", difference <= 1.25, detail, note: detail)
}

if hatAlphaSweep {
    guard frontmostPID() == helperPID || raiseHelper() else { bail("sweep setup", "helper not frontmost") }
    launchTiler()
    measureHatOnLightTitlebar()
    _ = sweepSuppression("default alpha")
    tiler?.terminate()
    tiler?.waitUntilExit()
    var passing: [Int] = []
    for level in [1, 2, 3, 5] {
        launchTiler(hatAlpha: Double(level) / 255)
        if sweepSuppression("alpha \(level)/255") { passing.append(level) }
        tiler?.terminate()
        tiler?.waitUntilExit()
    }
    let summary = passing.isEmpty ? "no alpha suppresses the native menu"
        : "suppressing: " + passing.map { "\($0)/255" }.joined(separator: ", ") + " — lowest \(passing[0])/255"
    print("hat alpha sweep: \(summary)")
    report("sweep summary", passing.isEmpty ? [summary] : [], note: summary)
    finish()
}

launchTiler()
if frontmostPID() != helperPID { _ = raiseHelper() }
check("Tiler launch keeps focus", frontmostPID() == helperPID && !tilerIsActive(),
      "frontmost pid \(frontmostPID().map(String.init) ?? "none"), Tiler active \(tilerIsActive())")

// MARK: 1. Hover shows the palette; the native menu never appears

do {
    guard frontmostPID() == helperPID else { bail("1 setup", "helper not frontmost") }
    guard let (_, buttonAXFrame, center) = greenButton() else { bail("1 button", "no green button on TW1") }
    let start = hoverOnto(center)
    // realPaletteVisible(), not paletteVisible(): the latter also matches the hat (same
    // popUpMenu level, CGWindowAlpha 1 like the palette — the hat's near-invisibility is its
    // background fill's alpha, not the window's), which appears immediately (step 4) while the
    // real palette only appears after hoverDelay (step 5) — measuring against the hat would
    // report a latency of ~0 regardless of hoverDelay.
    let latency = waitForFrom(start, hoverDelay + 0.15 + 0.35) { realPaletteVisible() }
    check("1 palette within hoverDelay(\(hoverDelay)) + 150 ms", latency != nil && latency! <= hoverDelay + 0.15,
          "palette after \(ms(latency))", note: ms(latency))
    // SPEC §4.C step 5: "after the hover delay, fade the palette in (~100 ms)". Sample
    // `kCGWindowAlpha` right after the palette window first exists — before the AX round-trips
    // below (readPalette, focusChecks), which would themselves eat into the 100 ms fade — so a
    // regression to popping in at full opacity in a single frame is caught. `paletteWindow()` is
    // alpha-independent (size-floor only, see its doc comment) so it finds the window at any
    // point in the fade, letting its `.alpha` field be sampled directly.
    if let firstAlpha = paletteWindow()?.alpha {
        check("1 palette fades in, not popped in", firstAlpha < 0.9,
              "alpha already \(String(format: "%.2f", firstAlpha)) right after appearing")
    } else {
        check("1 palette fades in, not popped in", false, "no palette window found right after appearing")
    }
    let fadedIn = waitFor(0.3) { (paletteWindow()?.alpha ?? 0) >= 0.95 }
    check("1 palette fade-in reaches full opacity", fadedIn != nil, "alpha never reached ~0.95 within 300 ms")
    if let state = readPalette() {
        check("1 header names TW1", state.header?.contains("TW1") == true, "header \(state.header ?? "nil")")
    }
    check("1 hovering keeps TW1's button frame", edgeError(axFrame(greenButton()?.button ?? tw()), buttonAXFrame) <= 2,
          "button frame moved while showing the palette")
    focusChecks("1 hover open")

    var nativeSeen: String?
    let deadline = start.addingTimeInterval(4.0)
    while Date() < deadline {
        if let id = nativeMenuWindowNumbers().first { nativeSeen = "window #\(id)" }
        if nativeSeen != nil { break }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    check("1 native green-button menu never appears within 4 s", nativeSeen == nil, "appeared: \(nativeSeen ?? "")")
    moveAway()
    _ = waitFor(1) { !realPaletteVisible() }
}

// MARK: 2. ⌘ held: native menu appears, Tiler palette does not

do {
    guard frontmostPID() == helperPID else { bail("2 setup", "helper not frontmost") }
    guard let (_, _, center) = greenButton() else { bail("2 button", "no green button on TW1") }
    let base = nativeMenuWindowNumbers()
    setCommandHeld(true)
    let start = Date()
    moveMouse(CGPoint(x: center.x - 40, y: center.y + 40), flags: .maskCommand)
    pause(0.1)
    moveMouse(center, flags: .maskCommand)
    var newNative: Int?
    let deadline = start.addingTimeInterval(1.5)
    while Date() < deadline {
        if let id = nativeMenuWindowNumbers().subtracting(base).first { newNative = id }
        if newNative != nil { break }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    check("2 ⌘ held shows the native menu", newNative != nil, "no native menu within 1.5 s")
    check("2 ⌘ held shows no Tiler palette", !paletteVisible(), "palette appeared with ⌘ held")

    // Critic gap (HoverMonitor.queryHoverTarget): SPEC §4.C step 3's ⌘ decision is taken at
    // detection time and must hold until the cursor leaves the button, whatever ⌘ does
    // afterwards — the native menu does not close itself on ⌘ release or a mere cursor move,
    // only on Esc or a click. Release ⌘ with the cursor still ON the button (not moveAway()
    // first, which would also leave the button and trivially pass), nudge 1 pt, wait 1 s, and
    // confirm no Tiler window (hat or real palette) appears at the pop-up-menu level over the
    // still-open native menu. `paletteVisible()`'s >60 pt size floor also excludes the hat, but
    // the fix disables detection entirely for this button, so neither ever shows.
    setCommandHeld(false)
    postMouse(.mouseMoved, CGPoint(x: center.x + 1, y: center.y))
    let afterRelease = waitFor(1) { paletteVisible() }
    check("2 releasing ⌘ over the still-open native menu shows no Tiler window", afterRelease == nil,
          "a Tiler window appeared \(ms(afterRelease)) after releasing ⌘", note: ms(afterRelease))

    // Critic gap (HoverMonitor.queryHoverTarget, follow-up): the hold above must also survive
    // the cursor actually LEAVING the button — not just the 1 pt nudge above, which still hits
    // it — by moving down INTO the still-open native menu itself (a hit-test miss) and back.
    // Reproduces the critic's report live: hold ⌘, let the native menu open (already done
    // above), move into that menu, then move straight back onto the button without ⌘ — no
    // Tiler window may appear. The old per-button hold was cleared on the very miss this
    // performs, exactly when the native menu is most likely still open.
    if let menuRecord = cgWindows().first(where: { $0.owner.contains("ThemeWidget") }) {
        let menuPoint = CGPoint(x: menuRecord.bounds.midX, y: menuRecord.bounds.midY)
        postMouse(.mouseMoved, menuPoint)
        pause(0.05)
        postMouse(.mouseMoved, center)
        let afterReturn = waitFor(1) { paletteVisible() }
        check("2 leaving into the still-open native menu and back to the button shows no Tiler window",
              afterReturn == nil, "a Tiler window appeared \(ms(afterReturn)) after returning", note: ms(afterReturn))
    } else {
        check("2 leaving into the still-open native menu and back to the button shows no Tiler window",
              false, "could not locate the native menu window to move into")
    }

    moveAway()
    _ = waitFor(2) { nativeMenuWindowNumbers().isEmpty }
    focusChecks("2 after ⌘ hover")
}

// MARK: 3. Clicking a preset moves TW1

do {
    place(startFrame)
    guard frontmostPID() == helperPID else { bail("3 setup", "helper not frontmost") }
    guard let (_, _, center) = greenButton() else { bail("3 button", "no green button on TW1") }
    hoverOnto(center)
    guard let state = waitFor(hoverDelay + 0.5, { readPalette() != nil }).flatMap({ _ in readPalette() }) else {
        bail("3 palette", "no palette after hovering")
    }
    let before = frameOfTW()
    if clickItem(state, "preset:left-half") {
        let closed = paletteClosed()
        check("3 palette fades out after apply", closed != nil, "palette still visible", note: ms(closed))
        let expected = expectedFrame("left-half")
        let applied = waitFor(1) { edgeError(frameOfTW(), expected) <= 1 }
        check("3 click Left Half moves TW1", applied != nil,
              "TW1 \(describe(frameOfTW())) (before \(describe(before))), expected \(describe(expected))")
    }
    focusChecks("3 after apply")
    moveAway()
}

// MARK: 4. Leaving dismisses within ~400 ms

do {
    place(startFrame)
    guard frontmostPID() == helperPID else { bail("4 setup", "helper not frontmost") }
    guard let (_, _, center) = greenButton() else { bail("4 button", "no green button on TW1") }
    hoverOnto(center)
    // Wait for the REAL palette (realPaletteVisible), not just the hat (paletteVisible): the hat
    // goes up immediately (step 4), well before hoverDelay, so waiting on paletteVisible() used
    // to let this check start "leaving" before the real palette even existed — the ~109 ms
    // "dismissal" it then measured was actually showPalette's cursor-on-hat guard removing the
    // hat, not a leave-dismissal of anything.
    guard waitFor(hoverDelay + 0.5, { realPaletteVisible() }) != nil else {
        bail("4 palette", "no real palette after hovering")
    }
    let start = Date()
    moveAway()
    let closed = waitForFrom(start, 0.4 + 0.3) { !realPaletteVisible() }
    check("4 leaving dismisses within ~400 ms", closed != nil && closed! <= 0.7, "still visible after \(ms(closed))",
          note: ms(closed))
    focusChecks("4 after leaving")
}

// MARK: 5. Clicking the green button through the hat still toggles full screen: enter, exit, enter

// Critic-reported gap: `AXPress` on `AXFullScreenButton` under a resting cursor returns success
// (or -25204) without moving the window, once the target window has round-tripped through full
// screen once — 8/14 clicks failed on a release build. The fix (`HoverMonitor.pressGreenButton`)
// sets `AXFullScreen` directly instead of forwarding `AXPress` for this subrole. A single
// enter-only check (the previous version of this test) cannot see the regression, since the
// FIRST hat click always worked even on the flaky path — this drives enter → exit → enter and
// requires all three to succeed, so the SECOND hat-triggered enter (after the round trip) is
// actually exercised.
do {
    place(startFrame)
    guard frontmostPID() == helperPID else { bail("5 setup", "helper not frontmost") }

    // Hovers the button fresh (a new hover session each time — the previous one was dismissed by
    // the full-screen transition itself, `TargetCloseWatcher`'s resize notification) and clicks
    // through the hat, exactly like a real user. Returns whether the click itself landed on
    // Tiler; the caller checks what it did.
    func clickGreenButtonThroughHat(_ label: String) -> Bool {
        guard let (_, _, center) = greenButton() else {
            check(label, false, "no green button on TW1")
            return false
        }
        hoverOnto(center)
        _ = waitFor(hoverDelay + 0.5) { paletteVisible() }
        let clicked = clickTiler(center, what: "green button (through the hat)")
        check(label, clicked, "hit-test at the button is not Tiler")
        return clicked
    }

    // Restore not through the hat: hovering a full-screen window is skipped by design (SPEC
    // §4.C step 2), so the hat is never reachable while full screen at all — full screen also
    // removes the titlebar entirely, detaching any button reference captured before the toggle.
    // Set `AXFullScreen` directly instead, the same attribute `AXWindowEngine`/`fullScreen()`
    // read (a check 6 regression otherwise: TW1 left full screen hides TW2 from the AX window
    // list).
    //
    // Critic-reported gap: the enter transition can still be in flight (TW1 transiently missing
    // from the AX window list, or a titlebar-less mid-animation frame) the instant `fullScreen()`
    // first reads `true` above. Setting `AXFullScreen` false immediately, then reading
    // `!fullScreen()` (which the old `?? false` default made `true` the moment TW1 went missing —
    // the START of a transition, not its end), reported "exits full screen" as PASS while TW1 was
    // still full screen or had no titlebar/button yet — the actual bug behind checks 22/26/27
    // failing ("no green button on TW1", ghost hat / stale palette after the round trip). Fixed by
    // (1) waiting for a settled `true` sample plus ~1 s of animation slack before mutating
    // `AXFullScreen`, (2) requiring a positive `false` sample (never a `nil` coerced to it) to
    // call the exit itself done, and (3) waiting for TW1 to be back with its green button inside
    // the restored frame before returning, so the ghost-hat and re-hover checks that immediately
    // follow never run against a still-mid-animation window.
    func exitFullScreenDirectly(_ label: String) {
        _ = waitFor(3, { fullScreen() == true })
        pause(1.0)
        if let window = testWindow() { AX.set(window, "AXFullScreen", NSNumber(value: false)) }
        let exited = waitFor(3) { fullScreen() == false }
        check(label, exited != nil, "AXFullScreen still true after 3 s")
        guard exited != nil else { return }
        _ = waitFor(3) {
            guard fullScreen() == false, let frame = frameOfTW(), let (_, buttonFrame, _) = greenButton() else { return false }
            return frame.contains(CGPoint(x: buttonFrame.midX, y: buttonFrame.midY))
        }
    }

    // Critic-reported gap: `HatPanel.mouseDown` used to forward the click while the mouse button
    // was still physically held down, so `dismissNow`'s `hat.orderOut` (triggered by the resize
    // notification the `AXFullScreen` set itself causes) raced the window server's own
    // full-screen mouse-tracking and lost — 4/6 round-trip clicks and 5/5 separate single-click
    // runs left a real ~22×22 layer-101 hat window on screen that AppKit believed already
    // hidden, so nothing ever ordered it out again; it then ate every hover and click over the
    // button (never cleared merely by leaving — only hovering a DIFFERENT window's green button
    // cleared it). Fixed by forwarding on `mouseUp` instead (`HatPanel.swift`). Checked directly
    // against `CGWindowList` at the button's own (now-restored) AX frame, not
    // `paletteVisible()`/`realPaletteVisible()` — both only ever look for windows ABOVE a size
    // floor to tell the palette from the hat, exactly wrong for a hat-sized ghost.
    func checkNoGhostHatOverButton(_ label: String) {
        guard let (_, axFrame, _) = greenButton() else {
            check(label, false, "no green button on TW1 to check against")
            return
        }
        let probe = axFrame.insetBy(dx: -6, dy: -6)
        let ghosts = cgWindows().filter { $0.pid == tilerPID && $0.bounds.intersects(probe) }
        check(label, ghosts.isEmpty,
              "stale Tiler window(s) over the button: \(ghosts.map { "\(describe($0.bounds)) layer \($0.layer)" })")
    }

    if clickGreenButtonThroughHat("5 first hat click reaches the hat") {
        let wentFullScreen = waitFor(3) { fullScreen() == true }
        check("5 first hat click enters full screen", wentFullScreen != nil, "AXFullScreen still false after 3 s")
    }
    exitFullScreenDirectly("5 exits full screen")
    moveAway()
    pause(0.3)
    checkNoGhostHatOverButton("5 no ghost hat over the button after the first round trip")

    // Reproduction (ninja/critic): hover delay 0.15, wait ~2.5 s before re-hovering, then a
    // 60 ms HID down/up on the button. Expected ~0.6 s to full screen; the flaky path left the
    // hat and hover session up with nothing happening within 4 s.
    pause(2.5)
    if clickGreenButtonThroughHat("5 second hat click reaches the hat (after a full-screen round trip)") {
        let wentFullScreenAgain = waitFor(4) { fullScreen() == true }
        check("5 second hat click re-enters full screen (critic regression)", wentFullScreenAgain != nil,
              "AXFullScreen still false after 4 s — AXPress-only path is flaky on repeat clicks")
    }
    exitFullScreenDirectly("5 exits full screen again")
    moveAway()
    pause(0.3)
    checkNoGhostHatOverButton("5 no ghost hat over the button after the second round trip")

    // Behavioural half of the same gap: with the ghost present, hovering the button no longer
    // showed the palette at all — not late, not once, never. This confirms the fix rather than
    // just the window's absence.
    if let (_, _, center) = greenButton() {
        hoverOnto(center)
        let recovered = waitFor(hoverDelay + 0.5) { realPaletteVisible() }
        check("5 hovering the button still shows the palette after the round trip", recovered != nil,
              "no palette after \(ms(recovered))")
        moveAway()
        _ = waitFor(1) { !realPaletteVisible() }
    } else {
        check("5 hovering the button still shows the palette after the round trip", false, "no green button on TW1")
    }

    focusChecks("5 after full screen toggle")
    place(startFrame)
}

// MARK: 6. Hovering a background window (TW2, while TW1 is frontmost) raises it on apply

do {
    place(startFrame)
    place(startFrame2, title: "TW2")
    _ = raiseHelper() // TW1 frontmost, TW2 behind it
    guard frontmostPID() == helperPID else { bail("6 setup", "helper not frontmost") }
    guard frontmostHelperWindowTitle() == "TW1" else { bail("6 setup", "TW1 not in front of TW2") }
    guard let (_, _, center) = greenButton("TW2") else { bail("6 button", "no green button on TW2") }
    hoverOnto(center)
    guard let state = waitFor(hoverDelay + 0.5, { readPalette() != nil }).flatMap({ _ in readPalette() }) else {
        bail("6 palette", "no palette hovering TW2's green button while TW1 is frontmost")
    }
    if let header = state.header {
        check("6 header names TW2 (background target)", header.contains("TW2"), "header \(header)")
    }
    let before = frameOfTW("TW2")
    if clickItem(state, "preset:left-half") {
        let closed = paletteClosed()
        check("6 palette fades out after apply", closed != nil, "palette still visible", note: ms(closed))
        let expected = expectedFrame("left-half")
        let applied = waitFor(1) { edgeError(frameOfTW("TW2"), expected) <= 1 }
        check("6 click Left Half moves TW2", applied != nil,
              "TW2 \(describe(frameOfTW("TW2"))) (before \(describe(before))), expected \(describe(expected))")
        // SPEC §4.C step 8 / the fixed regression: a preset applied to a background window must
        // raise it, or it lands on the right frame while staying hidden behind TW1.
        let raised = waitFor(1) { frontmostHelperWindowTitle() == "TW2" }
        check("6 TW2 raised in front of TW1 after apply", raised != nil,
              "frontmost helper window is \(frontmostHelperWindowTitle() ?? "none"), expected TW2")
    }
    focusChecks("6 after apply")
    moveAway()
    place(startFrame)
    place(startFrame2, title: "TW2")
    _ = raiseHelper()
}

// MARK: Other apps' windows

do {
    let after = otherWindows()
    var problems: [String] = []
    for (id, bounds) in othersBefore {
        guard let now = after[id] else { continue }
        if edgeError(now, bounds) > 1 { problems.append("window \(id) \(describe(bounds)) → \(describe(now))") }
    }
    report("other apps' windows untouched", problems, note: "\(othersBefore.count) windows")
}

// MARK: 7. Idle CPU with the hover trigger on

do {
    moveAway()
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
        guard !text.isEmpty else { return nil }
        return text.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }
    let before = cpuSeconds()
    Thread.sleep(forTimeInterval: 10)
    let after = cpuSeconds()
    if tiler?.isRunning != true {
        report("7 idle CPU (hover on)", ["Tiler is not running (exit status \(tiler?.terminationStatus ?? -1))"])
    } else if let before, let after {
        let percent = (after - before) / 10 * 100
        check("7 idle CPU over 10 s < 1 % (hover on, cursor still)", percent < 1, String(format: "%.2f %%", percent),
              note: String(format: "%.2f %% (%.2f s CPU)", percent, after - before))
    } else {
        report("7 idle CPU (hover on)", ["ps failed"])
    }
}

// MARK: 8. A fast straight move that stops on the button still beats the native menu
//
// Regression check for HoverMonitor's throttle: a leading-edge-only 40 ms throttle drops every
// event inside its window, so a straight, fast approach whose LAST event happens to land inside
// a throttle window (rather than exactly on a 40 ms boundary) used to vanish — no further mouse
// events arrive once the cursor is at rest, so nothing re-triggered the hit-test, the hat never
// went up, and Apple's native green-button menu appeared on its own ~0.85 s schedule. The fix is
// one trailing query scheduled for the end of the throttle window whenever an event is dropped.

do {
    place(startFrame)
    _ = raiseHelper()
    guard frontmostPID() == helperPID else { bail("8 setup", "helper not frontmost") }
    guard let (_, _, center) = greenButton() else { bail("8 button", "no green button on TW1") }
    moveAway()
    let base = nativeMenuWindowNumbers()
    let start = fastStraightMoveOnto(center)
    // realPaletteVisible(), not paletteVisible() — see check 1's comment: the hat alone would
    // make this pass regardless of whether the real palette ever appeared.
    let latency = waitForFrom(start, hoverDelay + 0.15 + 0.35) { realPaletteVisible() }
    check("8 fast straight move (12 steps @ 8 ms, no final nudge) still shows the palette within hoverDelay(\(hoverDelay)) + 150 ms",
          latency != nil && latency! <= hoverDelay + 0.15, "palette after \(ms(latency))", note: ms(latency))
    var nativeSeen: String?
    let deadline = start.addingTimeInterval(4.0)
    while Date() < deadline {
        if let id = nativeMenuWindowNumbers().subtracting(base).first { nativeSeen = "window #\(id)" }
        if nativeSeen != nil { break }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    check("8 native green-button menu never appears after a fast straight move", nativeSeen == nil,
          "appeared: \(nativeSeen ?? "")")
    focusChecks("8 after fast move")
    moveAway()
    _ = waitFor(1) { !realPaletteVisible() }
}

/// Whether the real palette panel (not the hover hat) is on screen. `paletteWindow()`'s
/// `alpha > 0.5` filter cannot tell them apart: `kCGWindowAlpha` reflects the window's own
/// `NSWindow.alphaValue` (1.0 for both the palette and the hat — the hat's near-invisibility
/// comes from its background fill color's alpha, `HatPanel.hatAlpha`, not the window's), and both sit at the
/// same `.popUpMenu` level. The hat is always exactly the button rect + 3 pt inset (≤ ~25 pt
/// square); the real palette is far larger, so a size floor tells them apart.
func realPaletteVisible() -> Bool {
    cgWindows().contains { $0.pid == tilerPID && $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow))
        && $0.bounds.width > 60 && $0.bounds.height > 60 }
}

// MARK: 9. Sweeping across the green button towards minimize never opens the palette
//
// Regression check for the critic-reported gap this build fixes: `showPalette` only checked that
// the target window was unchanged, never that the cursor was still on the button, so a cursor
// that swept across the green button on its way to another titlebar button (never resting on
// green for hoverDelay) still got the palette 100+ ms after it had already moved on, and it
// stayed open while the cursor sat on minimize. Confirmed live before the fix: palette at 449 ms
// for a sweep at 500 pt/s (227-267 ms actually over green, rest on minimize at 307 ms), 659 ms at
// 250 pt/s — both cases the cursor had left green well before the palette appeared.

do {
    place(startFrame)
    _ = raiseHelper()
    guard frontmostPID() == helperPID else { bail("9 setup", "helper not frontmost") }
    guard let (_, _, greenCenter) = greenButton() else { bail("9 button", "no green button on TW1") }
    guard let minimizeElement = AX.element(tw(), kAXMinimizeButtonAttribute), let minimizeFrame = axFrame(minimizeElement)
    else { bail("9 button", "no minimize button on TW1") }
    let yellowCenter = CGPoint(x: minimizeFrame.midX, y: minimizeFrame.midY)
    moveAway()

    // Start well past green on the side away from minimize, so the straight line to minimize
    // crosses right over green's hot region instead of starting inside it.
    let dx = yellowCenter.x - greenCenter.x
    let start = CGPoint(x: greenCenter.x - dx * 2, y: greenCenter.y)
    moveMouse(start)

    // Raw `.mouseMoved` events (not `moveMouse`, whose pause would itself slow this below hand
    // speed), 4 pt every 8 ms == 500 pt/s — an ordinary hand speed, no pause/settle on green, no
    // final on-target nudge at minimize (the cursor stops moving the instant it lands there, like
    // `fastStraightMoveOnto`).
    let stepDistance: CGFloat = 4
    let stepInterval: TimeInterval = 0.008
    let totalDistance = max(hypot(yellowCenter.x - start.x, yellowCenter.y - start.y), 1)
    let steps = max(Int((totalDistance / stepDistance).rounded()), 1)
    let sweepStart = Date()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = CGPoint(x: start.x + (yellowCenter.x - start.x) * t, y: start.y + (yellowCenter.y - start.y) * t)
        postMouse(.mouseMoved, point)
        if i < steps { Thread.sleep(forTimeInterval: stepInterval) }
    }

    // The palette must never appear at all, not even briefly — poll the whole window a late
    // `showPalette` firing could still land in (hoverDelay past when the sweep reached green),
    // plus slack for the grace-timer path.
    let deadline = sweepStart.addingTimeInterval(hoverDelay + 0.5)
    var everVisible = false
    while Date() < deadline {
        if realPaletteVisible() { everVisible = true; break }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    check("9 sweeping past the green button towards minimize never shows the palette", !everVisible,
          "palette appeared during/after the sweep")
    focusChecks("9 after pass-through sweep")

    // The session `showPalette` ended mid-sweep must leave clean state: hovering green normally
    // right afterwards still works.
    hoverOnto(greenCenter)
    let recovered = waitFor(hoverDelay + 0.5) { realPaletteVisible() }
    check("9 hovering green still works right after a pass-through sweep", recovered != nil,
          "no palette after \(ms(recovered))")
    moveAway()
    _ = waitFor(1) { !paletteVisible() }
    place(startFrame)
}

// MARK: 10. Leaving along the titlebar (past the palette, not through it) dismisses
//
// Regression check for the critic-reported gap this build fixes: `isInsideHotRegion` used to pad
// the hat ∪ palette union by a flat 24 pt on every side. The palette sits flush under the button
// by default (AX button bottom 224, palette top 223), so that flat margin reached ~24 pt above
// the palette's top edge — covering the whole titlebar strip across the palette's width (514 pt
// with the default layout), the minimize button, and the space just above the window. Sliding
// from the green button along the titlebar (e.g. towards minimize, to drag the window) left the
// palette open until the next click. The fix restricts the corridor between hat and palette to
// the hat's own (narrow) x-range, so a point further along the titlebar — clear of that corridor
// but still well inside the old 24 pt-padded rectangle — must now dismiss.

do {
    place(startFrame)
    _ = raiseHelper()
    guard frontmostPID() == helperPID else { bail("10 setup", "helper not frontmost") }
    guard let (_, buttonAXFrame, center) = greenButton() else { bail("10 button", "no green button on TW1") }
    hoverOnto(center)
    guard waitFor(hoverDelay + 0.5, { realPaletteVisible() }) != nil else {
        bail("10 palette", "no real palette after hovering")
    }
    // Same height as the button (inside the titlebar strip, above the palette), well to the
    // right of the hat — but still inside the test window and inside where the old 24 pt margin
    // used to read as "inside" (comfortably within the palette's width).
    let windowRight = frameOfTW()?.maxX ?? (buttonAXFrame.midX + 1000)
    let titlebarPoint = CGPoint(x: min(buttonAXFrame.midX + 150, windowRight - 20), y: buttonAXFrame.midY)
    let start = Date()
    moveMouse(titlebarPoint)
    let closed = waitForFrom(start, 0.4 + 0.3) { !realPaletteVisible() }
    check("10 leaving along the titlebar dismisses within ~400 ms", closed != nil && closed! <= 0.7,
          "still visible after \(ms(closed)) (moved to (\(titlebarPoint.x), \(titlebarPoint.y)))", note: ms(closed))
    focusChecks("10 after leaving along the titlebar")
    moveAway()
    _ = waitFor(1) { !realPaletteVisible() }
    place(startFrame)
}

finish()
