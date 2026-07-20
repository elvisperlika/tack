import AppKit
import ApplicationServices

/// Reads the frontmost app's focused window via the Accessibility API. Needs the
/// Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility).
enum AXWindows {
    static func promptForPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Just the bounds — used as a fallback when the notification-based tracker isn't up.
    static func focusedBounds(pid: pid_t) -> CGRect? {
        focusedWindow(pid: pid).flatMap(bounds(of:))
    }

    /// The frontmost app's focused window element, kept alive to attach AX notifications to.
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
                == .success,
            let value,
            // The AX payload comes from another process; a type check beats trusting it.
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func bounds(of el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?
        var sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
            let pv,
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success, let sv,
            CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p),
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
        else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// The URL of the focused window's web area. Chrome and Safari expose their full AX tree
    /// once a trusted client is watching, which we are. nil → the caller binds to the window
    /// instead of the tab. Called on the 0.4s poll only, never per frame.
    static func focusedURL(pid: pid_t) -> String? {
        guard let win = focusedWindow(pid: pid), let area = webArea(in: win, depth: 0),
            let value = attribute(area, kAXURLAttribute)
        else { return nil }
        if let u = value as? URL { return u.absoluteString }
        return value as? String
    }

    // ponytail: depth-limited DFS; the web area sits a few levels under the window. Depth 6
    // covers Chrome and Safari today — raise it if a browser buries it deeper.
    private static func webArea(in el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 6 { return nil }
        if string(el, kAXRoleAttribute) == "AXWebArea" { return el }
        guard let value = attribute(el, kAXChildrenAttribute), let kids = value as? [AXUIElement]
        else { return nil }
        for kid in kids {
            if let hit = webArea(in: kid, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func attribute(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
