import AppKit
import ApplicationServices

/// Reads the frontmost app's focused window via the Accessibility API. Needs the
/// Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility).
enum AXWindows {
    static func promptForPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Every AX read is a synchronous call into another app, made on our main thread, and the
    /// default wait for an answer is about six seconds — so an app that hung took Tack's menu
    /// and notes down with it. Set on the system-wide element, which makes it the limit for
    /// every element this process talks to.
    /// shortcut: one second for all apps; a slow app reads as "no window" for that poll and is
    /// retried on the next. Lower it if a hung app still makes Tack stutter.
    static func limitWaiting() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
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
        guard let win = focusedWindow(pid: pid) else { return nil }
        let kids: (AXUIElement) -> [AXUIElement] = {
            attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        let isWebArea: (AXUIElement) -> Bool = { string($0, kAXRoleAttribute) == "AXWebArea" }
        // The search asks every toolbar button and tab for its role and children, each one a
        // round trip into the browser. The web area keeps its place in the window from one poll
        // to the next, so the way to it is remembered and walked first: a handful of calls.
        // The URL is still read fresh from whatever sits there, so a tab switch is never stale.
        var area = follow(webAreaPath, from: win, children: kids, match: isWebArea)
        if area == nil {
            webAreaPath = []
            area = find(from: win, path: &webAreaPath, children: kids, match: isWebArea)
        }
        guard let area, let value = attribute(area, kAXURLAttribute) else { return nil }
        if let u = value as? URL { return u.absoluteString }
        return value as? String
    }

    /// Child indexes from the focused window down to its web area, as the last search found it.
    private static var webAreaPath: [Int] = []

    // ponytail: depth-limited DFS; the web area sits a few levels under the window. Depth 6
    // covers Chrome and Safari today — raise it if a browser buries it deeper.
    /// Generic over the node so `--selftest` can walk a plain tree; here the node is an AX element.
    /// On a hit, `path` holds the child index taken at each level.
    static func find<Node>(
        from node: Node, depth: Int = 0, path: inout [Int], children: (Node) -> [Node],
        match: (Node) -> Bool
    ) -> Node? {
        if depth > 6 { return nil }
        if match(node) { return node }
        for (i, kid) in children(node).enumerated() {
            path.append(i)
            if let hit = find(from: kid, depth: depth + 1, path: &path, children: children, match: match) {
                return hit
            }
            path.removeLast()
        }
        return nil
    }

    /// The node `path` leads to, or nil when the tree has changed shape and it no longer matches.
    static func follow<Node>(
        _ path: [Int], from node: Node, children: (Node) -> [Node], match: (Node) -> Bool
    ) -> Node? {
        var node = node
        for i in path {
            let kids = children(node)
            guard i < kids.count else { return nil }
            node = kids[i]
        }
        return match(node) ? node : nil
    }

    private static func attribute(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
