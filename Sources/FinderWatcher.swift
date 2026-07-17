import CoreGraphics
import Foundation

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

    /// The front folder's POSIX path; nil when Finder has no open window, isn't running, or
    /// permission is denied. The window bounds come from CGWindowList below, so only the path
    /// is read out of the reply — the script still fetches bounds to keep the Apple event,
    /// and the reply format, untouched.
    static func frontFolderPath() -> String? {
        var err: NSDictionary?
        guard let result = script?.executeAndReturnError(&err).stringValue, result != "NONE" else {
            return nil
        }
        let parts = result.components(separatedBy: "|")
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return parts[0]
    }

    /// Front Finder folder window + whatever normal windows sit above it, via CGWindowList —
    /// cheap enough to call per frame for smooth following and occlusion. Same top-left
    /// screen origin as `bounds` above. No permission needed: owner name + bounds, not titles.
    /// Our own note is at `.floating` level (layer != 0), so it's skipped by the layer filter.
    static func frontFinderWindow() -> FinderWindowInfo? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var covering: [CGRect] = []
        for info in list {  // front-to-back; only normal windows (layer 0)
            guard info[kCGWindowLayer as String] as? Int == 0,
                // conditional cast: window-server data is another process's word, not ours
                let b = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: b)
            else { continue }
            if info[kCGWindowOwnerName as String] as? String == "Finder" {
                return FinderWindowInfo(bounds: rect, coveringRects: covering)
            }
            covering.append(rect)  // a normal window above the front Finder folder window
        }
        return nil
    }
}
