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

    /// The note key for a prefix of `path`. Pure, and the format is a compatibility
    /// guarantee: at the finest level of a 2-part path it reproduces the pre-Container
    /// key exactly, so existing appnotes.json files keep resolving.
    static func key(path: [String], level: Int) -> String {
        path.prefix(level + 1).joined(separator: "|")
    }

    func key(at level: Int) -> String { Self.key(path: path, level: level) }

    // MARK: - Storage (subclass supplies)

    func note(at level: Int) -> Note? { nil }
    func write(_ note: Note, at level: Int) {}

    // MARK: - Position (subclass supplies)

    func frame() -> Frame? { nil }

    // MARK: - Lookup

    /// Finest → coarsest, first hit wins, reporting the level it hit at.
    ///
    /// This is why the level is never stored in the Note: it *is* whichever prefix the note
    /// was written under. A window-level note is therefore found by every tab in that window
    /// for free, and there's no chicken-and-egg where you'd need the level to build the key
    /// to load the note that holds the level.
    final func load() -> (note: Note, level: Int)? {
        guard !path.isEmpty else { return nil }
        for level in stride(from: finestLevel, through: minLevel, by: -1) {
            if let n = note(at: level) { return (n, level) }
        }
        return nil
    }

    /// Promotion. Empty text is the delete convention in both stores, so this is
    /// delete-at-the-old-key then write-at-the-new-one.
    final func move(_ note: Note, from: Int, to: Int) {
        guard from != to else { return }
        write(Note(text: "", dx: note.dx, dy: note.dy, color: note.color), at: from)
        write(note, at: to)
    }
}

// MARK: - Finder

/// A Finder folder. The note lives in a hidden .tack.json inside the folder itself, which is
/// why it travels with the folder when you move or copy it — and why it can't be promoted.
final class FinderContainer: Container {
    static let bundleID = "com.apple.finder"
    let folder: String

    init(folder: String) { self.folder = folder }

    override var path: [String] { [Self.bundleID, folder] }
    override var minLevel: Int { 1 }

    // ponytail: one level exists here, so `level` is always 1 and the folder is the key
    override func note(at level: Int) -> Note? { NoteStore.load(folder: folder) }
    override func write(_ note: Note, at level: Int) { NoteStore.save(folder: folder, note: note) }

    /// Polled at 60fps to glue the note to the window. CGWindowList gives bounds and
    /// occluders in the same pass.
    override func frame() -> Frame? {
        guard let info = FinderWatcher.frontFinderWindow() else { return nil }
        return Frame(bounds: info.bounds, covering: info.coveringRects)
    }
}

// MARK: - Any other app

/// Any app window readable through the Accessibility API. AXDocument names the focused
/// document and follows Preview's active tab; AXTitle is the fuzzy fallback and follows the
/// Settings pane. Non-final: BrowserContainer and TerminalContainer refine the identity.
class GenericAppContainer: Container {
    let bundleID: String
    let pid: pid_t
    let ident: String

    init?(app: NSRunningApplication) {
        guard let win = AXWindows.focusedWindow(pid: app.processIdentifier),
            let id = AXWindows.string(win, kAXDocumentAttribute)
                ?? AXWindows.string(win, kAXTitleAttribute),
            !id.isEmpty
        else { return nil }
        self.bundleID = app.bundleIdentifier ?? app.localizedName ?? "app"
        self.pid = app.processIdentifier
        self.ident = id
    }

    override var path: [String] { [bundleID, ident] }

    override func note(at level: Int) -> Note? { AppNotes.load(key: key(at: level)) }
    override func write(_ note: Note, at level: Int) {
        AppNotes.save(key: key(at: level), note: note)
    }

    /// A focused app window is already on top, so nothing covers the note — `covering` stays
    /// empty and the caller's occlusion test collapses to false on its own.
    override func frame() -> Frame? {
        AXWindows.focusedBounds(pid: pid).map { Frame(bounds: $0) }
    }
}

// MARK: - Browser

/// A browser tab. The generic key can't tell one Chrome tab from another — they share a window
/// identity that mutates as you switch — so the URL becomes the third path component.
///
/// Note the path keeps `ident` as its second component rather than a prefixed variant, so the
/// level-1 key still matches the pre-Container format and old title-keyed browser notes resolve
/// as window-level notes instead of orphaning.
final class BrowserContainer: GenericAppContainer {
    // Any Chromium/WebKit browser qualifies if it exposes an AXWebArea with a URL — that's the
    // only thing focusedURL needs. Arc is Chromium, so it rides the same path as Chrome.
    static let bundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",  // Arc
    ]
    private let url: String?

    override init?(app: NSRunningApplication) {
        url = AXWindows.focusedURL(pid: app.processIdentifier).map(BrowserContainer.normalize)
        super.init(app: app)
    }

    override var path: [String] {
        guard let url, !url.isEmpty else { return [bundleID, ident] }  // no URL → window level
        return [bundleID, ident, url]
    }

    /// scheme + host + path. Query and fragment are session noise.
    static func normalize(_ raw: String) -> String {
        guard var c = URLComponents(string: raw), c.host != nil else { return raw }
        c.query = nil
        c.fragment = nil
        return c.url?.absoluteString ?? raw
    }
}

// MARK: - Terminal

/// A Terminal tab. Tab titles churn as commands run, so a title-keyed note would vanish
/// mid-build; the tty (/dev/ttys003) is the only stable tab identity, and it costs one
/// Apple event on the 0.4s poll.
final class TerminalContainer: GenericAppContainer {
    static let bundleID = "com.apple.Terminal"

    private static let ttyScript = NSAppleScript(
        source: """
            tell application "Terminal"
                if (count of windows) is 0 then return ""
                return tty of selected tab of front window
            end tell
            """)

    private let tty: String?

    override init?(app: NSRunningApplication) {
        tty = TerminalContainer.currentTTY()
        super.init(app: app)
    }

    /// nil when Terminal has no window, or when the automation prompt was denied — the
    /// container then binds at window level rather than failing.
    static func currentTTY() -> String? {
        var err: NSDictionary?
        guard let s = ttyScript?.executeAndReturnError(&err).stringValue, !s.isEmpty else {
            return nil
        }
        return s
    }

    override var path: [String] {
        guard let tty else { return [bundleID, ident] }  // no tty → window level
        return [bundleID, ident, tty]
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
