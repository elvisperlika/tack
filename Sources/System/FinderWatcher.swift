import AppKit

/// Front Finder folder window plus the normal windows stacked above it (for occlusion).
struct FinderWindowInfo {
    var bounds: CGRect  // top-left screen coords
    var coveringRects: [CGRect]  // normal windows sitting above the folder window
}

/// Asks Finder (via one Apple event) which folder is frontmost and where its window is.
enum FinderWatcher {
    /// The timeout is per Apple event, and it is the same guard `AXWindows.limitWaiting` gives the Accessibility reads: AppleScript otherwise waits about two minutes on Tack's main thread, so a Finder stuck on a dead network volume took the menu and every note down with it.
    /// shortcut: a Finder slower than two seconds reads as "no folder" for that poll and is retried on the next; lower it if a hung Finder still makes Tack stutter.
    static let script = NSAppleScript(
        source: """
            with timeout of 2 seconds
                tell application "Finder"
                    if (count of Finder windows) is 0 then return "NONE"
                    set w to front Finder window
                    set p to POSIX path of (target of w as alias)
                    set b to bounds of w
                    return p & "|" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
                end tell
            end timeout
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
    /// Every window on screen, front to back, desktop elements included: `isRearranging` reads the wallpapers. Everything else here keeps to the normal layer.
    static func list() -> [[String: Any]] {
        if let shared { return shared }
        let fresh = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        if sharing { shared = fresh }
        return fresh
    }

    private static var sharing = false
    private static var shared: [[String: Any]]?

    /// Everything `body` asks — is the screen being rearranged, where is this window — is answered from one read of the window list, taken when first asked for. Two reads a moment apart disagree at the edges of a desktop switch: the first has a window where the slide left it, the second says nothing is sliding, and a note placed by that pair stays wrong. Main thread only, and `body` must not run a modal: frames tracked under it would be handed this stale list.
    static func sharingOneRead(_ body: () -> Void) {
        sharing = true
        defer {
            sharing = false
            shared = nil
        }
        body()
    }

    /// The Dock is rearranging the screen: sliding from one desktop to the next, or showing Mission Control. For as long as it does, the window list is no place to read positions from. It holds the windows of every desktop taking part, each where the animation has it right now, so a note that followed them was moved by Tack and by the system at once, and the notes of the other desktops popped up on this one.
    static func isRearranging() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        return isRearranging(in: list(), displays: ids.prefix(Int(count)).map(CGDisplayBounds))
    }

    /// Two tells, both the Dock's. Mission Control puts a Dock window among the normal ones, where the Dock otherwise has none. And a slide shows in the wallpaper: the Dock keeps one behind each screen, exactly where the screen is, and mid-slide there is one per desktop, off to the side. Anything else the Dock owns down there is not screen-sized and says nothing, which also keeps an unknown setup on the old behaviour rather than freezing every note.
    static func isRearranging(in list: [[String: Any]], displays: [CGRect]) -> Bool {
        list.contains { info in
            guard info[kCGWindowOwnerName as String] as? String == "Dock",
                let layer = info[kCGWindowLayer as String] as? Int, layer <= 0,
                let b = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: b)
            else { return false }
            return layer == 0 || (displays.contains { $0.size == rect.size } && !displays.contains(rect))
        }
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
