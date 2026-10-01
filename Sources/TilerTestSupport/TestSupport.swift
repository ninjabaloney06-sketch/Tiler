import AppKit
import ApplicationServices
import TilerAX
import TilerCore

// TilerTestSupport — shared helpers for Tiler's live-UI test executables (tiler-hovertest,
// tiler-palettetest), factored out because both drove the same "launch TilerTestWindows + Tiler,
// drive them with HID events, read the palette back over AX" pattern independently and a fix to
// lock handling, cursor restore or HID guards had to be made twice. Each executable still owns
// its own step-by-step checks and process-launch sequencing (those genuinely differ); this module
// holds only the pieces that were byte-for-byte or near-byte-for-byte identical between them.
// `tiler-harness` (C2) is architecturally different — in-process AX driving, no HID events, its
// own Row shape with a scenario column — so only its one truly identical leaf, `screenIsLocked`,
// is shared here; see SPEC §0 SHARED-REPO rules on why the rest of it was left alone.

// MARK: Report

public struct Row: Sendable {
    public let check: String
    public let passed: Bool
    public let detail: String
}

/// Collects PASS/FAIL rows, printing each as it happens (stderr) and the whole table at the end.
@MainActor
public final class TestReport {
    public private(set) var rows: [Row] = []
    private let checkColumnWidth: Int

    public init(checkColumnWidth: Int = 44) {
        self.checkColumnWidth = checkColumnWidth
    }

    public func report(_ check: String, _ problems: [String], note: String = "") {
        let row = Row(check: check, passed: problems.isEmpty, detail: problems.isEmpty ? note : problems.joined(separator: "; "))
        rows.append(row)
        FileHandle.standardError.write(Data("\(row.passed ? "PASS" : "FAIL") \(check) \(row.detail)\n".utf8))
    }

    public func check(_ name: String, _ condition: Bool, _ problem: @autoclosure () -> String, note: String = "") {
        report(name, condition ? [] : [problem()], note: note)
    }

    public func printTable() {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
        }
        print(pad("#", 4) + pad("check", checkColumnWidth) + pad("result", 8) + "detail")
        print(String(repeating: "-", count: 100))
        for (index, row) in rows.enumerated() {
            print(pad("\(index + 1)", 4) + pad(row.check, checkColumnWidth) + pad(row.passed ? "PASS" : "FAIL", 8) + row.detail)
        }
        let failed = rows.filter { !$0.passed }.count
        print("\n\(rows.count) checks, \(rows.count - failed) passed, \(failed) failed")
    }

    public var allPassed: Bool { rows.allSatisfy(\.passed) }
}

// MARK: Waiting

public func pause(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

/// Polls `condition` every 5 ms until it holds or `timeout` passes; returns the elapsed seconds
/// when it held, nil on timeout.
@discardableResult
public func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
    waitForFrom(Date(), timeout, condition)
}

/// Like `waitFor`, but the elapsed time is measured from `start` (e.g. the moment a mouse move
/// was posted) rather than from when polling began.
@discardableResult
public func waitForFrom(_ start: Date, _ timeout: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
    while true {
        if condition() { return Date().timeIntervalSince(start) }
        if Date().timeIntervalSince(start) > timeout { return nil }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
}

public func ms(_ seconds: TimeInterval?) -> String {
    seconds.map { "\(Int(($0 * 1000).rounded())) ms" } ?? "timeout"
}

public func describe(_ r: CGRect?) -> String {
    guard let r else { return "nil" }
    return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
}

public func edgeError(_ a: CGRect?, _ b: CGRect?) -> CGFloat {
    guard let a, let b else { return .infinity }
    return max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
}

// MARK: Screen lock

/// True while the console session is locked (`CGSSessionScreenIsLocked`). Then AX redacts every
/// app and no live check is possible. Shared verbatim with `tiler-harness` (C2) too.
public func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}

// MARK: Paths

/// `<repo>` from a test executable's own `main.swift` file path: `Sources/<target>/main.swift` is
/// always 3 path components below the repo root. Pass the caller's own `#filePath`, not this
/// module's — the file actually being built at that depth is what matters.
public func repoRoot(fromCallerFile file: String) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

public func buildDirectory() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
}

// MARK: Live-UI lock (SPEC §0)

/// Waits for `<repo>/.live-test.lock` (unless `alreadyHeld`, e.g. `--lock-held`), reporting the
/// live-UI-lock row either way. Bails (exit 3) after 10 minutes of waiting. Returns whether this
/// process now owns the lock (and so must `rmdir` it on the way out).
public func acquireLiveUILock(path: String, alreadyHeld: Bool, report: TestReport) -> Bool {
    if !alreadyHeld {
        let start = Date()
        var lastNote = Date.distantPast
        while mkdir(path, 0o755) != 0 {
            if Date().timeIntervalSince(start) > 600 {
                report.report("live-UI lock", ["\(path) still held after 10 min (pass --lock-held if you hold it)"])
                report.printTable()
                exit(3)
            }
            if Date().timeIntervalSince(lastNote) > 30 {
                FileHandle.standardError.write(Data("waiting for the live-UI lock \(path) (pass --lock-held if you already hold it)\n".utf8))
                lastNote = Date()
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }
    report.report("live-UI lock", [], note: alreadyHeld ? "held by the caller" : "taken")
    return !alreadyHeld
}

// MARK: Process cleanup (cursor restore, lock release, log tail)

/// Terminates `helper`/`tiler` (SIGKILL if they don't exit within 2 s), restores the cursor and
/// the original frontmost app, prints Tiler's stderr tail on failure, removes `tempDir`, releases
/// the live-UI lock if owned, and exits with the right code (2 if the screen ended up locked, 1 if
/// any check failed, else 0). Never returns. `additionalCleanup` runs right after the terminate
/// calls and before the wait loop (e.g. closing a helper's stdin pipe).
public func finishLiveTest(
    report: TestReport,
    helper: Process?,
    tiler: Process?,
    helperPID: pid_t,
    tilerPID: pid_t,
    originalCursor: CGPoint,
    originalFrontmost: NSRunningApplication?,
    tempDir: URL,
    tilerLog: URL,
    ownsLock: Bool,
    lockPath: String,
    additionalCleanup: () -> Void = {}
) -> Never {
    if let helper, helper.isRunning { helper.terminate() }
    if let tiler, tiler.isRunning { tiler.terminate() }
    additionalCleanup()
    let deadline = Date().addingTimeInterval(2)
    while (helper?.isRunning == true || tiler?.isRunning == true) && Date() < deadline { pause(0.05) }
    if helper?.isRunning == true { kill(helperPID, SIGKILL) }
    if tiler?.isRunning == true { kill(tilerPID, SIGKILL) }
    CGWarpMouseCursorPosition(originalCursor)
    CGAssociateMouseAndMouseCursorPosition(1)
    if let originalFrontmost, !originalFrontmost.isTerminated, originalFrontmost.processIdentifier != helperPID {
        _ = originalFrontmost.activate()
    }
    if !report.allPassed, let log = try? String(contentsOf: tilerLog, encoding: .utf8), !log.isEmpty {
        print("--- Tiler stderr (last 40 lines) ---")
        print(log.split(separator: "\n").suffix(40).joined(separator: "\n"))
        print("---")
    }
    try? FileManager.default.removeItem(at: tempDir)
    if ownsLock { rmdir(lockPath) }
    let lockedAtEnd = screenIsLocked()
    if lockedAtEnd { report.report("screen unlocked", ["screen locked by the end of the run; results above are not valid"]) }
    report.printTable()
    exit(lockedAtEnd ? 2 : report.allPassed ? 0 : 1)
}

// MARK: AX / CG helpers

public func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

public func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

public func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = AX.point(element), let size = AX.size(element) else { return nil }
    return CGRect(origin: position, size: size)
}

// `static let x = AXUIElementCreateSystemWide()` is a Swift 6 compile error (SPEC §0) — hence
// `nonisolated(unsafe)` on this file-scope global instead.
nonisolated(unsafe) public let systemWideElement: AXUIElement = {
    let element = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(element, 0.5)
    return element
}()

public func pidAt(_ point: CGPoint) -> pid_t? {
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &element) == .success,
          let element else { return nil }
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success ? pid : nil
}

public struct CGWin {
    public let id: CGWindowID
    public let pid: pid_t
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect
    public let owner: String
}

public func cgWindows() -> [CGWin] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int,
              let boundsInfo = info[kCGWindowBounds as String],
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as! CFDictionary) else { return nil }
        return CGWin(id: id, pid: pid, layer: layer, alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                     bounds: bounds, owner: info[kCGWindowOwnerName as String] as? String ?? "?")
    }
}

/// Every other on-screen layer-0 window (any app but the ones in `excludedPIDs`), by CGWindowID,
/// with its AX frame (read only).
public func otherWindows(excluding excludedPIDs: [pid_t]) -> [CGWindowID: CGRect] {
    let skipped: Set<String> = ["WindowManager", "Dock", "Window Server"]
    let pids = Set(cgWindows().filter {
        $0.layer == 0 && !excludedPIDs.contains($0.pid) && !skipped.contains($0.owner)
    }.map(\.pid))
    var frames: [CGWindowID: CGRect] = [:]
    for pid in pids {
        for window in AX.elements(AX.application(pid: pid), kAXWindowsAttribute) {
            guard let id = AX.windowID(window), let frame = axFrame(window) else { continue }
            frames[id] = frame
        }
    }
    return frames
}

public func frontmostPID() -> pid_t? {
    pause(0.02)
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

public func tilerIsActive(tilerPID: pid_t) -> Bool {
    NSRunningApplication(processIdentifier: tilerPID)?.isActive == true
}

/// `\(step): frontmost unchanged` — the check every trigger step ends with (SPEC §8: "the
/// frontmost app never changes").
public func focusChecks(_ step: String, helperPID: pid_t, tilerPID: pid_t, report: TestReport) {
    let front = frontmostPID()
    report.check("\(step): frontmost unchanged", front == helperPID && !tilerIsActive(tilerPID: tilerPID),
                 "frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") (pid \(front.map(String.init) ?? "none")), Tiler active \(tilerIsActive(tilerPID: tilerPID))")
}

// MARK: HID events

public let eventSource = CGEventSource(stateID: .privateState)

/// Mouse events carry no modifiers by default, so a stray flag from an earlier post never leaks
/// into the next one; pass `flags` to simulate a modifier held during the move.
public func postMouse(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = []) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

public func moveMouse(_ point: CGPoint, flags: CGEventFlags = []) {
    postMouse(.mouseMoved, point, flags: flags)
    pause(0.03)
}

/// A left click at `point`, only if the element there belongs to Tiler (hit-tested first).
public func clickTiler(_ point: CGPoint, what: String, tilerPID: pid_t, report: TestReport) -> Bool {
    moveMouse(point)
    guard pidAt(point) == tilerPID else {
        report.report("click \(what)", ["hit-test at \(point) is pid \(pidAt(point).map(String.init) ?? "none"), not Tiler — not clicking"])
        return false
    }
    postMouse(.leftMouseDown, point)
    pause(0.06)
    postMouse(.leftMouseUp, point)
    return true
}

// MARK: Palette via AX (SPEC §4 accessibility identifiers, shared by every trigger)

public func paletteElement(tilerPID: pid_t) -> AXUIElement? {
    let tilerApp = AX.application(pid: tilerPID)
    return AX.elements(tilerApp, kAXWindowsAttribute).first { AX.string($0, kAXTitleAttribute) == "Tiler Palette" }
}

public func identifiedElements(_ root: AXUIElement, depth: Int = 8) -> [String: AXUIElement] {
    var found: [String: AXUIElement] = [:]
    func visit(_ element: AXUIElement, _ level: Int) {
        AXUIElementSetMessagingTimeout(element, 0.5)
        if let id = AX.string(element, "AXIdentifier"), !id.isEmpty { found[id] = element }
        guard level < depth else { return }
        children(element).forEach { visit($0, level + 1) }
    }
    visit(root, 0)
    return found
}

public struct PaletteState {
    public let window: CGWin
    public let elements: [String: AXUIElement]
    public var header: String? { elements["palette-header"].flatMap { AX.string($0, kAXValueAttribute) } }
    public func frame(_ id: String) -> CGRect? { elements[id].flatMap(axFrame) }
    public func enabled(_ id: String) -> Bool? { elements[id].flatMap { AX.bool($0, kAXEnabledAttribute) } }
    public var selected: [String] { elements.filter { AX.bool($0.value, kAXSelectedAttribute) == true }.map(\.key).sorted() }
}

/// Waits for the palette window (via the caller's own `paletteWindow` lookup — hovertest and
/// palettetest tell the palette apart from other Tiler pop-up-menu-level windows differently,
/// see each executable's own `paletteWindow()`) and reads its AX content.
public func readPalette(tilerPID: pid_t, timeout: TimeInterval = 1, paletteWindow: () -> CGWin?) -> PaletteState? {
    var result: PaletteState?
    waitFor(timeout) {
        guard let window = paletteWindow(), let element = paletteElement(tilerPID: tilerPID) else { return false }
        let elements = identifiedElements(element)
        guard elements["palette-header"] != nil else { return false }
        result = PaletteState(window: window, elements: elements)
        return true
    }
    return result
}

public func paletteClosed(timeout: TimeInterval = 0.6, paletteWindow: () -> CGWin?) -> TimeInterval? {
    waitFor(timeout) { paletteWindow() == nil }
}

/// Clicks the palette item `id` (hit-tested).
public func clickItem(_ state: PaletteState, _ id: String, tilerPID: pid_t, report: TestReport) -> Bool {
    guard let frame = state.frame(id) else {
        report.report("click \(id)", ["no AX element \(id) in the palette"])
        return false
    }
    guard state.window.bounds.insetBy(dx: -1, dy: -1).contains(frame) else {
        report.report("click \(id)", ["AX frame \(describe(frame)) outside the palette \(describe(state.window.bounds))"])
        return false
    }
    return clickTiler(CGPoint(x: frame.midX, y: frame.midY), what: id, tilerPID: tilerPID, report: report)
}

// MARK: Helper (TilerTestWindows) process output

/// Buffers a helper process's stdout and hands back whole lines, from any thread (the
/// `FileHandle.readabilityHandler` that feeds `append` runs off the main actor).
nonisolated public final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []

    public init() {}

    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }

    @MainActor public func next(timeout: TimeInterval) -> String? {
        var line: String?
        waitFor(timeout) {
            lock.lock()
            defer { lock.unlock() }
            if !lines.isEmpty { line = lines.removeFirst() }
            return line != nil
        }
        return line
    }
}

// MARK: TilerTestWindows helper windows

public func testWindow(_ title: String, helperPID: pid_t) -> AXUIElement? {
    AX.elements(AX.application(pid: helperPID), kAXWindowsAttribute).first { AX.string($0, kAXTitleAttribute) == title }
}

public func frameOfHelperWindow(_ title: String, helperPID: pid_t) -> CGRect? {
    testWindow(title, helperPID: helperPID).flatMap(axFrame)
}

/// Direct AX placement (not the engine, so no revert history).
public func placeHelperWindow(_ title: String, _ frame: CGRect, helperPID: pid_t) {
    guard let window = testWindow(title, helperPID: helperPID) else { return }
    AX.setSize(window, frame.size)
    AX.setPosition(window, frame.origin)
    AX.setSize(window, frame.size)
    waitFor(1) { edgeError(frameOfHelperWindow(title, helperPID: helperPID), frame) <= 1 }
}

/// Raises an already-resolved TW1 element and waits for the helper to become frontmost.
public func raiseHelper(_ window: AXUIElement, helperPID: pid_t) -> Bool {
    AXWindowEngine.shared.raise(window)
    return waitFor(5) { frontmostPID() == helperPID } != nil
}

/// Expected frame for a single-window preset on `screen` (SPEC §1 geometry, no gap).
public func expectedFrame(_ id: String, screen: NSScreen) -> CGRect {
    let preset = PresetLibrary.preset(id: id)!
    let area = ScreenGeometry.usableArea(of: screen, for: preset, stageManagerInset: TilerSettings.default.stageManagerInset)
    return area.frame(for: preset.rect!)
}
