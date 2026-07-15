import Foundation
import CoreGraphics

/// The front Finder folder's path and its window bounds (AppleScript screen coords:
/// top-left origin of the primary display).
struct FinderState: Equatable {
    var path: String
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double
}

/// Front Finder folder window plus the normal windows stacked above it (for occlusion).
struct FinderWindowInfo {
    var bounds: CGRect          // top-left screen coords
    var coveringRects: [CGRect] // normal windows sitting above the folder window
}

/// Asks Finder (via one Apple event) which folder is frontmost and where its window is.
enum FinderWatcher {
    private static let script = NSAppleScript(source: """
    tell application "Finder"
        if (count of Finder windows) is 0 then return "NONE"
        set w to front Finder window
        set p to POSIX path of (target of w as alias)
        set b to bounds of w
        return p & "|" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
    end tell
    """)

    /// nil when Finder has no open window, isn't running, or permission is denied.
    static func current() -> FinderState? {
        var err: NSDictionary?
        guard let result = script?.executeAndReturnError(&err).stringValue, result != "NONE" else { return nil }
        let parts = result.components(separatedBy: "|")
        guard parts.count == 2 else { return nil }
        let nums = parts[1].components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 4 else { return nil }
        return FinderState(path: parts[0], left: nums[0], top: nums[1], right: nums[2], bottom: nums[3])
    }

    /// Front Finder folder window + whatever normal windows sit above it, via CGWindowList —
    /// cheap enough to call per frame for smooth following and occlusion. Same top-left
    /// screen origin as `bounds` above. No permission needed: owner name + bounds, not titles.
    /// Our own note is at `.floating` level (layer != 0), so it's skipped by the layer filter.
    static func frontFinderWindow() -> FinderWindowInfo? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var covering: [CGRect] = []
        for info in list { // front-to-back; only normal windows (layer 0)
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let b = info[kCGWindowBounds as String],
                  let rect = CGRect(dictionaryRepresentation: b as! CFDictionary) else { continue }
            if info[kCGWindowOwnerName as String] as? String == "Finder" {
                return FinderWindowInfo(bounds: rect, coveringRects: covering)
            }
            covering.append(rect) // a normal window above the front Finder folder window
        }
        return nil
    }
}
