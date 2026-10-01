import AppKit
import ApplicationServices

/// Private bridge AX element → CGWindowID (used by Rectangle and Loop; see docs/research.md
/// "Window ID bridge"). Returns `.success` and writes the id for real windows.
@_silgen_name("_AXUIElementGetWindow")
private func axUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Typed wrappers over the Accessibility C API. Every element that passes through `prepare`
/// gets the 0.1 s messaging timeout (SPEC §3), so one hung app cannot stall the main thread for
/// the multi-second system default. All helpers are main-actor bound (module default).
public enum AX {
    /// Messaging timeout for every element the engine touches, in seconds (SPEC §3).
    public static let messagingTimeout: Float = 0.1

    /// Sets the engine's messaging timeout on `element` and returns it.
    @discardableResult
    public static func prepare(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// The application element for `pid`, timeout set.
    public static func application(pid: pid_t) -> AXUIElement {
        prepare(AXUIElementCreateApplication(pid))
    }

    // MARK: Reading

    public static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    /// An element-valued attribute (e.g. `kAXWindowAttribute`), timeout set.
    public static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return prepare(value as! AXUIElement)
    }

    /// An array-of-elements attribute (e.g. `kAXWindowsAttribute`), timeouts set.
    public static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        let list = value(element, attribute) as? [AXUIElement] ?? []
        return list.map(prepare)
    }

    public static func point(_ element: AXUIElement, _ attribute: String = kAXPositionAttribute) -> CGPoint? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    public static func size(_ element: AXUIElement, _ attribute: String = kAXSizeAttribute) -> CGSize? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Window frame in AX space (top-left origin of the primary screen, y down).
    public static func frame(_ window: AXUIElement) -> CGRect? {
        guard let origin = point(window), let size = size(window) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Whether `attribute` is settable; nil when the query itself failed.
    public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return nil }
        return settable.boolValue
    }

    public static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// The CGWindowID behind a window element (private `_AXUIElementGetWindow`), nil if unknown.
    public static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard axUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: Writing

    @discardableResult
    public static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    @discardableResult
    public static func setPosition(_ window: AXUIElement, _ origin: CGPoint) -> Bool {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return false }
        return set(window, kAXPositionAttribute, value)
    }

    @discardableResult
    public static func setSize(_ window: AXUIElement, _ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return set(window, kAXSizeAttribute, value)
    }

    @discardableResult
    public static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }
}
