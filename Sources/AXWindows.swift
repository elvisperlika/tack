import AppKit
import ApplicationServices

/// The focused window of some app: a stable-ish identity key plus its bounds.
struct AppWindowInfo: Equatable {
    var key: String     // "<bundleID>|<document path or window title>"
    var bounds: CGRect  // top-left screen coords, like Finder/CGWindow
}

/// Reads the frontmost app's focused window via the Accessibility API. Needs the
/// Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility).
enum AXWindows {
    static func promptForPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Identity + bounds — used to decide which note to show.
    static func focused(of app: NSRunningApplication) -> AppWindowInfo? {
        guard let win = focusedElement(pid: app.processIdentifier) else { return nil }
        // Prefer the document path (stable across restarts); fall back to the window title (fuzzy).
        guard let ident = string(win, kAXDocumentAttribute) ?? string(win, kAXTitleAttribute),
              !ident.isEmpty, let b = bounds(win) else { return nil }
        let bundle = app.bundleIdentifier ?? app.localizedName ?? "app"
        return AppWindowInfo(key: bundle + "|" + ident, bounds: b)
    }

    /// Just the bounds — used per frame to follow the window.
    static func focusedBounds(pid: pid_t) -> CGRect? {
        focusedElement(pid: pid).flatMap(bounds)
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bounds(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success, let pv,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
