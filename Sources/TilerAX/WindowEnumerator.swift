import AppKit
import ApplicationServices

/// One window an arrange preset may move.
public struct WindowCandidate {
    public let element: AXUIElement
    public let pid: pid_t
    public let windowID: CGWindowID?
    /// AX frame at enumeration time (AX space).
    public let frame: CGRect
}

/// Finds the windows an arrange preset acts on (SPEC §1 steps 1–2).
public enum WindowEnumerator {
    /// Environment variable with a comma-separated pid allow-list (SPEC §0). While it is set the
    /// engine acts only on windows of these pids; set but without a valid pid it acts on nothing.
    public static let pidFilterVariable = "TILER_ONLY_PIDS"

    /// CG owners that are never windows to arrange.
    static let excludedOwners: Set<String> = ["Dock", "WindowManager", "Notification Center"]

    /// Tolerance for matching an AX window to a CG record by pid + frame (windows without id).
    static let frameMatchTolerance: CGFloat = 2

    /// The allow-list from `TILER_ONLY_PIDS`, read on every call (the harness sets it at runtime).
    /// nil = variable unset = no filter.
    public static var pidFilter: Set<pid_t>? {
        guard let raw = getenv(pidFilterVariable) else { return nil }
        let pids = String(cString: raw).split(separator: ",").compactMap {
            pid_t($0.trimmingCharacters(in: .whitespaces))
        }
        return Set(pids.filter { $0 > 0 })
    }

    /// True if the engine may touch windows of `pid`: never our own process (SPEC §3), and only
    /// allow-listed pids while `TILER_ONLY_PIDS` is set.
    public static func isAllowed(pid: pid_t) -> Bool {
        guard pid != getpid() else { return false }
        guard let filter = pidFilter else { return true }
        return filter.contains(pid)
    }

    /// Window-level filters of SPEC §1 step 1: role AXWindow and subrole AXStandardWindow (this
    /// excludes sheets, AXSystemDialog and other panels), not minimized, not full screen.
    public static func isStandardWindow(_ window: AXUIElement) -> Bool {
        AX.string(window, kAXRoleAttribute) == kAXWindowRole
            && AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole
            && AX.bool(window, kAXMinimizedAttribute) != true
            && AX.bool(window, "AXFullScreen") != true
    }

    /// One on-screen CG window record.
    struct CGEntry {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        /// Stage Manager shows this window as a thumbnail in its side strip, not on the stage.
        let inStageStrip: Bool
    }

    /// On-screen windows of the current Space, front to back: layer 0, alpha > 0.01, not owned by
    /// Dock / WindowManager / Notification Center, pid allowed.
    ///
    /// Stage Manager strip windows stay "on screen" in CG with their thumbnail as bounds, and each
    /// thumbnail coincides with a WindowManager-owned layer-0 window (measured on macOS 27); such
    /// entries are flagged `inStageStrip`.
    static func onScreenEntries() -> [CGEntry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        typealias Record = (id: CGWindowID, pid: pid_t, owner: String, alpha: Double, bounds: CGRect)
        let records: [Record] = info.compactMap { record in
            guard let id = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDict = record[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            let owner = record[kCGWindowOwnerName as String] as? String ?? ""
            let alpha = (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            return (id, pid, owner, alpha, bounds)
        }
        let stripChrome = records.filter { $0.owner == "WindowManager" }.map(\.bounds)
        return records.compactMap { record in
            guard record.alpha > 0.01, !excludedOwners.contains(record.owner), isAllowed(pid: record.pid) else {
                return nil
            }
            let inStrip = stripChrome.contains { matches($0, record.bounds, tolerance: 1) }
            return CGEntry(id: record.id, pid: record.pid, bounds: record.bounds, inStageStrip: inStrip)
        }
    }

    /// Candidate windows on `screen`, front to back, with `hovered` first (SPEC §1 steps 1–2).
    ///
    /// AX windows are matched to on-screen CG records by CGWindowID (without an id: same pid and
    /// frame), which restricts the result to the current Space; Stage Manager strip windows are
    /// dropped (see `onScreenEntries`), so only the stage counts. Apps that are hidden are skipped. The hovered window is put first; if it did
    /// not match (e.g. mid-animation) but passes the window filters and the pid filter, it is
    /// prepended anyway.
    public static func candidates(on screen: NSScreen, hovered: AXUIElement?) -> [WindowCandidate] {
        let entries = onScreenEntries()
        var zIndex: [CGWindowID: Int] = [:]
        var pidsInOrder: [pid_t] = []
        for (index, entry) in entries.enumerated() {
            zIndex[entry.id] = index
            if !pidsInOrder.contains(entry.pid) { pidsInOrder.append(entry.pid) }
        }

        var found: [(z: Int, window: WindowCandidate)] = []
        for pid in pidsInOrder {
            guard NSRunningApplication(processIdentifier: pid)?.isHidden != true else { continue }
            let app = AX.application(pid: pid)
            guard AX.bool(app, kAXHiddenAttribute) != true else { continue }
            for window in AX.elements(app, kAXWindowsAttribute) where isStandardWindow(window) {
                guard let frame = AX.frame(window) else { continue }
                let windowID = AX.windowID(window)
                guard let entry = onScreenEntry(windowID: windowID, pid: pid, frame: frame, in: entries), !entry.inStageStrip,
                      let z = zIndex[entry.id],
                      let windowScreen = ScreenGeometry.screen(forWindowFrame: frame),
                      ScreenGeometry.isSameScreen(windowScreen, screen)
                else { continue }
                found.append((z, WindowCandidate(element: window, pid: pid, windowID: windowID ?? entry.id, frame: frame)))
            }
        }
        var ordered = found.sorted { $0.z < $1.z }.map(\.window)

        if let hovered {
            if let index = ordered.firstIndex(where: { isSameWindow($0, hovered) }) {
                ordered.insert(ordered.remove(at: index), at: 0)
            } else if let pid = AX.pid(hovered), isAllowed(pid: pid), isStandardWindow(hovered),
                      let frame = AX.frame(hovered) {
                ordered.insert(WindowCandidate(element: AX.prepare(hovered), pid: pid,
                                               windowID: AX.windowID(hovered), frame: frame), at: 0)
            }
        }
        return ordered
    }

    /// The on-screen CG record of an AX window of `pid`: by CGWindowID, or by same pid and frame
    /// only for windows without an id (a known id missing from the list must not borrow another
    /// window's record, e.g. an identically placed window on the current Space). nil = not on
    /// screen in the current Space (other Space, minimized, ordered out).
    static func onScreenEntry(windowID: CGWindowID?, pid: pid_t, frame: CGRect, in entries: [CGEntry]) -> CGEntry? {
        guard let windowID else {
            return entries.first { $0.pid == pid && matches($0.bounds, frame, tolerance: frameMatchTolerance) }
        }
        let entry = entries.first { $0.id == windowID }
        return entry?.pid == pid ? entry : nil
    }

    /// True if `window` (of `pid`, AX `frame`) is on screen in the current Space and on the stage,
    /// not a Stage Manager strip thumbnail — the same rule `candidates` applies.
    public static func isOnCurrentStage(_ window: AXUIElement, pid: pid_t, frame: CGRect) -> Bool {
        guard let entry = onScreenEntry(windowID: AX.windowID(window), pid: pid, frame: frame, in: onScreenEntries()) else {
            return false
        }
        return !entry.inStageStrip
    }

    static func isSameWindow(_ candidate: WindowCandidate, _ window: AXUIElement) -> Bool {
        if CFEqual(candidate.element, window) { return true }
        guard let id = candidate.windowID else { return false }
        return AX.windowID(window) == id
    }

    static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}
