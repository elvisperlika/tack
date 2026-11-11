import AppKit

/// Front Finder folder window plus the normal windows stacked above it (for occlusion).
struct FinderWindowInfo {
    var bounds: CGRect  // top-left screen coords
    var coveringRects: [CGRect]  // normal windows sitting above the folder window
}

/// Asks Finder (via one Apple event) which folder is frontmost and where its window is.
enum FinderWatcher {
    private static let script = NSAppleScript(
        source: """
            tell application "Finder"
                if (count of Finder windows) is 0 then return "NONE"
                set w to front Finder window
                set p to POSIX path of (target of w as alias)
                set b to bounds of w
                return p & "|" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
            end tell
            """)

    /// The front folder's POSIX path and where Finder says its window is; nil when Finder has
    /// no open window, isn't running, or permission is denied. The bounds are only a hint for
    /// picking that window out of the window list — per-frame tracking reads the list itself.
    static func frontFolder() -> (path: String, bounds: CGRect)? {
        var err: NSDictionary?
        guard let result = script?.executeAndReturnError(&err).stringValue else { return nil }
        return parse(result)
    }

    /// "path|left,top,right,bottom". Split at the *last* bar: a folder name may hold one too.
    static func parse(_ reply: String) -> (path: String, bounds: CGRect)? {
        guard let bar = reply.range(of: "|", options: .backwards) else { return nil }  // "NONE"
        let path = String(reply[..<bar.lowerBound])
        let n = reply[bar.upperBound...].split(separator: ",").compactMap { Double($0) }
        guard !path.isEmpty, n.count == 4 else { return nil }
        return (path, CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1]))
    }

    /// The window-server number of the Finder window sitting where Finder said its front folder
    /// window is. "Front Finder window" means a *folder* window, but the window list also holds
    /// Finder's info panels and dialogs, and the frontmost of those is not always the folder.
    /// nil when nothing lines up (the window moved between the two reads): tracking then falls
    /// back to the frontmost Finder window, as it always did.
    static func windowNumber(near hint: CGRect) -> Int? {
        for info in WindowServer.list() where info[kCGWindowOwnerName as String] as? String == "Finder" {
            guard info[kCGWindowLayer as String] as? Int == 0,
                let b = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: b), near(rect, hint)
            else { continue }
            return info[kCGWindowNumber as String] as? Int
        }
        return nil
    }

    /// Finder and the window server report the same rect; the slack is for rounding only.
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.maxX - b.maxX) <= 2
            && abs(a.maxY - b.maxY) <= 2
    }

    /// The Finder folder window + whatever normal windows sit above it, via CGWindowList —
    /// cheap enough to call per frame for smooth following and occlusion. Same top-left
    /// screen origin as `bounds` above. No permission needed: owner name + bounds, not titles.
    /// Our own note is at `.floating` level (layer != 0), so it's skipped by the layer filter.
    ///
    /// `number` picks the window to follow; any Finder window above it is one more occluder.
    /// With no number the frontmost Finder window is the one. Once a numbered window is gone,
    /// `orFrontmost` says whether the frontmost will do instead: yes while Finder is in front
    /// (the next poll sorts it out), no in the background, where it is some other folder.
    static func frontFinderWindow(number: Int? = nil, orFrontmost: Bool = true) -> FinderWindowInfo? {
        var covering: [CGRect] = []
        var frontmost: FinderWindowInfo?
        for info in WindowServer.list() {  // front-to-back; only normal windows (layer 0)
            guard info[kCGWindowLayer as String] as? Int == 0,
                // conditional cast: window-server data is another process's word, not ours
                let b = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: b)
            else { continue }
            if info[kCGWindowOwnerName as String] as? String == "Finder" {
                // Finder's inline-rename editor is a real borderless layer-0 Finder window
                // floating above the folder window while a name is edited — tracking it would
                // teleport the note into a text strip. No folder window is anywhere near this
                // small. Skipped entirely: it's not an occluder either, it sits *inside* the
                // folder view. ponytail: size heuristic; match kCGWindowNumber if it misfires.
                if rect.width < 200 || rect.height < 80 { continue }
                let found = FinderWindowInfo(bounds: rect, coveringRects: covering)
                if number == nil || info[kCGWindowNumber as String] as? Int == number { return found }
                if frontmost == nil { frontmost = found }
            }
            covering.append(rect)  // a normal window above the tracked Finder folder window
        }
        return orFrontmost ? frontmost : nil
    }
}

/// Per-frame window bounds straight from the window server — the process compositing the
/// screen — so they're fresh even mid-drag, when an AX query would stall on the target
/// app's busy main thread.
enum WindowServer {
    /// Every window on screen, front to back.
    static func list() -> [[String: Any]] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// The on-screen window `number` of `pid`, or its frontmost one when no number is given —
    /// with the other apps' windows stacked above it, for occlusion.
    static func window(of pid: pid_t, number: Int? = nil) -> (number: Int, frame: Frame)? {
        pick(from: list(), pid: pid, number: number)
    }

    /// The walk itself, over plain data so `--selftest` can hand it a made-up screen.
    ///
    /// Only normal (layer-0) windows count; our own notes float above that layer and are
    /// skipped with everything else there. The app's *own* other windows are neither the hit
    /// nor an occluder: a sheet or a popup sits above its parent at layer 0, and counting it
    /// would blink the note away every time one opens.
    static func pick(from list: [[String: Any]], pid: pid_t, number: Int?) -> (
        number: Int, frame: Frame
    )? {
        var covering: [CGRect] = []
        for info in list {  // front-to-back
            guard info[kCGWindowLayer as String] as? Int == 0,
                // conditional cast: window-server data is another process's word, not ours
                let b = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: b)
            else { continue }
            guard info[kCGWindowOwnerPID as String] as? Int == Int(pid) else {
                covering.append(rect)  // another app's window, above the one we are after
                continue
            }
            if let n = info[kCGWindowNumber as String] as? Int, number == nil || n == number {
                return (n, Frame(bounds: rect, covering: covering))
            }
        }
        return nil
    }
}
