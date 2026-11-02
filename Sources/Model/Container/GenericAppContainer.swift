import AppKit

/// Any app window readable through the Accessibility API. AXDocument names the focused
/// document and follows Preview's active tab; AXTitle is the fuzzy fallback and follows the
/// Settings pane. Non-final: BrowserContainer and TerminalContainer refine the identity.
class GenericAppContainer: Container {
    let bundleID: String
    let pid: pid_t
    let ident: String
    /// The window-server number of the window that was focused when this was resolved — the app
    /// is frontmost then, so its first window is the one. What lets the note keep following
    /// *that* window after the app has gone to the background. nil: nothing on screen to number.
    private let window: Int?

    init?(app: NSRunningApplication) {
        // An empty AXDocument (Electron reports one) must fall through to the title, not end
        // the lookup there.
        let win = AXWindows.focusedWindow(pid: app.processIdentifier)
        let id = win.flatMap { w in
            [kAXDocumentAttribute, kAXTitleAttribute].lazy
                .compactMap { AXWindows.string(w, $0) }.first { !$0.isEmpty }
        }
        // No window identity at all: a plain app can still take an app-level note, as long
        // as it has a window on screen to pin it to. Subclasses key on the window, so they can't.
        let window = WindowServer.window(of: app.processIdentifier)?.number
        guard id != nil || (Self.self == GenericAppContainer.self && window != nil)
        else { return nil }
        self.bundleID = app.bundleIdentifier ?? app.localizedName ?? "app"
        self.pid = app.processIdentifier
        self.ident = id ?? ""
        self.window = window
    }

    override var path: [String] { ident.isEmpty ? [bundleID] : [bundleID, ident] }

    override func note(at level: Int) throws -> Note? {
        let currentKey = key(at: level)
        // Before stable tab keys, the mutable title was part of the key. Migrate on first read;
        // writing the new key before deleting the old one makes an interrupted migration harmless.
        let legacyKey = Container.key(path: path, level: level)
        return try AppNotes.load(key: currentKey, migrating: legacyKey)
    }
    override func write(_ note: Note, at level: Int) throws {
        try AppNotes.save(key: key(at: level), note: note)
    }

    /// Bounds come from the window server, not AX: an AX read is a synchronous round-trip
    /// into the app's main thread, which is busy servicing the event loop during a drag, so
    /// the note trailed and stuttered. CGWindowList is fresh every frame — same source that
    /// keeps Finder tracking smooth. AX stays as the fallback for windows the list can't see.
    ///
    /// ponytail: a sheet can sit above its parent at layer 0 and be the window numbered at
    /// resolve time — the note pins to the sheet until it closes.
    override func frame() -> Frame? {
        if let hit = WindowServer.window(of: pid, number: window) { return hit.frame }
        // The numbered window is off screen. In the background that is the whole answer: the
        // note waits for it. In front, the app's frontmost window will do until the next poll
        // resolves the surface again — and so it will when there never was a number.
        let inFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        guard window == nil || inFront else { return nil }
        return WindowServer.window(of: pid)?.frame
            ?? AXWindows.focusedBounds(pid: pid).map { Frame(bounds: $0) }
    }
}
