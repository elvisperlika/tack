import AppKit
import ApplicationServices

/// The focused window of some app: a stable-ish identity key plus its bounds.
struct AppWindowInfo: Equatable {
    var key: String  // "<bundleID>|<document path or window title>"
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
        guard let win = focusedWindow(pid: app.processIdentifier) else { return nil }
        // Prefer the document path (stable across restarts); fall back to the window title (fuzzy).
        guard let ident = string(win, kAXDocumentAttribute) ?? string(win, kAXTitleAttribute),
            !ident.isEmpty, let b = bounds(of: win)
        else { return nil }
        let bundle = app.bundleIdentifier ?? app.localizedName ?? "app"
        return AppWindowInfo(key: bundle + "|" + ident, bounds: b)
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
            let value
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
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success, let sv
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

/// Follows one app window by AX move/resize notifications instead of 60fps polling, so the
/// note glides in lockstep with the window's own movement (the OS posts these live during a drag).
final class AXWindowTracker {
    private var observer: AXObserver?
    private let window: AXUIElement
    private let onMove: (CGRect) -> Void

    init?(pid: pid_t, window: AXUIElement, onMove: @escaping (CGRect) -> Void) {
        self.window = window
        self.onMove = onMove
        let callback: AXObserverCallback = { _, _, _, refcon in
            let me = Unmanaged<AXWindowTracker>.fromOpaque(refcon!).takeUnretainedValue()
            if let b = AXWindows.bounds(of: me.window) { me.onMove(b) }
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, window, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(obs, window, kAXWindowResizedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    deinit {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
    }
}
