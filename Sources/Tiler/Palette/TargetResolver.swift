import AppKit
import ApplicationServices
import TilerCore

/// What the palette acts on (SPEC §4 "Target & header"): the window captured when the palette
/// was triggered, and the header text naming it.
struct PaletteTarget {
    /// The target window; nil = no usable target (header "No window", single-window presets
    /// disabled, arrange presets act on `screen`).
    let window: AXUIElement?
    /// The target window's pid, else the frontmost app's pid at trigger time (-1 if none).
    let pid: pid_t
    /// "App — Window title", "App" for an untitled window, or "No window".
    let header: String
    /// The target window's frame in AX space.
    let frame: CGRect?
    /// Where arrange presets act: the target window's screen, else the trigger's screen (status
    /// item's screen / screen under the mouse).
    let screen: NSScreen

    static let noWindowHeader = "No window"

    var hasWindow: Bool { window != nil }
}

/// Captures the target before anything is shown (SPEC §4.A/§4.B) and watches it while the
/// palette is open.
enum TargetResolver {
    /// The frontmost app's focused window via `AXWindowEngine.focusedWindow()` (which applies
    /// the no-target rules: sheets, dialogs, full screen, Finder desktop, other Spaces, our own
    /// process, `TILER_ONLY_PIDS`), with its header. `fallbackScreen` is the trigger's screen.
    static func capture(fallbackScreen: NSScreen) -> PaletteTarget {
        guard let window = AXWindowEngine.shared.focusedWindow() else {
            return PaletteTarget(window: nil, pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                                 header: PaletteTarget.noWindowHeader, frame: nil, screen: fallbackScreen)
        }
        return target(for: window, fallbackScreen: fallbackScreen)
    }

    /// The target for a known window (the focused one, or the hovered one for the green-button
    /// trigger): header "App — Window title" ("App" for an untitled window), frame and screen.
    static func target(for window: AXUIElement, fallbackScreen: NSScreen) -> PaletteTarget {
        let pid = AX.pid(window) ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? app?.bundleURL?.deletingPathExtension().lastPathComponent ?? "Window"
        let title = (AX.string(window, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = AXWindowEngine.shared.frame(of: window)
        let screen = frame.flatMap(ScreenGeometry.screen(forWindowFrame:)) ?? fallbackScreen
        return PaletteTarget(window: window, pid: pid, header: title.isEmpty ? appName : "\(appName) — \(title)",
                             frame: frame, screen: screen)
    }
}

/// Calls `onClose` when any of `notifications` fires on the target window — by default just
/// `kAXUIElementDestroyedNotification` (SPEC §4 dismissal "target window closed"), but the
/// hover trigger (C5) also watches move/resize (its hat's frame would otherwise go stale). One
/// `AXObserver` on the target's app, attached to the main run loop only while needed (the
/// palette is open, or a hover session, respectively) — no polling.
final class TargetCloseWatcher {
    private var observer: AXObserver?
    private let window: AXUIElement
    private let notifications: [String]
    fileprivate let onClose: () -> Void

    init?(window: AXUIElement, pid: pid_t, notifications: [String] = [kAXUIElementDestroyedNotification],
          onClose: @escaping () -> Void) {
        self.window = window
        self.notifications = notifications
        self.onClose = onClose
        var observer: AXObserver?
        guard AXObserverCreate(pid, targetClosedCallback, &observer) == .success, let observer else { return nil }
        var addedAny = false
        for name in notifications where AXObserverAddNotification(
            observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success {
            addedAny = true
        }
        guard addedAny else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
    }

    /// Detaches the observer; call before releasing.
    func invalidate() {
        guard let observer else { return }
        for name in notifications {
            AXObserverRemoveNotification(observer, window, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }
}

/// AX observer callback (C function pointer): runs on the main run loop.
private nonisolated func targetClosedCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let address = UInt(bitPattern: refcon)
    MainActor.assumeIsolated {
        let watcher = Unmanaged<TargetCloseWatcher>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
        watcher.onClose()
    }
}
