import AppKit
import TilerAX
import TilerCore
// Only `screenIsLocked()` (see below) is shared with tiler-hovertest/tiler-palettetest — a plain
// `import TilerTestSupport` would also bring in its own `cgWindows()` etc., which collide by name
// with this file's differently-shaped locals (no `alpha` field, decoded via NSNumber casts).
import func TilerTestSupport.screenIsLocked

// tiler-harness — live test of the window engine against TilerTestWindows windows (SPEC §7, §8).
//
//   .build-c2/debug/tiler-harness
//
// Launches TilerTestWindows (17 windows; TW2 min-size 480×440, TW3 fixed 360×240) from the same
// build directory, sets TILER_ONLY_PIDS=<its pid> before the first engine call, and then:
//   0. every preset has its width variant (`<id>` full visibleFrame, `<id>-sm` minus the Stage
//      Manager inset on the left) and the engine's usable areas equal the ones computed here;
//   1. every move & resize / center preset (both variants) on TW1 (strict ≤ 1 pt per edge vs
//      Geometry; left/right edges exactly on visibleFrame.minX (+ inset) / maxX), TW2 and TW3
//      (re-align rule), each followed by Revert (≤ 1 pt back to the start frame); TW1 frames of
//      neighbouring presets of one variant touch (no gaps);
//   2. every arrange preset (both variants) with k−1, k and k+1 visible windows (k = slots), and
//      additionally with exactly 1 and exactly 2 visible windows whenever k > 2 (for k ≤ 2 those
//      coincide with the k−1 / k scenarios):
//      windows are first placed near shuffled slots; the harness checks each landed in its
//      nearest slot (cost of SPEC §1 step 4), that the hovered TW1 is always kept, that windows
//      beyond the visible ones stay untouched, that neighbouring slots / windows share edges
//      exactly and the rightmost end at visibleFrame.maxX, and that Revert of the arrange
//      restores every frame; with exactly 2 windows the two land in different slots at the
//      pairing with the least total cost (brute-forced here from the 2×2 cost matrix);
//      Revert also after windows were ordered out and in again ("show 0" → "show N", which
//      replaces their AX elements): one window, a whole arrange, and an arrange with one window
//      still ordered out (it keeps its history and is restored by a second Revert once shown);
//   3. target capture for the menu-bar / hotkey triggers: `focusedWindow()` follows the focused
//      test window (TW1, TW2), its element drives `apply`, and it is nil when the helper is not in
//      TILER_ONLY_PIDS, while TW1 has a sheet, and with no window shown ("show 0"); arrange with
//      `hoveredWindow: nil` keeps the front-most windows in plain z-order (checks as in 2);
//   4. before/after snapshots of every other on-screen layer-0 window (all apps but the helper):
//      CGWindowList bounds, or for Stage Manager strip thumbnails the AX frame, must not change.
// Prints one table row per check and exits 1 on any failure. The helper is killed at the end on
// every path (and exits on its own via --control EOF if this process dies), so its windows are on
// screen only while the harness runs.
// Exits 2 without launching the helper while the screen is locked (AX is redacted then, so no live
// check is possible), and 2 if the screen was locked by the end of the run (results invalid).

signal(SIGPIPE, SIG_IGN)

let engine = AXWindowEngine.shared
let settings = TilerSettings.default
engine.settings = settings

// MARK: Report

struct Row {
    let check: String
    let scenario: String
    let passed: Bool
    let maxError: CGFloat?
    let detail: String
}

var rows: [Row] = []

func report(_ check: String, _ scenario: String, _ problems: [String], maxError: CGFloat? = nil, note: String = "") {
    let row = Row(check: check, scenario: scenario, passed: problems.isEmpty, maxError: maxError,
                  detail: problems.isEmpty ? note : problems.joined(separator: "; "))
    rows.append(row)
    let error = maxError.map { String(format: "%.2f", Double($0)) } ?? "-"
    FileHandle.standardError.write(Data("\(row.passed ? "PASS" : "FAIL") \(check) [\(scenario)] err=\(error) \(row.detail)\n".utf8))
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func printTable() {
    let header = pad("#", 4) + pad("check", 26) + pad("scenario", 34) + pad("result", 8) + pad("max err pt", 12) + "detail"
    print(header)
    print(String(repeating: "-", count: header.count + 20))
    for (index, row) in rows.enumerated() {
        let error = row.maxError.map { String(format: "%.2f", Double($0)) } ?? "-"
        print(pad("\(index + 1)", 4) + pad(row.check, 26) + pad(row.scenario, 34)
              + pad(row.passed ? "PASS" : "FAIL", 8) + pad(error, 12) + row.detail)
    }
    let failed = rows.filter { !$0.passed }.count
    print("\n\(rows.count) checks, \(rows.count - failed) passed, \(failed) failed")
}

// MARK: Geometry helpers (independent of the engine)

/// Largest edge difference; infinity if either frame is unknown (unreadable window).
func edgeError(_ a: CGRect, _ b: CGRect) -> CGFloat {
    guard !a.isNull, !b.isNull else { return .infinity }
    return max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
}

func describe(_ r: CGRect) -> String {
    "(\(r.minX),\(r.minY) \(r.width)x\(r.height))"
}

/// SPEC §1 step 4 cost, re-implemented here so the closest-slot check does not reuse the engine.
func cost(_ window: CGRect, _ slot: CGRect) -> CGFloat {
    hypot(window.midX - slot.midX, window.midY - slot.midY)
        + 0.5 * (abs(window.width - slot.width) + abs(window.height - slot.height))
}

/// Whether `b` lies directly right of / below `a` in unit space (shared edge, overlapping span).
/// Shared unit edges are bit-identical doubles (UnitRect.split), so `==` is exact.
func adjacency(_ a: UnitRect, _ b: UnitRect) -> (right: Bool, below: Bool) {
    let rowsOverlap = a.minY < b.maxY && b.minY < a.maxY
    let columnsOverlap = a.minX < b.maxX && b.minX < a.maxX
    return (a.maxX == b.minX && rowsOverlap, a.maxY == b.minY && columnsOverlap)
}

/// "No gaps" checks for frames laid out from `units` (SPEC §1 "No gaps", "Width variants"):
/// neighbours share their edge within `tolerance`, and frames on the right edge end at
/// visibleFrame.maxX. Returns the problems.
func touching(_ units: [UnitRect], _ frames: [CGRect], names: [String], tolerance: CGFloat) -> [String] {
    var problems: [String] = []
    for i in units.indices {
        if units[i].maxX == 1 && abs(frames[i].maxX - visibleFrame.maxX) > tolerance {
            problems.append("\(names[i]) ends at \(frames[i].maxX), not visibleFrame.maxX \(visibleFrame.maxX)")
        }
        for j in units.indices where i != j {
            let (right, below) = adjacency(units[i], units[j])
            if right && abs(frames[i].maxX - frames[j].minX) > tolerance {
                problems.append("\(names[i])|\(names[j]) gap \(frames[j].minX - frames[i].maxX)")
            }
            if below && abs(frames[i].maxY - frames[j].minY) > tolerance {
                problems.append("\(names[i])/\(names[j]) gap \(frames[j].minY - frames[i].maxY)")
            }
        }
    }
    return problems
}

/// The documented re-align rule (FrameSetter.alignedFrame), re-implemented: per axis differing by
/// more than 1 pt, anchor to the one usable-area edge the target touches, else center (pixel
/// snapped); then nudge inside the usable area.
func realignedFrame(size: CGSize, target: CGRect, unit: UnitRect?, bounds: CGRect, scale: CGFloat) -> CGRect {
    func place(_ length: CGFloat, _ start: CGFloat, _ span: CGFloat, _ leading: Bool, _ trailing: Bool) -> CGFloat {
        if abs(length - span) <= 1 { return start }
        if leading != trailing { return leading ? start : start + span - length }
        return ((start + (span - length) / 2) * scale).rounded() / scale
    }
    var x = place(size.width, target.minX, target.width, unit?.minX == 0, unit?.maxX == 1)
    var y = place(size.height, target.minY, target.height, unit?.minY == 0, unit?.maxY == 1)
    x = max(min(x, bounds.maxX - size.width), bounds.minX)
    y = max(min(y, bounds.maxY - size.height), bounds.minY)
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

// MARK: Test windows

enum Constraint {
    case none
    case minSize(CGSize)
    case fixed
}

struct TestWindow {
    let number: Int
    var element: AXUIElement
    let windowID: CGWindowID
    let constraint: Constraint
    var initial: CGRect = .zero
    var name: String { "TW\(number)" }
    var label: String {
        switch constraint {
        case .none: return "\(name) resizable"
        case .minSize(let size): return "\(name) min \(Int(size.width))x\(Int(size.height))"
        case .fixed: return "\(name) fixed-size"
        }
    }
}

func frame(_ window: TestWindow) -> CGRect {
    AX.frame(window.element) ?? .null
}

/// Staging move straight through AX (not the engine, so it leaves no revert history).
func place(_ window: TestWindow, _ target: CGRect) {
    AX.setSize(window.element, target.size)
    AX.setPosition(window.element, target.origin)
    AX.setSize(window.element, target.size)
}

/// Expected frame after the engine moved `window` to `target`.
func expected(_ window: TestWindow, target: CGRect, unit: UnitRect?, area: UsableArea, sizeBefore: CGSize) -> CGRect {
    switch window.constraint {
    case .none:
        return target
    case .minSize(let minimum):
        let size = CGSize(width: max(target.width, minimum.width), height: max(target.height, minimum.height))
        return realignedFrame(size: size, target: target, unit: unit, bounds: area.rect, scale: area.scale)
    case .fixed:
        return realignedFrame(size: sizeBefore, target: target, unit: unit, bounds: area.rect, scale: area.scale)
    }
}

// MARK: CoreGraphics views

struct CGWindow {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let layer: Int
    let bounds: CGRect
}

/// On-screen windows, front to back.
func cgWindows() -> [CGWindow] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return info.compactMap { record in
        guard let id = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (record[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let dict = record[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict)
        else { return nil }
        return CGWindow(id: id, pid: pid, owner: record[kCGWindowOwnerName as String] as? String ?? "?",
                        layer: layer, bounds: bounds)
    }
}

/// Waits until CG bounds of `windows` agree with their AX frames (≤ 1 pt). Returns the problems.
func settle(_ windows: [TestWindow], timeout: TimeInterval = 1.5) -> [String] {
    let deadline = Date().addingTimeInterval(timeout)
    var problems: [String] = []
    repeat {
        let bounds = Dictionary(cgWindows().map { ($0.id, $0.bounds) }, uniquingKeysWith: { a, _ in a })
        problems = windows.compactMap { window in
            let ax = frame(window)
            guard let cg = bounds[window.windowID] else { return "\(window.name) not on screen in CG" }
            return edgeError(cg, ax) <= 1 ? nil : "\(window.name) CG \(describe(cg)) != AX \(describe(ax))"
        }
        if problems.isEmpty { return [] }
        Thread.sleep(forTimeInterval: 0.03)
    } while Date() < deadline
    return problems
}

// MARK: Helper process

nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var lines: [String] = []
    private var closed = false

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { closed = true; return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
    }

    func nextLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                return line
            }
            let isClosed = closed
            lock.unlock()
            if isClosed { return nil }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
}

let windowCount = 17
var testWindows: [TestWindow] = []
let minSizeWindow = 2
let minimumSize = CGSize(width: 480, height: 440)
let fixedWindow = 3

let helperURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("TilerTestWindows")
let helper = Process()
helper.executableURL = helperURL
helper.arguments = ["\(windowCount)", "--min-size", "\(minSizeWindow):\(Int(minimumSize.width))x\(Int(minimumSize.height))",
                    "--fixed-size", "\(fixedWindow)", "--control"]
let helperInput = Pipe()
let helperOutput = Pipe()
let helperLines = LineBuffer()
helper.standardInput = helperInput
helper.standardOutput = helperOutput
do {
    let buffer = helperLines
    helperOutput.fileHandleForReading.readabilityHandler = { handle in
        buffer.append(handle.availableData)
    }
}

func stopHelper() {
    helperOutput.fileHandleForReading.readabilityHandler = nil
    try? helperInput.fileHandleForWriting.close()
    guard helper.isRunning else { return }
    helper.terminate()
    let deadline = Date().addingTimeInterval(2)
    while helper.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if helper.isRunning { kill(helper.processIdentifier, SIGKILL) }
}

// `screenIsLocked()` (true while `CGSSessionScreenIsLocked` — then AX redacts every app and CG
// bounds come back shifted and scaled, so no engine check can run) is shared via TilerTestSupport,
// identical here to tiler-hovertest/tiler-palettetest. The rest of that module targets their HID
// black-box pattern (external Tiler process, mouse/keyboard posting, palette-over-AX) which this
// harness doesn't use — it drives the AX engine in-process — so it isn't a fit here.

let screenLockedMessage = "screen locked — AX redacted, live check impossible"

func finish() -> Never {
    stopHelper()
    let lockedAtEnd = screenIsLocked()
    if lockedAtEnd { report("screen unlocked", "end of run", ["\(screenLockedMessage); results above are not valid"]) }
    if helper.processIdentifier > 0 {
        let deadline = Date().addingTimeInterval(3)
        var left = 0
        repeat {
            left = cgWindows().filter { $0.pid == helper.processIdentifier }.count
            if left == 0 && !helper.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        report("helper stopped", "TilerTestWindows killed", helper.isRunning || left > 0 ? ["\(left) helper windows still on screen"] : [])
    }
    printTable()
    exit(lockedAtEnd ? 2 : rows.allSatisfy(\.passed) ? 0 : 1)
}

func bail(_ check: String, _ problem: String) -> Never {
    report(check, "setup", [problem])
    finish()
}

/// Sends a control command; after `show` the AX elements are re-resolved by CGWindowID, because
/// ordering a window out and in again invalidates its old AXUIElement.
func send(_ command: String) -> Bool {
    try? helperInput.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    guard helperLines.nextLine(timeout: 3) == "OK \(command)" else { return false }
    refreshElements()
    return true
}

func refreshElements() {
    let byID = Dictionary(
        AX.elements(AX.application(pid: helper.processIdentifier), kAXWindowsAttribute).compactMap { element in
            AX.windowID(element).map { ($0, element) }
        }, uniquingKeysWith: { a, _ in a })
    for index in testWindows.indices {
        if let element = byID[testWindows[index].windowID] { testWindows[index].element = element }
    }
}

// MARK: Setup

// Checked before the helper opens any window: while locked, the wait for TW1…TWn below could only
// fail with a misleading "0 of n windows via AX".
if screenIsLocked() {
    report("screen unlocked", "setup", [screenLockedMessage])
    printTable()
    exit(2)
}
guard AXIsProcessTrusted() else {
    bail("accessibility", "AXIsProcessTrusted() is false — run from a shell that has Accessibility trust")
}
guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
    bail("launch helper", "TilerTestWindows not found at \(helperURL.path)")
}
do {
    try helper.run()
} catch {
    bail("launch helper", "\(error)")
}
guard let pidLine = helperLines.nextLine(timeout: 10), pidLine == "PID \(helper.processIdentifier)" else {
    bail("launch helper", "helper did not print PID \(helper.processIdentifier)")
}
let testPID = helper.processIdentifier

// The safety fence (SPEC §0): from here on the engine may only touch the helper's windows.
setenv(WindowEnumerator.pidFilterVariable, "\(testPID)", 1)
guard WindowEnumerator.pidFilter == [testPID] else { bail("pid filter", "TILER_ONLY_PIDS not in effect") }
report("pid filter", "TILER_ONLY_PIDS=\(testPID)", [])

// Wait for TW1…TWn via AX.
let windowDeadline = Date().addingTimeInterval(10)
while Date() < windowDeadline {
    var byNumber: [Int: TestWindow] = [:]
    for element in AX.elements(AX.application(pid: testPID), kAXWindowsAttribute) {
        guard let title = AX.string(element, kAXTitleAttribute), title.hasPrefix("TW"),
              let number = Int(title.dropFirst(2)), let id = AX.windowID(element) else { continue }
        let constraint: Constraint = number == minSizeWindow ? .minSize(minimumSize) : number == fixedWindow ? .fixed : .none
        byNumber[number] = TestWindow(number: number, element: element, windowID: id, constraint: constraint)
    }
    if byNumber.count == windowCount {
        testWindows = (1...windowCount).compactMap { byNumber[$0] }
        break
    }
    Thread.sleep(forTimeInterval: 0.1)
}
guard testWindows.count == windowCount else {
    let seen = AX.elements(AX.application(pid: testPID), kAXWindowsAttribute).map { AX.string($0, kAXTitleAttribute) ?? "?" }
    bail("helper windows", "only \(testWindows.count) of \(windowCount) windows via AX (AX lists \(seen))")
}

// Activate the helper through AX (with the screen locked it cannot activate itself; with Stage
// Manager on, windows of an inactive app sit in the strip).
engine.raise(testWindows[0].element)
let activation = settle(testWindows, timeout: 5)
guard activation.isEmpty else { bail("helper on stage", activation.joined(separator: "; ")) }
for index in testWindows.indices { testWindows[index].initial = frame(testWindows[index]) }
report("helper windows", "\(windowCount) windows via AX + CG", [], note: "pid \(testPID)")

guard let screen = ScreenGeometry.screen(forWindowFrame: testWindows[0].initial) else { bail("screen", "no screen") }

// Usable areas computed here without the engine (SPEC §1 "Width variants"): visibleFrame flipped
// with the primary screen; `-sm` presets leave the Stage Manager inset free on the left; gap 0.
// Edges are rounded to whole points: window frames cannot sit on half points (the system
// truncates them), so a half-point grid would leave 1 pt gaps between windows.
let primaryHeight = NSScreen.screens[0].frame.maxY
let visibleNS = screen.visibleFrame
let visibleFrame = CGRect(x: visibleNS.minX, y: primaryHeight - visibleNS.maxY, width: visibleNS.width, height: visibleNS.height)
let stageManagerInset = CGFloat(settings.stageManagerInset)

func isStageManagerVariant(_ preset: Preset) -> Bool { preset.id.hasSuffix("-sm") }

func usableArea(for preset: Preset) -> UsableArea {
    var rect = visibleFrame
    if isStageManagerVariant(preset) {
        rect.origin.x += stageManagerInset
        rect.size.width -= stageManagerInset
    }
    return UsableArea(rect: rect, scale: 1)
}

// Every preset has its partner variant with the same kind and rects.
do {
    var problems: [String] = []
    for preset in PresetLibrary.all {
        let partnerID = isStageManagerVariant(preset) ? String(preset.id.dropLast(3)) : preset.id + "-sm"
        guard let partner = PresetLibrary.preset(id: partnerID) else {
            problems.append("\(preset.id) has no \(partnerID)")
            continue
        }
        if partner.kind != preset.kind || partner.rects != preset.rects { problems.append("\(partnerID) differs from \(preset.id)") }
    }
    let variants = PresetLibrary.all.filter(isStageManagerVariant).count
    report("width variants", "\(PresetLibrary.all.count) presets in library", problems,
           note: "\(PresetLibrary.all.count - variants) full + \(variants) -sm")
}

for id in ["fill", "fill-sm"] {
    guard let preset = PresetLibrary.preset(id: id) else { continue }
    let mine = usableArea(for: preset)
    let engines = ScreenGeometry.usableArea(of: screen, for: preset, stageManagerInset: settings.stageManagerInset)
    report("usable area", id, engines == mine ? [] : ["engine \(describe(engines.rect)) != \(describe(mine.rect))"],
           note: describe(mine.rect))
}

// Every other on-screen layer-0 window (the only layer the engine ever acts on), snapshotted once
// the helper is on stage — launch and activation themselves let Stage Manager rearrange its
// strip, which is the system, not the engine. With Stage Manager on, CG reports a strip window's
// thumbnail as its bounds (it coincides with a WindowManager-owned window, and WindowManager
// re-renders thumbnails with ±1 pt jitter), so for those the real frame is read via AX (read
// only). WindowManager's own strip chrome is not a user window and is skipped.
struct OtherWindow {
    let window: CGWindow
    /// Real frame for Stage Manager strip windows (AX, read only); nil otherwise.
    let stripFrame: CGRect?
    var isStripWindow: Bool { stripFrame != nil }
}

func otherWindows() -> [CGWindowID: OtherWindow] {
    let own = getpid()
    let all = cgWindows().filter { $0.pid != testPID && $0.pid != own && $0.layer == 0 }
    let chrome = all.filter { $0.owner == "WindowManager" }.map(\.bounds)
    var axFrames: [pid_t: [CGWindowID: CGRect]] = [:]
    var result: [CGWindowID: OtherWindow] = [:]
    for window in all where window.owner != "WindowManager" {
        var stripFrame: CGRect?
        if chrome.contains(where: { edgeError($0, window.bounds) <= 0.5 }) {
            if axFrames[window.pid] == nil {
                var frames: [CGWindowID: CGRect] = [:]
                for element in AX.elements(AX.application(pid: window.pid), kAXWindowsAttribute) {
                    if let id = AX.windowID(element), let frame = AX.frame(element) { frames[id] = frame }
                }
                axFrames[window.pid] = frames
            }
            stripFrame = axFrames[window.pid]?[window.id] ?? .null
        }
        result[window.id] = OtherWindow(window: window, stripFrame: stripFrame)
    }
    return result
}

/// Same windows, same strip state, same frames (±0.5 pt).
func sameOthers(_ a: [CGWindowID: OtherWindow], _ b: [CGWindowID: OtherWindow]) -> Bool {
    a.count == b.count && a.allSatisfy { id, old in
        guard let new = b[id], new.isStripWindow == old.isStripWindow else { return false }
        let (x, y) = (old.stripFrame ?? old.window.bounds, new.stripFrame ?? new.window.bounds)
        return (x.isNull && y.isNull) || edgeError(x, y) <= 0.5
    }
}

// The baseline is taken once two reads 0.3 s apart agree (at most 5 s): the helper's activation
// makes Stage Manager animate the previous stage's windows into its strip, and a read mid-flight
// would count such a window as a normal one that later "moved into the Stage Manager strip".
var othersBefore = otherWindows()
do {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.3)
        let again = otherWindows()
        let stable = sameOthers(othersBefore, again)
        othersBefore = again
        if stable { break }
    }
}

// MARK: 1. Move & resize and center presets

guard send("show 3") else { bail("helper control", "no reply to show 3") }
let singleTargets = Array(testWindows.prefix(3))
var landed: [String: CGRect] = [:]  // preset id → TW1 frame after apply

for preset in PresetLibrary.all where preset.kind != .arrange {
    let area = usableArea(for: preset)
    for window in singleTargets {
        var problems: [String] = []
        if edgeError(frame(window), window.initial) > 0.5 { place(window, window.initial) }
        let before = frame(window)
        let bystanders = singleTargets.filter { $0.number != window.number }.map { ($0, frame($0)) }

        let result = engine.apply(preset: preset, hoveredWindow: window.element, screen: screen)
        let after = frame(window)
        if window.number == 1 { landed[preset.id] = after }
        let target = preset.rect.map(area.frame(for:)) ?? area.centeredFrame(size: before.size)
        let want = expected(window, target: target, unit: preset.rect, area: area, sizeBefore: before.size)
        let error = edgeError(after, want)
        if error > 1 { problems.append("got \(describe(after)) want \(describe(want))") }
        if result.moves.count != 1 { problems.append("engine reported \(result.moves.count) moves \(result.skippedReason ?? "")") }
        if case .fixed = window.constraint, result.moves.first?.sizeSettable != false {
            problems.append("fixed-size window not detected as fixed")
        }
        // Width variant: resizable windows reach exactly the variant's left edge and visibleFrame's
        // right edge wherever the preset touches them.
        if case .none = window.constraint, let unit = preset.rect {
            let left = visibleFrame.minX + (isStageManagerVariant(preset) ? stageManagerInset : 0)
            if unit.minX == 0 && abs(after.minX - left) > 0.5 { problems.append("left edge \(after.minX) != \(left)") }
            if unit.maxX == 1 && abs(after.maxX - visibleFrame.maxX) > 0.5 {
                problems.append("right edge \(after.maxX) != \(visibleFrame.maxX)")
            }
        }
        for (other, otherFrame) in bystanders where edgeError(frame(other), otherFrame) > 0.5 {
            problems.append("\(other.name) moved")
        }
        problems += settle([window])
        if !engine.hasHistory(window.element) { problems.append("no revert history") }

        engine.revert(window.element)
        let reverted = frame(window)
        let revertError = edgeError(reverted, before)
        if revertError > 1 { problems.append("revert got \(describe(reverted)) want \(describe(before))") }
        if engine.hasHistory(window.element) { problems.append("history kept after revert") }
        let note = result.moves.first?.realigned == true ? "re-aligned" : ""
        report(preset.id, window.label, problems, maxError: max(error, revertError), note: note)
    }
}

// Neighbouring single-window presets of one width variant touch: e.g. left-half-sm ends exactly
// where right-half-sm starts, and right-edge presets end at visibleFrame.maxX (TW1 frames).
for stageManager in [false, true] {
    let presets = PresetLibrary.all.filter { $0.kind == .moveResize && isStageManagerVariant($0) == stageManager }
    let placed = presets.filter { landed[$0.id] != nil }
    let problems = touching(placed.compactMap(\.rect), placed.compactMap { landed[$0.id] },
                            names: placed.map(\.id), tolerance: 0.5)
    var pairs = 0
    for a in placed { for b in placed { if let ra = a.rect, let rb = b.rect { let adj = adjacency(ra, rb); pairs += (adj.right ? 1 : 0) + (adj.below ? 1 : 0) } } }
    report("presets touch", stageManager ? "move & resize -sm (TW1)" : "move & resize full (TW1)", problems,
           note: "\(pairs) neighbour pairs, \(presets.count) presets")
}

// Revert goes back to the frame before Tiler's FIRST move (Moom semantics), not the last one.
do {
    let window = testWindows[0]
    var problems: [String] = []
    let before = frame(window)
    for id in ["left-half", "fill", "bottom-right-quarter"] {
        if let preset = PresetLibrary.preset(id: id) {
            engine.apply(preset: preset, hoveredWindow: window.element, screen: screen)
        }
    }
    engine.revert(window.element)
    let error = edgeError(frame(window), before)
    if error > 1 { problems.append("revert got \(describe(frame(window))) want \(describe(before))") }
    report("revert after 3 moves", window.label, problems, maxError: error)
}

// MARK: 2. Arrange presets

/// Deterministic shuffle (no randomness between runs).
func shuffled(_ count: Int, seed: String) -> [Int] {
    var state = seed.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    var items = Array(0..<count)
    for i in stride(from: count - 1, to: 0, by: -1) {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let j = Int((state >> 33) % UInt64(i + 1))
        items.swapAt(i, j)
    }
    return items
}

/// Staging frame near `slot`: centered on it, 76 % of its size (or the constrained size).
func stagingFrame(for window: TestWindow, near slot: CGRect) -> CGRect {
    var size = CGSize(width: (slot.width * 0.76).rounded(), height: (slot.height * 0.76).rounded())
    switch window.constraint {
    case .none: break
    case .minSize(let minimum): size = CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
    case .fixed: size = window.initial.size
    }
    return CGRect(x: (slot.midX - size.width / 2).rounded(), y: (slot.midY - size.height / 2).rounded(),
                  width: size.width, height: size.height)
}

/// `withTarget` false = the menu-bar / hotkey trigger without a usable target: the engine gets
/// `hoveredWindow: nil` and must keep the front-most windows in plain z-order.
func runArrange(_ preset: Preset, visibleCount: Int, withTarget: Bool = true) {
    let area = usableArea(for: preset)
    let slots = area.slotFrames(for: preset)
    let slotCount = slots.count
    // Width variant geometry: left slots start at visibleFrame.minX (+ inset for -sm), top/bottom
    // slots sit on visibleFrame's top/bottom, and neighbouring slots share edges exactly.
    let left = visibleFrame.minX + (isStageManagerVariant(preset) ? stageManagerInset : 0)
    var variantProblems = touching(preset.slots, slots, names: slots.indices.map { "slot\($0)" }, tolerance: 0.001)
    for (unit, slot) in zip(preset.slots, slots) {
        if unit.minX == 0 && abs(slot.minX - left) > 0.001 { variantProblems.append("left slot starts at \(slot.minX), not \(left)") }
        if unit.minY == 0 && abs(slot.minY - visibleFrame.minY) > 0.001 { variantProblems.append("top slot off visibleFrame") }
        if unit.maxY == 1 && abs(slot.maxY - visibleFrame.maxY) > 0.001 { variantProblems.append("bottom slot off visibleFrame") }
    }
    let relation = visibleCount < slotCount ? "fewer" : visibleCount > slotCount ? "more" : "equal"
    let scenario = (withTarget ? "" : "no target, ") + "\(visibleCount) windows, \(slotCount) slots (\(relation))"
    var problems: [String] = variantProblems
    guard send("show \(visibleCount)") else {
        report(preset.id, scenario, ["helper did not confirm show \(visibleCount)"])
        return
    }
    let visibleWindows = Array(testWindows.prefix(visibleCount))
    let hovered = visibleWindows[0]
    let keptCount = min(visibleCount, slotCount)
    // Kept = TW1 (hovered) + the last keptCount−1 windows, or without a target the last keptCount
    // windows; the others must stay untouched.
    let keptOthers = Array(visibleWindows.suffix(keptCount - 1))
    let kept = withTarget ? [hovered] + keptOthers : Array(visibleWindows.suffix(keptCount))
    let dropped = visibleWindows.filter { w in !kept.contains { $0.number == w.number } }

    // Place each kept window near its own shuffled slot; dropped windows at their cascade frame.
    // A constrained window takes the first shuffled slot its staging frame fits around without
    // leaving the usable area (else the OS would push it towards a neighbouring slot).
    var order = shuffled(slotCount, seed: "\(preset.id)/\(visibleCount)")
    var intended: [Int: Int] = [:]  // window number → slot
    let constrainedFirst = kept.filter { if case .none = $0.constraint { false } else { true } }
        + kept.filter { if case .none = $0.constraint { true } else { false } }
    for window in constrainedFirst {
        let index = order.firstIndex { area.rect.contains(stagingFrame(for: window, near: slots[$0])) } ?? 0
        let slot = order.remove(at: index)
        intended[window.number] = slot
        place(window, stagingFrame(for: window, near: slots[slot]))
    }
    for window in dropped { place(window, window.initial) }

    // Z-order front to back: kept others, dropped, TW1 last — so only the hovered rule keeps TW1.
    // Without a target: kept, then dropped — plain z-order decides.
    // Raises are applied by the window server asynchronously: wait for the order (one retry).
    let frontToBack = withTarget ? keptOthers + dropped + [hovered] : kept + dropped
    let intendedOrder = frontToBack.map(\.windowID)
    var zOrder: [CGWindowID] = []
    for _ in 0..<2 {
        for window in frontToBack.reversed() { engine.raise(window.element) }
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            zOrder = cgWindows().filter { $0.pid == testPID && $0.layer == 0 }.map(\.id)
            if zOrder == intendedOrder { break }
            Thread.sleep(forTimeInterval: 0.03)
        } while Date() < deadline
        if zOrder == intendedOrder { break }
    }
    if zOrder != intendedOrder { problems.append("z-order setup failed") }
    problems += settle(visibleWindows)

    // Enumerator: exactly the visible test windows, hovered first (if any), then CG z-order.
    let target = withTarget ? hovered.element : nil
    let candidates = WindowEnumerator.candidates(on: screen, hovered: target)
    let candidateIDs = candidates.compactMap(\.windowID)
    let visibleZOrder = zOrder.filter { id in visibleWindows.contains { $0.windowID == id } }
    let wantCandidates = withTarget ? [hovered.windowID] + visibleZOrder.filter { $0 != hovered.windowID } : visibleZOrder
    if candidateIDs != wantCandidates { problems.append("enumerator returned \(candidates.count) windows in wrong order") }
    if candidates.contains(where: { $0.pid != testPID }) { problems.append("enumerator returned a non-test window") }

    // Closest-slot precondition from the read-back frames: each kept window's nearest slot is its
    // intended one, by a clear margin — so the optimal assignment must be exactly that.
    var before: [Int: CGRect] = [:]
    for window in visibleWindows { before[window.number] = frame(window) }
    for window in kept {
        let costs = slots.map { cost(before[window.number]!, $0) }
        let ranked = costs.indices.sorted { costs[$0] < costs[$1] }
        if ranked[0] != intended[window.number] || (ranked.count > 1 && costs[ranked[1]] - costs[ranked[0]] <= 1) {
            problems.append("setup: \(window.name) nearest slot \(ranked[0]) != \(intended[window.number]!)")
        }
    }

    let result = engine.apply(preset: preset, hoveredWindow: target, screen: screen)
    var maxError: CGFloat = 0
    if result.moves.count != keptCount { problems.append("\(result.moves.count) moves, want \(keptCount)") }
    for window in kept {
        guard let slot = intended[window.number] else { continue }
        let unit = preset.slots[slot]
        let want = expected(window, target: slots[slot], unit: unit, area: area, sizeBefore: before[window.number]!.size)
        let got = frame(window)
        let error = edgeError(got, want)
        maxError = max(maxError, error)
        if error > 1 { problems.append("\(window.name) got \(describe(got)) want slot \(slot) \(describe(want))") }
        let reportedSlot = result.moves.first { $0.windowID == window.windowID }?.slotIndex
        if reportedSlot != slot { problems.append("\(window.name) engine slot \(reportedSlot.map(String.init) ?? "none") != \(slot)") }
    }
    // Exactly 2 windows: brute-force the 2×2 cost matrix (cost() above) over all ordered slot
    // pairs and compare with the engine's assignment — the two windows must go to two different
    // slots, at the pairing with the least total cost. The setup precondition (each window's
    // nearest slot by a margin > 1) makes that optimum unique, so a tie cannot mislead here.
    if keptCount == 2 {
        let pairingCosts = kept.map { window in slots.map { cost(before[window.number]!, $0) } }
        var optimum: (first: Int, second: Int)?
        var optimumTotal = CGFloat.infinity
        for first in slots.indices {
            for second in slots.indices where first != second {
                let total = pairingCosts[0][first] + pairingCosts[1][second]
                if total < optimumTotal { optimumTotal = total; optimum = (first, second) }
            }
        }
        let engineSlots = kept.map { window in result.moves.first { $0.windowID == window.windowID }?.slotIndex }
        if let optimum {
            if engineSlots != [optimum.first, optimum.second] {
                problems.append("engine pairing \(engineSlots.map { $0.map(String.init) ?? "none" }.joined(separator: " + "))"
                                + " != least-cost pairing \(optimum.first) + \(optimum.second)")
            }
        } else {
            problems.append("no two-slot pairing among \(slots.count) slots")
        }
    }
    // Actual windows in neighbouring slots touch (resizable ones; constrained ones may overlap).
    let resizableKept = kept.filter { if case .none = $0.constraint { true } else { false } }
    problems += touching(resizableKept.map { preset.slots[intended[$0.number]!] }, resizableKept.map(frame),
                         names: resizableKept.map(\.name), tolerance: 0.5)
    for window in dropped where edgeError(frame(window), before[window.number]!) > 0.5 {
        problems.append("\(window.name) should be untouched but moved")
    }
    problems += settle(visibleWindows)
    // Windows ordered out stay out: the engine only ever acts on on-stage candidates, so exactly
    // the visible windows may be on screen after the arrange. (Polled briefly, like settle: a
    // window that `show n` just ordered out can still be listed while the window server finishes
    // tearing it down; if one really comes back, the poll ends and the row names it.)
    let countDeadline = Date().addingTimeInterval(1.5)
    var onScreenProblems: [String] = []
    repeat {
        let onScreen = Set(cgWindows().filter { $0.pid == testPID && $0.layer == 0 }.map(\.id))
        let beyond = onScreen.subtracting(visibleWindows.map(\.windowID)).sorted()
        let missing = visibleWindows.filter { !onScreen.contains($0.windowID) }.map(\.name)
        onScreenProblems = beyond.map { id in
            let name = testWindows.first { $0.windowID == id }?.name ?? "helper window #\(id)"
            return "\(name) on screen beyond the \(visibleCount) visible"
        } + missing.map { "\($0) not on screen" }
        if onScreenProblems.isEmpty { break }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < countDeadline
    problems += onScreenProblems
    if !engine.hasArrangeHistory { problems.append("no arrange history") }

    let restored = engine.revertLastArrange()
    if restored != keptCount { problems.append("revert restored \(restored), want \(keptCount)") }
    var revertError: CGFloat = 0
    for window in visibleWindows {
        let error = edgeError(frame(window), before[window.number]!)
        revertError = max(revertError, error)
        if error > 1 { problems.append("revert: \(window.name) at \(describe(frame(window)))") }
    }
    if engine.hasArrangeHistory || kept.contains(where: { engine.hasHistory($0.element) }) {
        problems.append("history kept after revert")
    }
    let realigned = result.moves.filter(\.realigned).count
    report(preset.id, scenario, problems, maxError: max(maxError, revertError),
           note: realigned > 0 ? "\(realigned) re-aligned" : "")
}

for preset in PresetLibrary.all where preset.kind == .arrange {
    let slotCount = preset.slots.count
    // Fewer-windows-than-slots coverage: every arrange preset is additionally applied with
    // exactly 1 and exactly 2 visible windows. For k ≤ 2 those coincide with the k−1 / k
    // scenarios above, so they are added for k > 2 only (deduplicated, so a k = 3 preset where
    // 2 = k−1 would not run twice either).
    var counts = [slotCount - 1, slotCount, slotCount + 1]
    if slotCount > 2 { counts += [1, 2] }
    var ran = Set<Int>()
    for visibleCount in counts where (1...windowCount).contains(visibleCount) {
        if ran.insert(visibleCount).inserted { runArrange(preset, visibleCount: visibleCount) }
    }
}

// Revert of one window after an arrange, then of the rest of the arrange.
do {
    var problems: [String] = []
    if send("show 4"), let preset = PresetLibrary.preset(id: "arrange-2x2") {
        let windows = Array(testWindows.prefix(4))
        for window in windows { place(window, window.initial) }
        problems += settle(windows)
        let before = windows.map(frame)
        engine.apply(preset: preset, hoveredWindow: windows[0].element, screen: screen)
        let arranged = windows.map(frame)
        engine.revert(windows[1].element)
        if edgeError(frame(windows[1]), before[1]) > 1 { problems.append("TW2 not reverted") }
        for i in [0, 2, 3] where edgeError(frame(windows[i]), arranged[i]) > 0.5 { problems.append("\(windows[i].name) moved by single revert") }
        let restored = engine.revertLastArrange()
        if restored != 3 { problems.append("arrange revert restored \(restored), want 3") }
        for (i, window) in windows.enumerated() where edgeError(frame(window), before[i]) > 1 {
            problems.append("\(window.name) not restored")
        }
    } else {
        problems.append("setup failed")
    }
    report("revert single, then rest", "arrange-2x2, 4 windows", problems)
}

// Revert after windows were ordered out and in again (apps that only hide on ⌘W — Slack, Spotify,
// Music — do that). AppKit replaces an ordered-out window's AX element, so the element the engine
// recorded is dead while the CGWindowID and its history live on. Revert must reach the window
// through a live element, and keep the history while the window cannot be reached.
do {
    var hiddenProblems: [String] = []
    var problems: [String] = []
    var maxError: CGFloat = 0
    if send("show 3"), let preset = PresetLibrary.preset(id: "left-half") {
        place(testWindows[0], testWindows[0].initial)
        problems += settle([testWindows[0]])
        let before = frame(testWindows[0])
        let recorded = testWindows[0].element
        engine.apply(preset: preset, hoveredWindow: recorded, screen: screen)
        let moved = frame(testWindows[0])
        if edgeError(moved, before) <= 1 { problems.append("setup: left-half did not move TW1") }
        if send("show 0") {
            if engine.revert(recorded) { hiddenProblems.append("revert of the ordered-out TW1 reported success") }
        } else {
            hiddenProblems.append("helper did not confirm show 0")
        }
        if send("show 3") {
            let fresh = testWindows[0].element
            // Precondition: the scenario really invalidated the recorded element.
            if AX.frame(recorded) != nil { problems.append("setup: recorded element still answers after show 0 → show 3") }
            if !engine.hasHistory(fresh) { hiddenProblems.append("history lost by the revert while ordered out") }
            let reverted = engine.revert(fresh)
            let got = frame(testWindows[0])
            maxError = edgeError(got, before)
            if !reverted || maxError > 1 {
                problems.append("revert returned \(reverted), TW1 at \(describe(got)) want \(describe(before))")
            }
            if engine.hasHistory(fresh) { problems.append("history kept after revert") }
        } else {
            problems.append("helper did not confirm show 3")
        }
    } else {
        problems.append("setup failed")
    }
    report("revert while ordered out", "TW1 left-half, show 0", hiddenProblems, note: "no-op, history kept")
    report("revert after hide/show", "TW1 left-half, show 0 → show 3", problems, maxError: maxError)
}

/// Raises `windows` (the first one frontmost) and waits until the enumerator sees all of them on
/// the stage in consecutive polls spanning `stable` seconds; up to three raises. After the helper
/// ordered all its windows out ("show 0") and in again, Stage Manager re-sorts its stage for a
/// while, and a single poll can catch windows that are still on their way into the strip (then
/// they are no arrange candidates). Returns the windows still off the stage.
func awaitOnStage(_ windows: [TestWindow], stable: TimeInterval = 0.6) -> [TestWindow] {
    var offStage = windows
    for _ in 0..<3 {
        for window in windows.reversed() { engine.raise(window.element) }
        let deadline = Date().addingTimeInterval(3)
        var onStageSince: Date?
        repeat {
            let onStage = Set(WindowEnumerator.candidates(on: screen, hovered: nil).compactMap(\.windowID))
            offStage = windows.filter { !onStage.contains($0.windowID) }
            if !offStage.isEmpty {
                onStageSince = nil
            } else if let since = onStageSince {
                if Date().timeIntervalSince(since) >= stable { return [] }
            } else {
                onStageSince = Date()
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
    }
    return offStage
}

/// Arranges TW1…TW4 with arrange-2x2 from their cascade frames; returns the frames before, or nil
/// with the setup problem appended to `problems`.
func arrangeFour(_ problems: inout [String]) -> [CGRect]? {
    guard send("show 4"), let preset = PresetLibrary.preset(id: "arrange-2x2") else {
        problems.append("setup: helper did not confirm show 4")
        return nil
    }
    let windows = Array(testWindows.prefix(4))
    for window in windows { place(window, window.initial) }
    let offStage = awaitOnStage(windows)
    guard offStage.isEmpty else {
        problems.append("setup: \(offStage.map(\.name).joined(separator: ", ")) not on the stage")
        return nil
    }
    let unsettled = settle(windows)
    guard unsettled.isEmpty else {
        problems.append("setup: " + unsettled.joined(separator: ", "))
        return nil
    }
    let before = windows.map(frame)
    let result = engine.apply(preset: preset, hoveredWindow: windows[0].element, screen: screen)
    guard result.moves.count == 4 else {
        problems.append("setup: arrange-2x2 moved \(result.moves.count) of 4 windows \(result.skippedReason ?? "")")
        engine.revertLastArrange()  // leave no history behind for later rows
        return nil
    }
    return before
}

// Whole arrange reverted after all its windows were ordered out and in again: every recorded
// element is dead, so each window is found again by its CGWindowID.
do {
    var problems: [String] = []
    var maxError: CGFloat = 0
    if let before = arrangeFour(&problems) {
        let recorded = testWindows.prefix(4).map(\.element)
        if send("show 0"), send("show 4") {
            let dead = recorded.filter { AX.frame($0) == nil }.count
            if dead != 4 { problems.append("setup: \(4 - dead) recorded elements still answer after show 0 → show 4") }
            let restored = engine.revertLastArrange()
            if restored != 4 { problems.append("revert restored \(restored), want 4") }
            for (index, window) in testWindows.prefix(4).enumerated() {
                let error = edgeError(frame(window), before[index])
                maxError = max(maxError, error)
                if error > 1 { problems.append("\(window.name) at \(describe(frame(window))) want \(describe(before[index]))") }
            }
            if engine.hasArrangeHistory || testWindows.prefix(4).contains(where: { engine.hasHistory($0.element) }) {
                problems.append("history kept after revert")
            }
        } else {
            problems.append("helper did not confirm show 0 / show 4")
        }
    }
    report("arrange revert after hide/show", "arrange-2x2, show 0 → show 4", problems, maxError: maxError)
}

// Arrange reverted while one of its windows is ordered out: the others are restored, the hidden
// one keeps its history in the last-arrange group and is restored by a second Revert once shown.
do {
    var problems: [String] = []
    var maxError: CGFloat = 0
    if let before = arrangeFour(&problems) {
        if send("show 3") {
            let restored = engine.revertLastArrange()
            if restored != 3 { problems.append("first revert restored \(restored), want 3") }
            for (index, window) in testWindows.prefix(3).enumerated() where edgeError(frame(window), before[index]) > 1 {
                problems.append("\(window.name) not restored by the first revert")
            }
            if !engine.hasArrangeHistory { problems.append("arrange history dropped while TW4 is ordered out") }
        } else {
            problems.append("helper did not confirm show 3")
        }
        if send("show 4") {
            if !engine.hasHistory(testWindows[3].element) { problems.append("TW4 history lost") }
            let restored = engine.revertLastArrange()
            if restored != 1 { problems.append("second revert restored \(restored), want 1") }
            for (index, window) in testWindows.prefix(4).enumerated() {
                let error = edgeError(frame(window), before[index])
                maxError = max(maxError, error)
                if error > 1 { problems.append("\(window.name) at \(describe(frame(window))) want \(describe(before[index]))") }
            }
            if engine.hasArrangeHistory || engine.hasHistory(testWindows[3].element) {
                problems.append("history kept after the second revert")
            }
        } else {
            problems.append("helper did not confirm show 4")
        }
    }
    report("arrange revert, 1 hidden", "arrange-2x2, TW4 ordered out, then shown", problems, maxError: maxError)
}

// MARK: 3. Target capture for the menu-bar / hotkey triggers (SPEC §4.A, §4.B)

/// Lets NSWorkspace see activation changes (this CLI has no running run loop otherwise).
func pumpRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    Thread.sleep(forTimeInterval: 0.01)
}

func frontmostPID() -> pid_t? {
    pumpRunLoop()
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

func windowName(_ window: AXUIElement?) -> String {
    guard let window else { return "nil" }
    let id = AX.windowID(window)
    if let test = testWindows.first(where: { $0.windowID == id }) { return test.name }
    return "\(AX.string(window, kAXRoleAttribute) ?? "?")/\(AX.string(window, kAXSubroleAttribute) ?? "?") #\(id.map(String.init) ?? "?")"
}

/// Polls `focusedWindow()` until it is `want` (nil = no target) and returns the last result.
func awaitFocusedWindow(_ want: TestWindow?, timeout: TimeInterval = 2) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    var window: AXUIElement?
    repeat {
        pumpRunLoop()
        window = engine.focusedWindow()
        if let want { if window.flatMap(AX.windowID) == want.windowID { break } } else if window == nil { break }
    } while Date() < deadline
    return window
}

if send("show 3") {
    let windows = Array(testWindows.prefix(3))
    for window in windows { place(window, window.initial) }
    _ = settle(windows)

    // Follows focus: TW2 raised, then TW1.
    for window in [windows[1], windows[0]] {
        engine.raise(window.element)
        let got = awaitFocusedWindow(window)
        let front = frontmostPID()
        var problems: [String] = []
        if got.flatMap(AX.windowID) != window.windowID { problems.append("focusedWindow() = \(windowName(got))") }
        if front != testPID { problems.append("frontmost pid \(front.map(String.init) ?? "none"), not the helper") }
        report("focused window", "\(window.name) raised", problems)
    }

    // The captured element drives the engine like the hovered one.
    if let focused = awaitFocusedWindow(windows[0]), let preset = PresetLibrary.preset(id: "left-half") {
        var problems: [String] = []
        let before = frame(windows[0])
        let result = engine.apply(preset: preset, hoveredWindow: focused, screen: screen)
        let want = usableArea(for: preset).frame(for: preset.rect!)
        let error = edgeError(frame(windows[0]), want)
        if result.moves.count != 1 || error > 1 { problems.append("got \(describe(frame(windows[0]))) want \(describe(want))") }
        if !engine.revert(focused) || edgeError(frame(windows[0]), before) > 1 { problems.append("revert failed") }
        report("focused window", "apply left-half to it", problems, maxError: error)
    } else {
        report("focused window", "apply left-half to it", ["no focused window"])
    }

    // Pid outside TILER_ONLY_PIDS → nil (the helper stays frontmost).
    setenv(WindowEnumerator.pidFilterVariable, "1", 1)
    let filtered = engine.focusedWindow()
    setenv(WindowEnumerator.pidFilterVariable, "\(testPID)", 1)
    report("focused window", "helper not in TILER_ONLY_PIDS",
           filtered == nil ? [] : ["focusedWindow() = \(windowName(filtered)), want nil"])

    // Sheet focused → nil; ending the sheet gives TW1 back.
    if send("sheet on") {
        let got = awaitFocusedWindow(nil)
        report("focused window", "TW1 with a sheet", got == nil ? [] : ["focusedWindow() = \(windowName(got)), want nil"])
        _ = send("sheet off")
        let back = awaitFocusedWindow(windows[0])
        report("focused window", "TW1 after the sheet ended",
               back.flatMap(AX.windowID) == windows[0].windowID ? [] : ["focusedWindow() = \(windowName(back))"])
    } else {
        report("focused window", "TW1 with a sheet", ["helper did not confirm sheet on"])
    }

    // No window at all → nil, while the helper is still the frontmost app (so the nil is not the
    // pid filter's).
    if send("show 0") {
        let got = awaitFocusedWindow(nil)
        let front = frontmostPID()
        var problems: [String] = []
        if got != nil { problems.append("focusedWindow() = \(windowName(got)), want nil") }
        if front != testPID { problems.append("frontmost pid \(front.map(String.init) ?? "none"), not the helper") }
        report("focused window", "no window shown (show 0)", problems)
    } else {
        report("focused window", "no window shown (show 0)", ["helper did not confirm show 0"])
    }
} else {
    report("focused window", "setup", ["helper did not confirm show 3"])
}

// Arrange without a target: fewer / equal / more windows than slots, and one -sm variant.
if let preset = PresetLibrary.preset(id: "arrange-2x2") {
    for visibleCount in [3, 4, 5] { runArrange(preset, visibleCount: visibleCount, withTarget: false) }
}
if let preset = PresetLibrary.preset(id: "arrange-3x2-sm") {
    runArrange(preset, visibleCount: 7, withTarget: false)
}

// MARK: 4. Other windows untouched

_ = send("show \(windowCount)")
for window in testWindows { place(window, window.initial) }
_ = settle(testWindows)
var changed: [String] = []
var missing: [String] = []
let othersDeadline = Date().addingTimeInterval(5)
repeat {
    let now = otherWindows()
    changed = othersBefore.values.compactMap { old in
        guard let new = now[old.window.id] else { return nil }
        let name = "\(old.window.owner)#\(old.window.id)"
        if let oldFrame = old.stripFrame {
            guard let newFrame = new.stripFrame else { return "\(name) left the Stage Manager strip" }
            return edgeError(newFrame, oldFrame) > 0.5 ? "\(name) \(describe(oldFrame))→\(describe(newFrame))" : nil
        }
        if new.isStripWindow { return "\(name) moved into the Stage Manager strip" }
        return edgeError(new.window.bounds, old.window.bounds) > 0.5
            ? "\(name) \(describe(old.window.bounds))→\(describe(new.window.bounds))" : nil
    }
    missing = othersBefore.values.filter { now[$0.window.id] == nil }.map { "\($0.window.owner)#\($0.window.id)" }
    if changed.isEmpty && missing.isEmpty { break }
    Thread.sleep(forTimeInterval: 0.1)
} while Date() < othersDeadline
let stripCount = othersBefore.values.filter(\.isStripWindow).count
report("other windows untouched", "\(othersBefore.count) non-test windows",
       changed.map { "changed \($0)" } + missing.map { "gone \($0)" },
       note: "\(othersBefore.count - stripCount) by CG bounds, \(stripCount) strip windows by AX frame")

finish()
