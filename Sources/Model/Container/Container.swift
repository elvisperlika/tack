import AppKit

/// Where a tracked window is, and what's stacked above it. The two travel together because
/// this is read at 60fps: splitting them would double the CGWindowList traversal per frame.
struct Frame {
    var bounds: CGRect  // top-left screen coords, like Finder/CGWindow
    var covering: [CGRect] = []  // normal windows sitting above it
}

/// The focused surface a note sticks to: an app, one of its windows, or one tab inside it.
///
/// Identity is a path, coarse → fine — ["com.apple.Preview", "Report.pdf"] — and the attach
/// level is an index into it. Tack only ever cares about the focused surface, so there is no
/// tree here: just the path to the current leaf.
///
/// Subclasses supply identity (`path`) and storage (`note(at:)` / `write(_:at:)`).
class Container {
    /// Identity, coarse → fine: [app, window, tab]. Only as deep as the app actually resolves.
    var path: [String] { [] }

    /// The coarsest level a note may attach at. Finder overrides this: its notes live in a
    /// .tack.json inside the folder, so "a note on all of Finder" has no file to live in.
    var minLevel: Int { 0 }

    var finestLevel: Int { path.count - 1 }

    /// A stable persistence identity for the finest scope when its display hierarchy contains
    /// mutable components. Browser and Terminal tabs provide this; ordinary containers do not.
    var finestKey: String? { nil }

    /// The note key for a prefix of `path`. Pure, and the format is a compatibility
    /// guarantee: at the finest level of a 2-part path it reproduces the pre-Container
    /// key exactly, so existing appnotes.json files keep resolving.
    static func key(path: [String], level: Int) -> String {
        path.prefix(level + 1).joined(separator: "|")
    }

    func key(at level: Int) -> String {
        if level == finestLevel, let finestKey { return finestKey }
        return Self.key(path: path, level: level)
    }

    /// What the polling loop compares to decide whether the focused surface actually changed.
    var focusKey: String { key(at: finestLevel) }

    // MARK: - Storage (subclass supplies)

    func note(at level: Int) throws -> Note? { nil }
    func write(_ note: Note, at level: Int) throws {}

    // MARK: - Position (subclass supplies)

    func frame() -> Frame? { nil }

    // MARK: - Lookup

    /// Finest → coarsest, first hit wins, reporting the level it hit at.
    ///
    /// This is why the level is never stored in the Note: it *is* whichever prefix the note
    /// was written under. A window-level note is therefore found by every tab in that window
    /// for free, and there's no chicken-and-egg where you'd need the level to build the key
    /// to load the note that holds the level.
    final func load() throws -> (note: Note, level: Int)? {
        guard !path.isEmpty else { return nil }
        for level in stride(from: finestLevel, through: minLevel, by: -1) {
            if let n = try note(at: level) { return (n, level) }
        }
        return nil
    }

    /// Write the destination first. If either operation fails, at least one complete copy remains.
    final func move(_ note: Note, from: Int, to: Int) throws {
        guard from != to else { return }
        try write(note, at: to)
        try write(Note(text: "", dx: note.dx, dy: note.dy, color: note.color), at: from)
    }
}

// MARK: - Resolution

extension Container {
    /// Which container the frontmost app gets. The one place per-app rules live.
    static func resolve(front: NSRunningApplication) -> Container? {
        if front.bundleIdentifier == FinderContainer.bundleID {
            guard let folder = FinderWatcher.frontFolderPath() else { return nil }
            return FinderContainer(folder: folder)
        }
        if let id = front.bundleIdentifier {
            if BrowserContainer.bundleIDs.contains(id) { return BrowserContainer(app: front) }
            if id == TerminalContainer.bundleID { return TerminalContainer(app: front) }
        }
        return GenericAppContainer(app: front)
    }
}

/// Menu wording for an attach level. Pure so it can be tested without a menu.
enum LevelName {
    /// Level 0 is always the app. The deepest level of a 3-part path is a tab; everything
    /// else is a window — a 2-part path bottoms out at the window, not a tab.
    static func label(level: Int, of count: Int) -> String {
        if level == 0 { return "Pin to this app" }
        if count > 2 && level == count - 1 { return "Pin to this tab" }
        return "Pin to this window"
    }
}

/// The level a shown note saves to. A reference cell rather than a plain Int because
/// NoteWindow debounces saves by 0.5s — longer than the 0.4s poll — so an in-flight save must
/// land at the level its own note was shown at, even if focus has moved on since.
final class LevelBox {
    var value: Int
    init(_ value: Int) { self.value = value }
}

// MARK: - Naming a stored note

/// Human wording for a note's storage key, for any UI that lists notes away from the app they
/// belong to. Pure apart from the bundle-ID lookup, so it can be tested without a window.
extension Container {
    /// "Finder — Projects", "Chrome — example.com/page", "Preview — Report.pdf".
    static func label(for key: String) -> String {
        let parts = key.components(separatedBy: "|")
        let app = appName(bundleID: parts[0])
        let rest = parts.dropFirst().map(detail).joined(separator: " › ")
        return rest.isEmpty ? app : "\(app) — \(rest)"
    }

    /// Which scope the key attaches to. ponytail: the key doesn't record its level, so this is
    /// inferred from the bundle ID — store the level beside the note if a third tab-style app
    /// ever needs telling apart.
    static func scopeName(for key: String) -> String {
        let parts = key.components(separatedBy: "|")
        guard parts.count > 1 else { return "App" }
        if parts[0] == FinderContainer.bundleID { return "Folder" }
        if BrowserContainer.bundleIDs.contains(parts[0]) { return "Tab" }
        if parts[0] == TerminalContainer.bundleID { return "Tab" }
        return "Window"
    }

    /// The app's own name, or the bundle ID verbatim when it isn't installed — a note outlives
    /// the app it was written on.
    static func appName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        // displayName keeps the extension when Finder is set to show all of them.
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// What clicking a note's header should bring forward. Pure, so the choice can be tested
    /// without opening anything.
    enum RevealTarget: Equatable {
        case folder(String)  // a Finder window on this path
        case url(URL)  // this page, in the browser the note was written on
        case app  // just bring the app forward
    }

    static func revealTarget(for key: String) -> RevealTarget {
        let parts = key.components(separatedBy: "|")
        if parts[0] == FinderContainer.bundleID, parts.count > 1 { return .folder(parts[1]) }
        // The finest component is a URL only for browser tabs; a Terminal tty also starts with
        // a slash, which is why this tests the scheme rather than the shape.
        if let last = parts.dropFirst().last, let url = URL(string: last),
            url.scheme?.hasPrefix("http") == true {
            return .url(url)
        }
        return .app
    }

    /// Bring the surface a note belongs to back to the front. The note follows on its own: the
    /// poll notices the focus change and shows whatever is pinned there.
    ///
    /// ponytail: a browser gets the URL (its own tab if it already has one, a new tab if not)
    /// and everything else just comes forward — picking a particular window or Terminal tab
    /// needs AX or an Apple event per app. Add that if landing on the wrong one starts to sting.
    @discardableResult static func reveal(key: String) -> Bool {
        let bundleID = key.components(separatedBy: "|")[0]
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }  // the app is gone; the note outlived it
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        switch revealTarget(for: key) {
        case .folder(let path):
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: path)], withApplicationAt: app, configuration: config)
        case .url(let url):
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        case .app:
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
        return true
    }

    /// A path component as a person would read it: folders and ttys by their last component,
    /// URLs without the scheme, window titles as they are.
    private static func detail(_ part: String) -> String {
        if part.hasPrefix("/") { return (part as NSString).lastPathComponent }
        guard let url = URLComponents(string: part), let host = url.host else { return part }
        return host + (url.path == "/" ? "" : url.path)
    }
}
