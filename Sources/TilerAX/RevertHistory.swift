import ApplicationServices
import CoreGraphics

/// Frames to restore on Revert (SPEC §3). Moom semantics: Revert returns a window to the frame it
/// had before Tiler first touched it, so repeated moves keep the first recorded frame.
///
/// Keyed by CGWindowID (`_AXUIElementGetWindow`); for windows without an id, by pid + the frame
/// Tiler last gave the window (the key moves along with every recorded move). The last arrange
/// is remembered as the list of windows it moved. `Entry.element` is only the element seen at the
/// last move: AppKit replaces a window's AX element when the window is ordered out and in again,
/// so the engine resolves a live element by key before restoring.
public final class RevertHistory {
    public struct Entry {
        public let element: AXUIElement
        public let pid: pid_t
        /// Frame before Tiler's first move of this window (AX space).
        public let originalFrame: CGRect
    }

    enum Key: Hashable {
        case window(CGWindowID)
        /// pid + frame in half points (exact, hashable).
        case pidFrame(pid_t, x: Int, y: Int, width: Int, height: Int)

        init(windowID: CGWindowID?, pid: pid_t, frame: CGRect) {
            if let windowID {
                self = .window(windowID)
            } else {
                func half(_ value: CGFloat) -> Int { Int((value * 2).rounded()) }
                self = .pidFrame(pid, x: half(frame.minX), y: half(frame.minY),
                                 width: half(frame.width), height: half(frame.height))
            }
        }

        /// The CGWindowID for `.window` keys, nil for `.pidFrame` keys.
        var windowID: CGWindowID? {
            if case .window(let id) = self { return id }
            return nil
        }
    }

    private var entries: [Key: Entry] = [:]
    private var lastArrange: [Key] = []

    public init() {}

    /// Records a move of a window from `before` to `after`. Keeps an existing original frame.
    @discardableResult
    func record(element: AXUIElement, pid: pid_t, windowID: CGWindowID?, before: CGRect, after: CGRect) -> Key {
        let oldKey = Key(windowID: windowID, pid: pid, frame: before)
        let original = entries.removeValue(forKey: oldKey)?.originalFrame ?? before
        let newKey = Key(windowID: windowID, pid: pid, frame: after)
        entries[newKey] = Entry(element: element, pid: pid, originalFrame: original)
        if oldKey != newKey, let index = lastArrange.firstIndex(of: oldKey) {
            lastArrange[index] = newKey
        }
        return newKey
    }

    /// Replaces the last-arrange group: the windows an arrange moved, or after a Revert of it the
    /// ones that could not be reached yet.
    func setLastArrange(_ keys: [Key]) {
        lastArrange = keys
    }

    func entry(for key: Key) -> Entry? {
        entries[key]
    }

    func remove(_ key: Key) {
        entries[key] = nil
    }

    /// Windows of the last arrange that still have an entry.
    var lastArrangeKeys: [Key] {
        lastArrange.filter { entries[$0] != nil }
    }
}
